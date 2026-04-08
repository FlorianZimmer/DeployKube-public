#!/usr/bin/env bash
set -euo pipefail

ISTIO_HELPER="/helpers/istio-native-exit.sh"
[ -f "$ISTIO_HELPER" ] || { echo "missing istio-native-exit helper" >&2; exit 1; }
. "$ISTIO_HELPER"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

LAST_ERROR=""

fail() {
  LAST_ERROR="$*"
  log "ERROR: $*"
  exit 1
}

kcadm_retry() {
  local what="$1"
  shift

  local attempts="${KEYCLOAK_KCADM_ATTEMPTS:-10}"
  local delay="${KEYCLOAK_KCADM_DELAY:-3}"
  local cmd_timeout="${KEYCLOAK_KCADM_COMMAND_TIMEOUT:-30s}"
  local has_timeout="false"
  local out="" err_file="" err_tail="" rc=0

  if command -v timeout >/dev/null 2>&1; then
    has_timeout="true"
  fi

  for ((i=1; i<=attempts; i++)); do
    err_file="${TMP_DIR}/kcadm-err-$(date +%s%N)"
    if [[ "${has_timeout}" == "true" ]]; then
      if out="$(timeout "${cmd_timeout}" "$@" 2>"${err_file}")"; then
        rc=0
      else
        rc=$?
      fi
    elif out="$("$@" 2>"${err_file}")"; then
      rc=0
    else
      rc=$?
    fi
    if [[ "${rc}" -eq 0 ]]; then
      if [[ -s "${err_file}" ]]; then
        err_tail="$(tail -n 2 "${err_file}" || true)"
        if [[ -n "${err_tail}" ]]; then
          log "WARN: ${what} emitted stderr (exit=0): ${err_tail}" >&2
        fi
      fi
      rm -f "${err_file}" || true
      printf '%s' "${out}"
      return 0
    fi

    if [[ "${i}" -lt "${attempts}" ]]; then
      if [[ "${rc}" -eq 124 ]]; then
        log "WARN: ${what} timed out after ${cmd_timeout} (attempt ${i}/${attempts}); retrying after ${delay}s"
      else
        log "WARN: ${what} failed (attempt ${i}/${attempts}); retrying after ${delay}s"
      fi
      if [[ -s "${err_file}" ]]; then
        tail -n 2 "${err_file}" >&2 || true
      else
        printf '%s\n' "${out}" | tail -n 2 >&2
      fi
      sleep "${delay}"
    fi
  done

  if [[ ! -s "${err_file}" && -z "${out}" ]]; then
    log "ERROR: ${what} failed (exit=${rc}) with no output" >&2
  fi
  if [[ -s "${err_file}" ]]; then
    cat "${err_file}" >&2
  else
    printf '%s\n' "${out}" >&2
  fi
  rm -f "${err_file}" || true
  fail "${what} failed after ${attempts} attempts"
}

kcadm_best_effort() {
  local what="$1"
  shift

  local cmd_timeout="${KEYCLOAK_KCADM_BEST_EFFORT_TIMEOUT:-${KEYCLOAK_KCADM_COMMAND_TIMEOUT:-30s}}"
  local rc=0

  if command -v timeout >/dev/null 2>&1; then
    timeout "${cmd_timeout}" "$@" >/dev/null 2>&1 || rc=$?
  else
    "$@" >/dev/null 2>&1 || rc=$?
  fi

  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${rc}" -eq 124 ]]; then
      log "WARN: ${what} timed out after ${cmd_timeout} (continuing)"
    else
      log "WARN: ${what} failed (exit=${rc}, continuing)"
    fi
  fi
}

NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_NAME="${KEYCLOAK_NAME:-keycloak}"
HTTPROUTE_NAME="${KEYCLOAK_HTTPROUTE_NAME:-keycloak}"
ISTIO_NAMESPACE="${KEYCLOAK_ISTIO_NAMESPACE:-istio-system}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
TEMPLATE_DIR="${KEYCLOAK_REALM_TEMPLATE_DIR:-/realm-templates}"
RENDER_DIR="${KEYCLOAK_REALM_RENDER_DIR:-/rendered-realms}"
VARIABLE_MAP_CONFIGMAP="${KEYCLOAK_REALM_VARIABLES_CONFIGMAP:-keycloak-realm-variable-map}"
STATUS_CM="${STATUS_CONFIGMAP:-keycloak-bootstrap-status}"
KEYCLOAK_API="${KEYCLOAK_INTERNAL_URL:-http://keycloak.keycloak.svc.cluster.local:8080}"
EXTERNAL_KEYCLOAK_HOST="${KEYCLOAK_HOST:-https://keycloak.placeholder.invalid}"
TLS_SECRET_NAME="${KEYCLOAK_TLS_SECRET:-keycloak-tls}"
INITIAL_ADMIN_SECRET_NAME="${KEYCLOAK_INITIAL_ADMIN_SECRET:-keycloak-initial-admin}"
ADMIN_CREDENTIALS_SECRET_NAME="${KEYCLOAK_ADMIN_CREDENTIALS_SECRET:-keycloak-admin-credentials}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault-system.svc:8200}"
VAULT_LOGIN_METHOD="${VAULT_LOGIN_METHOD:-kubernetes}"
VAULT_K8S_ROLE="${VAULT_K8S_ROLE:-keycloak-bootstrap}"
SERVICEACCOUNT_TOKEN_PATH="${SERVICEACCOUNT_TOKEN_PATH:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
TENANT_REGISTRY_PATH="${TENANT_REGISTRY_PATH:-/tenant-registry/tenant-registry.yaml}"
DEPLOYKUBE_CONFIG_SNAPSHOT_NAME="${DEPLOYKUBE_CONFIG_SNAPSHOT_NAME:-deploykube-deployment-config}"
DEPLOYKUBE_CONFIG_SNAPSHOT_KEY="${DEPLOYKUBE_CONFIG_SNAPSHOT_KEY:-deployment-config.yaml}"
KEYCLOAK_IAM_UPSTREAM_ALIAS="${KEYCLOAK_IAM_UPSTREAM_ALIAS:-upstream}"

declare -A PREV_STATUS=()
declare -A STATUS=()
declare -A RENDERED_REALM_SHA=()

TMP_DIR="$(mktemp -d)"
DEPLOYMENT_CONFIG_FILE="${TMP_DIR}/deployment-config.yaml"
KCADM_CONFIG="${TMP_DIR}/kcadm.config"
export KCADM_CONFIG

IAM_MODE="standalone"
IAM_PRIMARY_REALM="deploykube-admin"
IAM_UPSTREAM_TYPE=""
IAM_UPSTREAM_ALIAS="${KEYCLOAK_IAM_UPSTREAM_ALIAS}"
IAM_FAIL_OPEN="true"
IAM_OFFLINE_REQUIRED="false"
IAM_OFFLINE_METHOD="password+otp"
DEPLOYMENT_ID=""
DEPLOYMENT_ENVIRONMENT_ID=""
declare -a IAM_TARGET_REALMS=()

write_failure_status() {
  local exit_code="$1"
  set_status "job.lastExitCode" "${exit_code}"
  set_status "job.lastError" "${LAST_ERROR:-unknown}"
  set_status "job.lastFailure" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  write_status_configmap || true
}

cleanup() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 ]]; then
    write_failure_status "${exit_code}"
  fi
  rm -rf "${TMP_DIR}"
  deploykube_istio_quit_sidecar >/dev/null 2>&1 || true
}

trap cleanup EXIT

load_prev_status() {
  if ! cm_json=$(kubectl -n "${NAMESPACE}" get configmap "${STATUS_CM}" -o json 2>/dev/null); then
    return
  fi
  while IFS== read -r key value; do
    PREV_STATUS["$key"]="$value"
  done < <(echo "${cm_json}" | jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"')
}

set_status() {
  STATUS["$1"]="$2"
}

get_prev() {
  local key="$1"
  printf '%s' "${PREV_STATUS[$key]:-}"
}

yaml_escape() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '%s' "$val"
}

write_status_configmap() {
  (( ${#STATUS[@]} == 0 )) && return
  local tmp="${TMP_DIR}/status.yaml"
  {
    printf "apiVersion: v1\nkind: ConfigMap\nmetadata:\n"
    printf "  name: %s\n  namespace: %s\n" "$STATUS_CM" "$NAMESPACE"
    printf "  labels:\n    deploykube.gitops/job: keycloak-bootstrap\n    app.kubernetes.io/name: keycloak\n"
    printf "data:\n"
    for key in $(printf '%s\n' "${!STATUS[@]}" | sort); do
      local value
      value=$(yaml_escape "${STATUS[$key]}")
      printf "  %s: \"%s\"\n" "$key" "$value"
    done
  } > "$tmp"
  kubectl apply -f "$tmp"
}

load_admin_credentials() {
  if [[ -n "${KEYCLOAK_ADMIN_USERNAME:-}" && -n "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
    return 0
  fi

  local attempts="${KEYCLOAK_ADMIN_SECRET_ATTEMPTS:-60}"
  local delay="${KEYCLOAK_ADMIN_SECRET_DELAY:-5}"
  for ((i=1; i<=attempts; i++)); do
    local secret_json
    if secret_json=$(kubectl -n "${NAMESPACE}" get secret "${ADMIN_CREDENTIALS_SECRET_NAME}" -o json 2>/dev/null); then
      KEYCLOAK_ADMIN_USERNAME=$(echo "${secret_json}" | jq -r '.data.username' | base64 -d)
      KEYCLOAK_ADMIN_PASSWORD=$(echo "${secret_json}" | jq -r '.data.password' | base64 -d)
      if [[ -n "${KEYCLOAK_ADMIN_USERNAME}" && -n "${KEYCLOAK_ADMIN_PASSWORD}" ]]; then
        export KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD
        return 0
      fi
      fail "Secret ${NAMESPACE}/${ADMIN_CREDENTIALS_SECRET_NAME} missing username/password keys"
    fi
    log "Secret ${NAMESPACE}/${ADMIN_CREDENTIALS_SECRET_NAME} not present yet; retry ${i}/${attempts}..."
    sleep "${delay}"
  done
  fail "Timed out waiting for Secret ${NAMESPACE}/${ADMIN_CREDENTIALS_SECRET_NAME}"
}

resolve_variable_spec() {
  local spec="$1"
  case "${spec}" in
    literal:*)
      printf '%s' "${spec#literal:}"
      ;;
    env:*)
      local env_name="${spec#env:}"
      local value="${!env_name:-}"
      [[ -z "${value}" ]] && fail "Variable map requested env ${env_name} but it is unset"
      printf '%s' "${value}"
      ;;
    secret:*)
      local ref="${spec#secret:}"
      local ns_name="${ref%%:*}"
      local key="${ref#*:}"
      local ns name
      if [[ "${ns_name}" == */* ]]; then
        ns="${ns_name%%/*}"
        name="${ns_name##*/}"
      else
        ns="${NAMESPACE}"
        name="${ns_name}"
      fi
      local encoded
      encoded=$(kubectl -n "${ns}" get secret "${name}" -o "jsonpath={.data.${key}}" 2>/dev/null || true)
      [[ -z "${encoded}" ]] && fail "Secret ${ns}/${name} missing key ${key} for variable map entry (${spec})"
      printf '%s' "${encoded}" | base64 -d
      ;;
    *)
      fail "Unsupported variable spec '${spec}' in ${VARIABLE_MAP_CONFIGMAP}"
      ;;
  esac
}

load_variable_map() {
  [[ -z "${VARIABLE_MAP_CONFIGMAP}" ]] && return
  local cm_json
  if ! cm_json=$(kubectl -n "${NAMESPACE}" get configmap "${VARIABLE_MAP_CONFIGMAP}" -o json 2>/dev/null); then
    fail "ConfigMap ${VARIABLE_MAP_CONFIGMAP} not found in namespace ${NAMESPACE}"
  fi
  while IFS== read -r key spec; do
    [[ -z "${key}" || -z "${spec}" ]] && continue
    local value
    value=$(resolve_variable_spec "${spec}")
    export "${key}=${value}"
  done < <(echo "${cm_json}" | jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"')
}

deployment_cfg() {
  local expr="$1"
  yq -r "${expr} // \"\"" "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true
}

load_deployment_config_snapshot() {
  local cm_json raw
  if ! cm_json=$(kubectl -n "${NAMESPACE}" get configmap "${DEPLOYKUBE_CONFIG_SNAPSHOT_NAME}" -o json 2>/dev/null); then
    log "DeploymentConfig snapshot ${NAMESPACE}/${DEPLOYKUBE_CONFIG_SNAPSHOT_NAME} not present; using existing env defaults."
    return 0
  fi

  raw=$(echo "${cm_json}" | jq -r --arg key "${DEPLOYKUBE_CONFIG_SNAPSHOT_KEY}" '.data[$key] // ""')
  if [[ -z "${raw}" ]]; then
    log "DeploymentConfig snapshot key ${DEPLOYKUBE_CONFIG_SNAPSHOT_KEY} missing in ${NAMESPACE}/${DEPLOYKUBE_CONFIG_SNAPSHOT_NAME}; using existing env defaults."
    return 0
  fi

  printf '%s\n' "${raw}" > "${DEPLOYMENT_CONFIG_FILE}"
  DEPLOYMENT_ID="$(deployment_cfg '.spec.deploymentId')"
  DEPLOYMENT_ENVIRONMENT_ID="$(deployment_cfg '.spec.environmentId')"

  [[ -n "${DEPLOYMENT_ID}" ]] && set_status "deployment.deploymentId" "${DEPLOYMENT_ID}"
  [[ -n "${DEPLOYMENT_ENVIRONMENT_ID}" ]] && set_status "deployment.environmentId" "${DEPLOYMENT_ENVIRONMENT_ID}"
}

set_env_if_present() {
  local env_name="$1"
  local value="$2"
  if [[ -n "${value}" ]]; then
    export "${env_name}=${value}"
  fi
}

export_hosts_from_deployment_config() {
  [[ -f "${DEPLOYMENT_CONFIG_FILE}" ]] || return 0

  local keycloak_host argocd_host forgejo_host vault_host grafana_host kiali_host harbor_host hubble_host
  keycloak_host="$(deployment_cfg '.spec.dns.hostnames.keycloak')"
  argocd_host="$(deployment_cfg '.spec.dns.hostnames.argocd')"
  forgejo_host="$(deployment_cfg '.spec.dns.hostnames.forgejo')"
  vault_host="$(deployment_cfg '.spec.dns.hostnames.vault')"
  grafana_host="$(deployment_cfg '.spec.dns.hostnames.grafana')"
  kiali_host="$(deployment_cfg '.spec.dns.hostnames.kiali')"
  harbor_host="$(deployment_cfg '.spec.dns.hostnames.harbor')"
  hubble_host="$(deployment_cfg '.spec.dns.hostnames.hubble')"

  if [[ -n "${keycloak_host}" ]]; then
    EXTERNAL_KEYCLOAK_HOST="https://${keycloak_host}"
    export KEYCLOAK_HOST="${EXTERNAL_KEYCLOAK_HOST}"
  fi
  set_env_if_present "ARGOCD_HOST" "${argocd_host}"
  set_env_if_present "FORGEJO_HOST" "${forgejo_host}"
  set_env_if_present "KEYCLOAK_VAULT_HOST" "${vault_host}"
  set_env_if_present "GRAFANA_HOST" "${grafana_host}"
  set_env_if_present "KIALI_HOST" "${kiali_host}"
  set_env_if_present "HARBOR_HOST" "${harbor_host}"
  set_env_if_present "HUBBLE_HOST" "${hubble_host}"

  if [[ -z "${ENABLE_DEV_K8S_ADMIN_BINDING:-}" || "${ENABLE_DEV_K8S_ADMIN_BINDING}" == "auto" ]]; then
    if [[ "${DEPLOYMENT_ENVIRONMENT_ID}" == "dev" ]]; then
      export ENABLE_DEV_K8S_ADMIN_BINDING="true"
    else
      export ENABLE_DEV_K8S_ADMIN_BINDING="false"
    fi
  fi
}

resolve_iam_value_ref() {
  local ref_path="$1"
  local secret_name secret_key secret_ns vault_path vault_key encoded secret_json
  secret_name="$(deployment_cfg "${ref_path}.secretName")"
  secret_key="$(deployment_cfg "${ref_path}.secretKey")"
  secret_ns="$(deployment_cfg "${ref_path}.namespace")"
  vault_path="$(deployment_cfg "${ref_path}.vaultPath")"
  vault_key="$(deployment_cfg "${ref_path}.vaultKey")"

  if [[ -n "${secret_name}" && -n "${secret_key}" ]]; then
    if [[ -z "${secret_ns}" ]]; then
      secret_ns="${NAMESPACE}"
    fi
    encoded="$(kubectl -n "${secret_ns}" get secret "${secret_name}" -o "jsonpath={.data.${secret_key}}" 2>/dev/null || true)"
    [[ -n "${encoded}" ]] || fail "IAM value ref secret ${secret_ns}/${secret_name} missing key ${secret_key}"
    printf '%s' "${encoded}" | base64 -d
    return 0
  fi

  if [[ -n "${vault_path}" && -n "${vault_key}" ]]; then
    if [[ "${vault_path}" != secret/data/* ]]; then
      vault_path="secret/data/${vault_path#secret/}"
    fi
    if secret_json=$(read_vault_secret "${vault_path}"); then
      local value
      value="$(echo "${secret_json}" | jq -r --arg k "${vault_key}" '.data.data[$k] // empty')"
      [[ -n "${value}" ]] || fail "IAM value ref Vault path ${vault_path} missing key ${vault_key}"
      printf '%s' "${value}"
      return 0
    fi
    fail "IAM value ref Vault path ${vault_path} not found"
  fi

  return 1
}

read_iam_mode_from_deployment_config() {
  IAM_MODE="standalone"
  IAM_PRIMARY_REALM="deploykube-admin"
  IAM_UPSTREAM_TYPE=""
  IAM_UPSTREAM_ALIAS="${KEYCLOAK_IAM_UPSTREAM_ALIAS}"
  IAM_FAIL_OPEN="true"
  IAM_OFFLINE_REQUIRED="false"
  IAM_OFFLINE_METHOD="password+otp"
  IAM_TARGET_REALMS=()

  if [[ -f "${DEPLOYMENT_CONFIG_FILE}" ]]; then
    local mode primary upstream_type upstream_alias fail_open offline_required offline_method
    mode="$(deployment_cfg '.spec.iam.mode')"
    primary="$(deployment_cfg '.spec.iam.primaryRealm')"
    upstream_type="$(deployment_cfg '.spec.iam.upstream.type')"
    upstream_alias="$(deployment_cfg '.spec.iam.upstream.alias')"
    fail_open="$(deployment_cfg '.spec.iam.hybrid.failOpen')"
    offline_required="$(deployment_cfg '.spec.iam.hybrid.offlineCredential.required')"
    offline_method="$(deployment_cfg '.spec.iam.hybrid.offlineCredential.method')"

    [[ -n "${mode}" ]] && IAM_MODE="${mode}"
    [[ -n "${primary}" ]] && IAM_PRIMARY_REALM="${primary}"
    [[ -n "${upstream_type}" ]] && IAM_UPSTREAM_TYPE="${upstream_type}"
    [[ -n "${upstream_alias}" ]] && IAM_UPSTREAM_ALIAS="${upstream_alias}"
    [[ -n "${fail_open}" ]] && IAM_FAIL_OPEN="${fail_open}"
    [[ -n "${offline_required}" ]] && IAM_OFFLINE_REQUIRED="${offline_required}"
    [[ -n "${offline_method}" ]] && IAM_OFFLINE_METHOD="${offline_method}"

    mapfile -t IAM_TARGET_REALMS < <(
      {
        printf '%s\n' "${IAM_PRIMARY_REALM}"
        yq -r '.spec.iam.secondaryRealms[]?' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true
      } | awk 'NF>0 && !seen[$0]++'
    )
  fi

  if (( ${#IAM_TARGET_REALMS[@]} == 0 )); then
    IAM_TARGET_REALMS=("deploykube-admin")
  fi

  set_status "iam.mode" "${IAM_MODE}"
  set_status "iam.primaryRealm" "${IAM_PRIMARY_REALM}"
  set_status "iam.upstream.type" "${IAM_UPSTREAM_TYPE:-none}"
  set_status "iam.upstream.alias" "${IAM_UPSTREAM_ALIAS}"
  set_status "iam.hybrid.failOpen" "${IAM_FAIL_OPEN}"
  set_status "iam.hybrid.offlineCredential.required" "${IAM_OFFLINE_REQUIRED}"
  set_status "iam.hybrid.offlineCredential.method" "${IAM_OFFLINE_METHOD}"
  set_status "iam.hybrid.health.type" "$(deployment_cfg '.spec.iam.hybrid.healthCheck.type')"
  set_status "iam.hybrid.health.url" "$(deployment_cfg '.spec.iam.hybrid.healthCheck.url')"
  set_status "iam.hybrid.health.host" "$(deployment_cfg '.spec.iam.hybrid.healthCheck.host')"
  set_status "iam.hybrid.health.port" "$(deployment_cfg '.spec.iam.hybrid.healthCheck.port')"
}

extract_template_variables() {
  local template="$1"
  grep -o '\${[A-Za-z0-9_]\+}' "${template}" 2>/dev/null | tr -d '${}' | sort -u || true
}

render_template_file() {
  local template="$1"
  [[ -f "${template}" ]] || fail "Template ${template} missing"
  local base
  base=$(basename "${template}")
  local rendered="${RENDER_DIR}/${base}"
  local k8s_render="${TMP_DIR}/${base}.k8s"
  local vars=()
  while IFS= read -r var; do
    [[ -z "${var}" ]] && continue
    vars+=("${var}")
    if [[ -z "${!var:-}" ]]; then
      fail "Template ${base} references ${var} but it is unset"
    fi
  done < <(extract_template_variables "${template}")

  local subst_vars=""
  if (( ${#vars[@]} > 0 )); then
    subst_vars=$(printf '${%s} ' "${vars[@]}")
    envsubst "${subst_vars}" < "${template}" > "${k8s_render}"
  else
    cp "${template}" "${k8s_render}"
  fi

  local realm_name
  realm_name=$(yq -r '.spec.realm.realm' "${k8s_render}")
  [[ -z "${realm_name}" || "${realm_name}" == "null" ]] && fail "Rendered template ${base} missing spec.realm.realm"

  if ! yq '.spec.realm' "${k8s_render}" > "${rendered}"; then
    fail "Unable to extract spec.realm from ${base}"
  fi

  local sha
  sha=$(sha256sum "${rendered}" | awk '{print $1}')
  RENDERED_REALM_SHA["${realm_name}"]="${sha}"
}

render_realm_templates() {
  [[ -d "${TEMPLATE_DIR}" ]] || fail "Template directory ${TEMPLATE_DIR} not found"
  log "Rendering Keycloak realm templates from ${TEMPLATE_DIR}..."
  for key in "${!RENDERED_REALM_SHA[@]}"; do
    unset "RENDERED_REALM_SHA[$key]"
  done
  load_variable_map
  mkdir -p "${RENDER_DIR}"
  local found="false"
  shopt -s nullglob
  for template in "${TEMPLATE_DIR}"/*.yaml; do
    found="true"
    render_template_file "${template}"
  done
  shopt -u nullglob
  [[ "${found}" == "true" ]] || fail "No realm templates found under ${TEMPLATE_DIR}"
}

run_keycloak_config_cli() {
  load_admin_credentials
  local cli_user="${KEYCLOAK_ADMIN_USERNAME:-}"
  local cli_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
  [[ -n "${cli_user}" && -n "${cli_pass}" ]] || fail "KEYCLOAK_ADMIN_USERNAME/PASSWORD must be set for keycloak-config-cli"

  local files_pattern="file://${RENDER_DIR}/*.yaml"
  if ! ls "${RENDER_DIR}"/*.yaml >/dev/null 2>&1; then
    fail "No rendered realms present under ${RENDER_DIR}"
  fi

  local exit_code=0
  log "Applying rendered realms via keycloak-config-cli..."
  if keycloak-config-cli \
      --keycloak.url="${KEYCLOAK_API}" \
      --keycloak.user="${cli_user}" \
      --keycloak.password="${cli_pass}" \
      --keycloak.login-realm=master \
      --keycloak.ssl-verify=false \
      --import.files.locations="${files_pattern}" \
      --import.var-substitution.enabled=false; then
    exit_code=0
  else
    exit_code=$?
    set_status "realms.configCli.lastExitCode" "${exit_code}"
    fail "keycloak-config-cli import failed (exit ${exit_code})"
  fi

  set_status "realms.configCli.lastExitCode" "${exit_code}"
  set_status "realms.configCli.lastRun" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

wait_for_object_existence() {
  local description="$1"
  local resource="$2"
  local name="$3"
  local namespace="$4"
  local attempts="${5:-60}"
  local delay="${6:-5}"
  for ((i=1; i<=attempts; i++)); do
    if kubectl -n "${namespace}" get "${resource}/${name}" >/dev/null 2>&1; then
      return 0
    fi
    log "${description} not found yet; retry ${i}/${attempts}..."
    sleep "${delay}"
  done
  fail "Timed out waiting for ${description}"
}

wait_for_resource_condition() {
  local description="$1"
  local resource="$2"
  local name="$3"
  local namespace="$4"
  local condition="$5"
  local timeout="$6"
  log "Waiting for ${description}..."
  kubectl -n "${namespace}" wait --for="condition=${condition}" --timeout="${timeout}" "${resource}/${name}"
}

wait_for_http_route_acceptance() {
  local attempts=120
  local delay=5
  for ((i=1; i<=attempts; i++)); do
    local status
    status=$(kubectl -n "${NAMESPACE}" get "httproutes.gateway.networking.k8s.io/${HTTPROUTE_NAME}" -o json | jq -r '
      (.status.parents // []) | any(.conditions[]?; .type == "Accepted" and .status == "True")
    ')
    if [[ "${status}" == "true" ]]; then
      log "HTTPRoute ${HTTPROUTE_NAME} accepted by gateway."
      return 0
    fi
    log "HTTPRoute ${HTTPROUTE_NAME} not accepted yet; retry ${i}/${attempts}..."
    sleep "${delay}"
  done
  fail "Timed out waiting for HTTPRoute ${HTTPROUTE_NAME} to be accepted"
}

wait_for_ready_conditions() {
  wait_for_object_existence "Keycloak CR ${KEYCLOAK_NAME}" "keycloaks.k8s.keycloak.org" "${KEYCLOAK_NAME}" "${NAMESPACE}"
  wait_for_resource_condition "Keycloak CR ${KEYCLOAK_NAME} to become Ready" "keycloaks.k8s.keycloak.org" "${KEYCLOAK_NAME}" "${NAMESPACE}" "Ready" "900s"

  wait_for_object_existence "HTTPRoute ${HTTPROUTE_NAME}" "httproutes.gateway.networking.k8s.io" "${HTTPROUTE_NAME}" "${NAMESPACE}"
  wait_for_http_route_acceptance()

  for ns in "${NAMESPACE}" "${ISTIO_NAMESPACE}"; do
    wait_for_object_existence "Certificate ${TLS_SECRET_NAME} in ${ns}" "certificate" "${TLS_SECRET_NAME}" "${ns}"
    wait_for_resource_condition "Certificate ${TLS_SECRET_NAME} in ${ns} to become Ready" "certificate" "${TLS_SECRET_NAME}" "${ns}" "Ready" "300s"
  done

  load_admin_credentials
}

secret_checksum() {
  jq -r '.data | to_entries | sort_by(.key) | map(.value) | join("")' | sha256sum | awk '{print $1}'
}

secret_serial() {
  local crt
  crt=$(jq -r '.data["tls.crt"] // empty' <<<"$1")
  [[ -z "${crt}" ]] && { echo "unknown"; return; }
  echo "${crt}" | base64 -d | openssl x509 -noout -serial | cut -d'=' -f2
}

sync_tls_secret() {
  local src_json dest_json src_checksum dest_checksum src_serial dest_serial
  src_json=$(kubectl -n "${ISTIO_NAMESPACE}" get secret "${TLS_SECRET_NAME}" -o json) || fail "Source TLS secret missing in ${ISTIO_NAMESPACE}"
  src_checksum=$(echo "${src_json}" | secret_checksum)
  src_serial=$(secret_serial "${src_json}")

  if dest_json=$(kubectl -n "${NAMESPACE}" get secret "${TLS_SECRET_NAME}" -o json 2>/dev/null); then
    dest_checksum=$(echo "${dest_json}" | secret_checksum)
    dest_serial=$(secret_serial "${dest_json}")
  else
    dest_checksum=""
    dest_serial="absent"
  fi

  if [[ "${src_checksum}" != "${dest_checksum}" ]]; then
    log "Syncing TLS secret into ${NAMESPACE}..."
    {
      cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${TLS_SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: keycloak
  annotations:
    darksite.cloud/keycloak-tls-checksum: "${src_checksum}"
type: kubernetes.io/tls
data:
EOF
      echo "${src_json}" | jq -r '.data | to_entries[] | "  \(.key): \(.value)"'
    } | kubectl apply -f -
    dest_serial="${src_serial}"
    dest_checksum="${src_checksum}"
  else
    log "TLS secret already up to date in ${NAMESPACE}."
  fi

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  set_status "tls.gateway.checksum" "${src_checksum}"
  set_status "tls.gateway.serial" "${src_serial}"
  set_status "tls.keycloak.checksum" "${dest_checksum}"
  set_status "tls.keycloak.serial" "${dest_serial}"
  set_status "tls.lastSync" "${timestamp}"
}

keycloak_login() {
  KEYCLOAK_LOGIN_SOURCE="unknown"
  local attempts="${KEYCLOAK_LOGIN_ATTEMPTS:-120}"
  local delay="${KEYCLOAK_LOGIN_DELAY:-5}"

  log "Authenticating with Keycloak API at ${KEYCLOAK_API} (may take a few minutes after CR Ready)..."
  for ((i=1; i<=attempts; i++)); do
    local secret_json bootstrap_user bootstrap_pass
    bootstrap_user=""
    bootstrap_pass=""

    if secret_json=$(kubectl -n "${NAMESPACE}" get secret "${INITIAL_ADMIN_SECRET_NAME}" -o json 2>/dev/null); then
      bootstrap_user=$(echo "${secret_json}" | jq -r '.data.username // empty' | base64 -d 2>/dev/null || true)
      bootstrap_pass=$(echo "${secret_json}" | jq -r '.data.password // empty' | base64 -d 2>/dev/null || true)
      if [[ -n "${bootstrap_user}" && -n "${bootstrap_pass}" ]]; then
        if kcadm.sh config credentials \
          --server "${KEYCLOAK_API}" \
          --realm master \
          --user "${bootstrap_user}" \
          --password "${bootstrap_pass}" \
          >/dev/null 2>&1; then
          KEYCLOAK_LOGIN_SOURCE="bootstrap"
          log "Authenticated with operator bootstrap credential."
          return
        fi
      fi
    fi

    local vault_admin="${KEYCLOAK_ADMIN_USERNAME:-}"
    local vault_admin_password="${KEYCLOAK_ADMIN_PASSWORD:-}"
    if [[ -n "${vault_admin}" && -n "${vault_admin_password}" ]]; then
      if kcadm.sh config credentials \
        --server "${KEYCLOAK_API}" \
        --realm master \
        --user "${vault_admin}" \
        --password "${vault_admin_password}" \
        >/dev/null 2>&1; then
        KEYCLOAK_LOGIN_SOURCE="vault"
        log "Authenticated with Vault admin credential."
        return
      fi
    fi

    log "Keycloak login not ready yet; retry ${i}/${attempts}..."
    sleep "${delay}"
  done

  fail "Unable to authenticate with Keycloak using either ${NAMESPACE}/${INITIAL_ADMIN_SECRET_NAME} or ${NAMESPACE}/${ADMIN_CREDENTIALS_SECRET_NAME}."
}



ensure_master_admin() {
  load_admin_credentials
  local desired_user="${KEYCLOAK_ADMIN_USERNAME:-}"
  local desired_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
  if [[ -z "${desired_user}" || -z "${desired_pass}" ]]; then
    log "KEYCLOAK_ADMIN_USERNAME/PASSWORD not set; skipping master admin sync."
    return
  fi

  log "Ensuring master realm admin '${desired_user}' exists and matches Vault secret..."
  if ! kcadm.sh create users -r master \
      -s username="${desired_user}" \
      -s enabled=true \
      -s emailVerified=true \
      -s firstName=Deploykube \
      -s lastName=Admin \
      -s 'requiredActions=[]' \
      >/dev/null 2>&1; then
    log "Master admin ${desired_user} already present (create skipped)."
  fi

  kcadm_retry "set password for master/${desired_user}" \
    kcadm.sh set-password -r master \
      --username "${desired_user}" \
      --new-password "${desired_pass}" \
      --temporary=false >/dev/null

  log "Ensuring ${desired_user} has realm-management/realm-admin rights..."
  local role_timeout="${KEYCLOAK_KCADM_ROLE_GRANT_TIMEOUT:-30s}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${role_timeout}" kcadm.sh add-roles -r master \
      --uusername "${desired_user}" \
      --cclientid realm-management \
      --rolename realm-admin >/dev/null 2>&1 || log "WARN: unable to grant realm-management/realm-admin to ${desired_user} (continuing)"
  else
    kcadm.sh add-roles -r master \
      --uusername "${desired_user}" \
      --cclientid realm-management \
      --rolename realm-admin >/dev/null 2>&1 || log "WARN: unable to grant realm-management/realm-admin to ${desired_user} (continuing)"
  fi

  log "Ensuring ${desired_user} has the master realm 'admin' role..."
  if command -v timeout >/dev/null 2>&1; then
    timeout "${role_timeout}" kcadm.sh add-roles -r master \
      --uusername "${desired_user}" \
      --rolename admin >/dev/null 2>&1 || log "WARN: unable to grant master/admin to ${desired_user} (continuing)"
  else
    kcadm.sh add-roles -r master \
      --uusername "${desired_user}" \
      --rolename admin >/dev/null 2>&1 || log "WARN: unable to grant master/admin to ${desired_user} (continuing)"
  fi

  # From here on we need a principal that can manage non-master realms.
  # The operator bootstrap credential is often limited and can yield HTTP 401 later in the flow.
  log "Switching Keycloak admin session to master/${desired_user}..."
  if command -v timeout >/dev/null 2>&1; then
    timeout "${role_timeout}" kcadm.sh config credentials \
      --server "${KEYCLOAK_API}" \
      --realm master \
      --user "${desired_user}" \
      --password "${desired_pass}" \
      >/dev/null 2>&1 || log "WARN: unable to switch kcadm credentials to ${desired_user} (continuing)"
  else
    kcadm.sh config credentials \
      --server "${KEYCLOAK_API}" \
      --realm master \
      --user "${desired_user}" \
      --password "${desired_pass}" \
      >/dev/null 2>&1 || log "WARN: unable to switch kcadm credentials to ${desired_user} (continuing)"
  fi

  set_status "admin.username" "${desired_user}"

  if [[ "${REMOVE_TEMP_ADMIN:-false}" == "true" ]]; then
    local temp_tmp temp_id
    temp_tmp="${TMP_DIR}/temp-admin.json"
    if kcadm.sh get users -r master -q username=temp-admin >"${temp_tmp}" 2>/dev/null; then
      temp_id=$(jq -r '.[0].id // empty' "${temp_tmp}")
      if [[ -n "${temp_id}" ]]; then
        log "Removing bootstrap temp-admin user"
        kcadm.sh delete "users/${temp_id}" -r master >/dev/null || true
      fi
    fi
  fi
}

ensure_realm_user_password() {
  local realm="$1"
  local username="$2"
  local password="$3"
  local first_name="${4:-}"
  local last_name="${5:-}"
  local email="${6:-}"
  local create_timeout="${KEYCLOAK_KCADM_COMMAND_TIMEOUT:-30s}"
  local create_rc=0
  if [[ -z "${realm}" || -z "${username}" || -z "${password}" ]]; then
    fail "ensure_realm_user_password: realm/user/password must be set"
  fi
  if [[ -z "${email}" ]]; then
    email="${username}@example.test"
  fi

  local create_args=(
    -s "username=${username}"
    -s "enabled=true"
    -s "emailVerified=true"
    -s "email=${email}"
  )
  if [[ -n "${first_name}" ]]; then
    create_args+=(-s "firstName=${first_name}")
  fi
  if [[ -n "${last_name}" ]]; then
    create_args+=(-s "lastName=${last_name}")
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${create_timeout}" kcadm.sh create users -r "${realm}" "${create_args[@]}" >/dev/null 2>&1 || create_rc=$?
  elif ! kcadm.sh create users -r "${realm}" "${create_args[@]}" >/dev/null 2>&1; then
    create_rc=$?
  fi

  if [[ "${create_rc}" -eq 0 ]]; then
    log "User ${username} created in realm ${realm}."
  elif [[ "${create_rc}" -eq 124 ]]; then
    log "WARN: create user ${realm}/${username} timed out after ${create_timeout}; verifying existence."
  else
    log "User ${username} already present in realm ${realm} (create skipped)."
  fi

  kcadm_retry "set password for ${realm}/${username}" \
    kcadm.sh set-password -r "${realm}" \
      --username "${username}" \
      --new-password "${password}" \
      --temporary=false >/dev/null

  # Ensure the account can use the password grant non-interactively.
  # If requiredActions are present (e.g. UPDATE_PASSWORD / CONFIGURE_TOTP),
  # Keycloak returns: "invalid_grant" / "Account is not fully set up".
  local user_id
  user_id=$(kcadm_retry "lookup user ${realm}/${username}" kcadm.sh get users -r "${realm}" -q username="${username}" | jq -r '.[0].id // empty')
  if [[ -n "${user_id}" ]]; then
    local update_args=(
      -s "enabled=true"
      -s "emailVerified=true"
      -s "email=${email}"
      -s 'requiredActions=[]'
    )
    if [[ -n "${first_name}" ]]; then
      update_args+=(-s "firstName=${first_name}")
    fi
    if [[ -n "${last_name}" ]]; then
      update_args+=(-s "lastName=${last_name}")
    fi
    kcadm_retry "update user ${realm}/${username} profile/requiredActions" \
      kcadm.sh update "users/${user_id}" -r "${realm}" \
        "${update_args[@]}" >/dev/null 2>&1 || true
  fi

  set_status "user.${realm}.${username}.lastSynced" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

sync_dev_user() {
  local secret_json username password
  if ! secret_json=$(kubectl -n "${NAMESPACE}" get secret keycloak-dev-user -o json 2>/dev/null); then
    log "Secret keycloak-dev-user missing; skipping developer user sync."
    return
  fi
  username=$(echo "${secret_json}" | jq -r '.data.username' | base64 -d)
  password=$(echo "${secret_json}" | jq -r '.data.password' | base64 -d)
  if [[ -z "${username}" || -z "${password}" ]]; then
    fail "keycloak-dev-user secret missing username/password fields"
  fi

  log "Ensuring developer user '${username}' exists in admin/apps realms."
  ensure_realm_user_password "deploykube-admin" "${username}" "${password}" "DeployKube" "Developer" "${username}@example.test"
  ensure_realm_user_password "deploykube-apps" "${username}" "${password}" "DeployKube" "Developer" "${username}@example.test"

  if [[ "${ENABLE_DEV_K8S_ADMIN_BINDING:-}" == "true" ]]; then
    # In mac dev we want a deterministic, repeatable way to get kubectl access via OIDC.
    # Bind the developer user to the Kubernetes admin group so the OIDC groups claim
    # is present and Kubernetes RBAC works out-of-the-box.
    local token user_id group_json dk_admin_id
    token=$(master_admin_token)
    user_id=$(curl -sSf -H "Authorization: Bearer ${token}" \
      "${KEYCLOAK_API%/}/admin/realms/deploykube-admin/users?username=${username}" | jq -r '.[0].id // empty')
    [[ -n "${user_id}" ]] || fail "developer user '${username}' not found after ensure_realm_user_password"

    group_json=$(curl -sSf -H "Authorization: Bearer ${token}" \
      "${KEYCLOAK_API%/}/admin/realms/deploykube-admin/groups")
    dk_admin_id=$(echo "${group_json}" | jq -r '.[] | select(.name=="dk-platform-admins") | .id' | head -n 1)
    if [[ -n "${dk_admin_id}" ]]; then
      curl -sSf -X PUT -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_API%/}/admin/realms/deploykube-admin/users/${user_id}/groups/${dk_admin_id}" >/dev/null
    else
      log "Group dk-platform-admins not found; skipping membership for ${username}"
    fi

    set_status "user.deploykube-admin.${username}.groupsSynced" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi
}

master_admin_token() {
  load_admin_credentials
  local cli_user="${KEYCLOAK_ADMIN_USERNAME:-}"
  local cli_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
  [[ -n "${cli_user}" && -n "${cli_pass}" ]] || fail "KEYCLOAK_ADMIN_USERNAME/PASSWORD must be set for master_admin_token"

  curl -sSf -X POST "${KEYCLOAK_API%/}/realms/master/protocol/openid-connect/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${cli_user}" \
    --data-urlencode "password=${cli_pass}" \
    | jq -r '.access_token'
}

sync_automation_user_from_secret() {
  local secret_name="$1" primary_group="$2" secondary_group="${3:-}"
  local secret_json username password
  if ! secret_json=$(kubectl -n "${NAMESPACE}" get secret "${secret_name}" -o json 2>/dev/null); then
    log "Secret ${secret_name} missing; skipping automation user sync."
    return 1
  fi
  username=$(echo "${secret_json}" | jq -r '.data.username' | base64 -d)
  password=$(echo "${secret_json}" | jq -r '.data.password' | base64 -d)
  if [[ -z "${username}" || -z "${password}" ]]; then
    fail "${secret_name} secret missing username/password fields"
  fi

  log "Ensuring automation user '${username}' exists in deploykube-admin realm."
  ensure_realm_user_password "deploykube-admin" "${username}" "${password}" "DeployKube" "Automation" "${username}@example.test"

  local token user_id group_json group_name group_id
  token=$(master_admin_token)
  user_id=$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/deploykube-admin/users?username=${username}" | jq -r '.[0].id // empty')
  [[ -n "${user_id}" ]] || fail "automation user '${username}' not found after ensure_realm_user_password"

  group_json=$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/deploykube-admin/groups")

  for group_name in "${primary_group}" "${secondary_group}"; do
    [[ -z "${group_name}" ]] && continue
    group_id=$(echo "${group_json}" | jq -r --arg n "${group_name}" '.[] | select(.name==$n) | .id' | head -n 1)
    if [[ -n "${group_id}" ]]; then
      curl -sSf -X PUT -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_API%/}/admin/realms/deploykube-admin/users/${user_id}/groups/${group_id}" >/dev/null
    else
      log "Group ${group_name} not found; skipping membership for ${username}"
    fi
  done

  set_status "user.deploykube-admin.${username}.groupsSynced" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  return 0
}

sync_automation_users() {
  local argocd_synced=0
  if sync_automation_user_from_secret "keycloak-argocd-automation-user" "dk-bot-argocd-sync"; then
    argocd_synced=1
  fi

  # Backward compatibility while legacy secret paths are still present.
  if [[ "${argocd_synced}" -eq 0 ]]; then
    sync_automation_user_from_secret "keycloak-automation-user" "dk-bot-argocd-sync" || true
  fi

  sync_automation_user_from_secret "keycloak-vault-automation-user" "dk-bot-vault-writer" || true
}

record_realm_status() {
  log "Recording rendered realm checksums..."
  for realm in "${!RENDERED_REALM_SHA[@]}"; do
    set_status "realm.${realm}.sha256" "${RENDERED_REALM_SHA[$realm]}"
  done
}

import_realms() {
  render_realm_templates
  run_keycloak_config_cli
  record_realm_status
}

obtain_vault_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    return
  fi

  case "${VAULT_LOGIN_METHOD}" in
    kubernetes)
      [[ -f "${SERVICEACCOUNT_TOKEN_PATH}" ]] || fail "ServiceAccount token missing at ${SERVICEACCOUNT_TOKEN_PATH}"
      local jwt payload response token
      jwt=$(<"${SERVICEACCOUNT_TOKEN_PATH}") || fail "Unable to read ServiceAccount token from ${SERVICEACCOUNT_TOKEN_PATH}"
      payload=$(jq -n --arg role "${VAULT_K8S_ROLE}" --arg jwt "${jwt}" '{role:$role,jwt:$jwt}')
      if ! response=$(curl -sS -X POST \
        -H "Content-Type: application/json" \
        --data "${payload}" \
        "${VAULT_ADDR%/}/v1/auth/kubernetes/login"); then
        fail "Vault Kubernetes login failed for role ${VAULT_K8S_ROLE}"
      fi
      token=$(echo "${response}" | jq -r '.auth.client_token // empty')
      [[ -z "${token}" ]] && fail "Vault Kubernetes login response missing client_token for role ${VAULT_K8S_ROLE}"
      VAULT_TOKEN="${token}"
      export VAULT_TOKEN
      ;;
    *)
      fail "Unsupported VAULT_LOGIN_METHOD '${VAULT_LOGIN_METHOD}' and no VAULT_TOKEN provided"
      ;;
  esac
}

vault_api() {
  obtain_vault_token
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local tmp="${TMP_DIR}/vault-$(date +%s%N)"
  local url="${VAULT_ADDR%/}/v1/${path}"
  local code
  if [[ -n "${body}" ]]; then
    code=$(curl -sS -w '%{http_code}' -o "${tmp}" -X "${method}" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${body}" "${url}" || true)
  else
    code=$(curl -sS -w '%{http_code}' -o "${tmp}" -X "${method}" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      "${url}" || true)
  fi
  echo "${code}" "${tmp}"
}

read_vault_secret() {
  local path="$1"
  read -r code tmp <<<"$(vault_api GET "${path}")"
  if [[ "${code}" == "200" ]]; then
    cat "${tmp}"
    rm -f "${tmp}"
    return 0
  elif [[ "${code}" == "404" ]]; then
    rm -f "${tmp}"
    return 1
  else
    cat "${tmp}" >&2
    rm -f "${tmp}"
    fail "Vault read for ${path} failed (HTTP ${code})"
  fi
}

write_vault_secret() {
  local path="$1"
  local payload="$2"
  read -r code tmp <<<"$(vault_api POST "${path}" "${payload}")"
  if [[ "${code}" =~ ^20 ]]; then
    cat "${tmp}"
    rm -f "${tmp}"
  else
    cat "${tmp}" >&2
    rm -f "${tmp}"
    fail "Vault write for ${path} failed (HTTP ${code})"
  fi
}

fetch_client_secret() {
  local realm="$1" client_id="$2"
  local client_json client_uuid secret_json secret_value

  client_json=$(kcadm_retry "lookup client ${realm}/${client_id}" kcadm.sh get clients -r "${realm}" -q "clientId=${client_id}")
  client_uuid=$(echo "${client_json}" | jq -r '.[0].id // empty')
  [[ -z "${client_uuid}" ]] && fail "Client ${client_id} not found in realm ${realm}"

  local attempts="${KEYCLOAK_CLIENT_SECRET_ATTEMPTS:-10}"
  local delay="${KEYCLOAK_CLIENT_SECRET_DELAY:-3}"
  for ((i=1; i<=attempts; i++)); do
    local err_file="${TMP_DIR}/kcadm-client-secret-err-$(date +%s%N)"
    secret_json="$(kcadm.sh get "clients/${client_uuid}/client-secret" -r "${realm}" 2>"${err_file}" || true)"
    if [[ -s "${err_file}" ]]; then
      log "WARN: client-secret fetch emitted stderr (attempt ${i}/${attempts}): $(tail -n 2 "${err_file}" || true)" >&2
    fi
    rm -f "${err_file}" || true
    if echo "${secret_json}" | jq -e '.value' >/dev/null 2>&1; then
      secret_value="$(echo "${secret_json}" | jq -r '.value // empty')"
      if [[ -n "${secret_value}" ]]; then
        echo "${secret_value}"
        return 0
      fi
    fi

    if [[ "${i}" -lt "${attempts}" ]]; then
      log "WARN: failed to fetch client secret for ${realm}/${client_id} (attempt ${i}/${attempts}); retrying after ${delay}s"
      printf '%s\n' "${secret_json}" | head -n 2 >&2
      sleep "${delay}"
    fi
  done

  printf '%s\n' "${secret_json}" >&2
  fail "Failed to fetch client secret for ${realm}/${client_id} after ${attempts} attempts"
}

patch_secret_if_present() {
  local namespace="$1" name="$2" patch="$3"
  if ! kubectl -n "${namespace}" get secret "${name}" >/dev/null 2>&1; then
    log "Secret ${namespace}/${name} not present yet; skipping patch."
    return
  fi
  kubectl -n "${namespace}" patch secret "${name}" --type merge -p "${patch}" >/dev/null
}

sync_oidc_clients() {
  local timestamp realm client_id vault_key secret_value vault_client_id vault_secret_path
  realm="deploykube-admin"
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  vault_client_id="${KEYCLOAK_VAULT_CLIENT_ID:-vault-cli}"
  vault_secret_path="secret/data/keycloak/vault-client"

  # Only sync secrets for clients that Keycloak may rotate/regenerate and that have downstream consumers
  # (Argo CD, Forgejo, Vault CLI). Other platform clients (e.g. Kiali/Hubble) are sourced from Vault and
  # rendered into realm templates, so they don't require a Keycloak→Vault back-propagation step here.
  for client_id in argocd forgejo "${vault_client_id}"; do
    log "Reconciling OIDC client ${client_id}..."
    secret_value=$(fetch_client_secret "${realm}" "${client_id}")
    [[ -z "${secret_value}" ]] && fail "Empty secret returned for client ${client_id}"

    local vault_path
    if [[ "${client_id}" == "${vault_client_id}" ]]; then
      vault_path="${vault_secret_path}"
    else
      vault_path="secret/data/keycloak/${client_id}-client"
    fi
    local current_secret current_id current_version new_version payload
    if vault_json=$(read_vault_secret "${vault_path}"); then
      current_secret=$(echo "${vault_json}" | jq -r '.data.data.clientSecret // empty')
      current_id=$(echo "${vault_json}" | jq -r '.data.data.clientId // empty')
      current_version=$(echo "${vault_json}" | jq -r '.data.metadata.version // "0"')
    else
      current_secret=""
      current_id=""
      current_version="0"
    fi

    if [[ "${current_secret}" != "${secret_value}" || "${current_id}" != "${client_id}" ]]; then
      log "Updating Vault secret ${vault_path}..."
      payload=$(jq -n --arg id "${client_id}" --arg secret "${secret_value}" '{data:{clientId:$id,clientSecret:$secret}}')
      vault_resp=$(write_vault_secret "${vault_path}" "${payload}")
      # Vault KV v2 commonly returns HTTP 204 with an empty body for writes.
      # Avoid hard-failing on a non-JSON response; read back the secret to obtain the metadata version.
      new_version="$(echo "${vault_resp}" | jq -r '.data.version // empty' 2>/dev/null || true)"
      if [[ -z "${new_version}" ]]; then
        if vault_json_post=$(read_vault_secret "${vault_path}"); then
          new_version="$(echo "${vault_json_post}" | jq -r '.data.metadata.version // "unknown"' 2>/dev/null || echo "unknown")"
        else
          new_version="unknown"
        fi
      fi
    else
      new_version="${current_version}"
    fi

    case "${client_id}" in
      argocd)
        patch_secret_if_present "${ARGOCD_NAMESPACE}" "argocd-secret" \
          "$(jq -n --arg value "${secret_value}" --arg ts "${timestamp}" '{stringData: {"oidc.clientSecret": $value}, metadata: {annotations: {"darksite.cloud/keycloak-last-sync": $ts}}}')"
        set_status "secret.argocd.lastPatched" "${timestamp}"
        set_status "vault.argocd.version" "${new_version}"
        ;;
      forgejo)
        patch_secret_if_present "${FORGEJO_NAMESPACE}" "forgejo-oidc-client" \
          "$(jq -n --arg id "${client_id}" --arg value "${secret_value}" --arg ts "${timestamp}" '{stringData: {"key": $id, "secret": $value}, metadata: {annotations: {"darksite.cloud/keycloak-last-sync": $ts}}}')"
        set_status "secret.forgejo.lastPatched" "${timestamp}"
        set_status "vault.forgejo.version" "${new_version}"
        ;;
      "${vault_client_id}")
        set_status "vault.vault-cli.version" "${new_version}"
        ;;
    esac
  done

  set_status "vault.lastSync" "${timestamp}"
}

ensure_device_code_grant_enabled() {
  local realm="$1" client_id="$2"
  local client_json client_uuid

  log "Ensuring OAuth2 Device Authorization Grant is enabled for ${realm}/${client_id}..."
  client_json=$(kcadm_retry "lookup client ${realm}/${client_id}" kcadm.sh get clients -r "${realm}" -q "clientId=${client_id}")
  client_uuid=$(echo "${client_json}" | jq -r '.[0].id // empty' 2>/dev/null || true)
  [[ -z "${client_uuid}" ]] && fail "Client ${client_id} not found in realm ${realm}"

  # Keycloak stores this client toggle in the attributes map.
  kcadm_retry "enable device-code grant for ${realm}/${client_id}" \
    kcadm.sh update "clients/${client_uuid}" -r "${realm}" \
      -s 'attributes."oauth2.device.authorization.grant.enabled"="true"' >/dev/null
}

ensure_k8s_oidc_runtime_smoke_client() {
  local realm="deploykube-admin"
  local client_id="${KEYCLOAK_K8S_OIDC_RUNTIME_SMOKE_CLIENT_ID:-k8s-oidc-runtime-smoke}"
  local audience_client="${KEYCLOAK_K8S_OIDC_RUNTIME_SMOKE_AUDIENCE_CLIENT_ID:-kubernetes-api}"
  local desired_group="${KEYCLOAK_K8S_OIDC_RUNTIME_SMOKE_GROUP:-dk-platform-admins}"
  local vault_path="secret/data/keycloak/${client_id}-client"

  log "Ensuring Kubernetes OIDC runtime smoke client ${realm}/${client_id} exists..."

  local client_json client_uuid
  client_json=$(kcadm_retry "lookup client ${realm}/${client_id}" kcadm.sh get clients -r "${realm}" -q "clientId=${client_id}")
  client_uuid=$(echo "${client_json}" | jq -r '.[0].id // empty' 2>/dev/null || true)

  if [[ -z "${client_uuid}" ]]; then
    kcadm_retry "create client ${realm}/${client_id}" \
      kcadm.sh create clients -r "${realm}" \
        -s "clientId=${client_id}" \
        -s "name=Kubernetes OIDC runtime smoke" \
        -s "protocol=openid-connect" \
        -s "enabled=true" \
        -s "publicClient=false" \
        -s "serviceAccountsEnabled=true" \
        -s "standardFlowEnabled=false" \
        -s "directAccessGrantsEnabled=false" \
        -s "clientAuthenticatorType=client-secret" >/dev/null

    client_json=$(kcadm_retry "lookup client ${realm}/${client_id} (post-create)" kcadm.sh get clients -r "${realm}" -q "clientId=${client_id}")
    client_uuid=$(echo "${client_json}" | jq -r '.[0].id // empty' 2>/dev/null || true)
    [[ -n "${client_uuid}" ]] || fail "Client ${client_id} not found in realm ${realm} after create"
  else
    kcadm_retry "reconcile client ${realm}/${client_id} settings" \
      kcadm.sh update "clients/${client_uuid}" -r "${realm}" \
        -s "enabled=true" \
        -s "publicClient=false" \
        -s "serviceAccountsEnabled=true" \
        -s "standardFlowEnabled=false" \
        -s "directAccessGrantsEnabled=false" \
        -s "clientAuthenticatorType=client-secret" >/dev/null
  fi

  local mappers_json
  mappers_json="$(kcadm_retry "list protocol mappers for ${realm}/${client_id}" \
    kcadm.sh get "clients/${client_uuid}/protocol-mappers/models" -r "${realm}")"

  local groups_mapper_id
  groups_mapper_id="$(echo "${mappers_json}" | jq -r '.[] | select(.name=="groups") | .id' 2>/dev/null | head -n 1)"
  if [[ -z "${groups_mapper_id}" ]]; then
    kcadm_retry "create groups mapper for ${realm}/${client_id}" \
      kcadm.sh create "clients/${client_uuid}/protocol-mappers/models" -r "${realm}" \
        -s "name=groups" \
        -s "protocol=openid-connect" \
        -s "protocolMapper=oidc-group-membership-mapper" \
        -s "consentRequired=false" \
        -s 'config."full.path"="false"' \
        -s 'config."id.token.claim"="true"' \
        -s 'config."access.token.claim"="true"' \
        -s 'config."userinfo.token.claim"="true"' \
        -s 'config."claim.name"="groups"' >/dev/null
  else
    kcadm_retry "reconcile groups mapper for ${realm}/${client_id}" \
      kcadm.sh update "clients/${client_uuid}/protocol-mappers/models/${groups_mapper_id}" -r "${realm}" \
        -s "protocolMapper=oidc-group-membership-mapper" \
        -s "consentRequired=false" \
        -s 'config."full.path"="false"' \
        -s 'config."id.token.claim"="true"' \
        -s 'config."access.token.claim"="true"' \
        -s 'config."userinfo.token.claim"="true"' \
        -s 'config."claim.name"="groups"' >/dev/null
  fi

  local aud_mapper_name="audience-${audience_client}"
  local aud_mapper_id
  aud_mapper_id="$(echo "${mappers_json}" | jq -r --arg name "${aud_mapper_name}" '.[] | select(.name==$name) | .id' 2>/dev/null | head -n 1)"
  if [[ -z "${aud_mapper_id}" ]]; then
    kcadm_retry "create audience mapper for ${realm}/${client_id} (aud=${audience_client})" \
      kcadm.sh create "clients/${client_uuid}/protocol-mappers/models" -r "${realm}" \
        -s "name=${aud_mapper_name}" \
        -s "protocol=openid-connect" \
        -s "protocolMapper=oidc-audience-mapper" \
        -s "consentRequired=false" \
        -s 'config."included.client.audience"='"${audience_client}"'' \
        -s 'config."id.token.claim"="false"' \
        -s 'config."access.token.claim"="true"' \
        -s 'config."userinfo.token.claim"="false"' >/dev/null
  else
    kcadm_retry "reconcile audience mapper for ${realm}/${client_id} (aud=${audience_client})" \
      kcadm.sh update "clients/${client_uuid}/protocol-mappers/models/${aud_mapper_id}" -r "${realm}" \
        -s "protocolMapper=oidc-audience-mapper" \
        -s "consentRequired=false" \
        -s 'config."included.client.audience"='"${audience_client}"'' \
        -s 'config."id.token.claim"="false"' \
        -s 'config."access.token.claim"="true"' \
        -s 'config."userinfo.token.claim"="false"' >/dev/null
  fi

  log "Ensuring ${realm}/${client_id} service account is member of group ${desired_group}..."
  local token sa_user_json sa_user_id group_json group_id
  token="$(master_admin_token)"
  sa_user_json="$(kcadm_retry "lookup service account user for ${realm}/${client_id}" \
    kcadm.sh get "clients/${client_uuid}/service-account-user" -r "${realm}")"
  sa_user_id="$(echo "${sa_user_json}" | jq -r '.id // empty' 2>/dev/null || true)"
  [[ -n "${sa_user_id}" ]] || fail "Service account user id missing for ${realm}/${client_id}"

  group_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/groups")"
  group_id="$(echo "${group_json}" | jq -r --arg g "${desired_group}" '.[] | select(.name==$g) | .id' | head -n 1)"
  [[ -n "${group_id}" ]] || fail "Group ${desired_group} not found in realm ${realm}"

  curl -sSf -X PUT -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/users/${sa_user_id}/groups/${group_id}" >/dev/null

  log "Publishing ${realm}/${client_id} secret to Vault (${vault_path})..."
  local secret_value current_secret current_id current_version new_version payload vault_resp
  secret_value="$(fetch_client_secret "${realm}" "${client_id}")"
  [[ -n "${secret_value}" ]] || fail "Empty secret returned for client ${client_id}"

  if vault_json=$(read_vault_secret "${vault_path}"); then
    current_secret="$(echo "${vault_json}" | jq -r '.data.data.clientSecret // empty')"
    current_id="$(echo "${vault_json}" | jq -r '.data.data.clientId // empty')"
    current_version="$(echo "${vault_json}" | jq -r '.data.metadata.version // "0"')"
  else
    current_secret=""
    current_id=""
    current_version="0"
  fi

  if [[ "${current_secret}" != "${secret_value}" || "${current_id}" != "${client_id}" ]]; then
    payload="$(jq -n --arg id "${client_id}" --arg secret "${secret_value}" '{data:{clientId:$id,clientSecret:$secret}}')"
    vault_resp="$(write_vault_secret "${vault_path}" "${payload}")"
    new_version="$(echo "${vault_resp}" | jq -r '.data.version // empty' 2>/dev/null || true)"
    if [[ -z "${new_version}" ]]; then
      if vault_json_post=$(read_vault_secret "${vault_path}"); then
        new_version="$(echo "${vault_json_post}" | jq -r '.data.metadata.version // "unknown"' 2>/dev/null || echo "unknown")"
      else
        new_version="unknown"
      fi
    fi
  else
    new_version="${current_version}"
  fi

  set_status "vault.k8s-oidc-runtime-smoke.version" "${new_version}"
  set_status "k8sOidcRuntimeSmoke.clientId" "${client_id}"
  set_status "k8sOidcRuntimeSmoke.group" "${desired_group}"
}

ensure_scim_bridge_client() {
  local realm="$1"
  local client_id="${KEYCLOAK_SCIM_BRIDGE_CLIENT_ID:-deploykube-scim-bridge}"
  local secret_name="${KEYCLOAK_SCIM_BRIDGE_SECRET_NAME:-keycloak-scim-bridge-client}"
  local client_json client_uuid sa_user_json sa_user_id role token secret_value

  log "Ensuring SCIM bridge service account client ${realm}/${client_id} exists..."
  client_json="$(kcadm_retry "lookup client ${realm}/${client_id}" kcadm.sh get clients -r "${realm}" -q "clientId=${client_id}")"
  client_uuid="$(echo "${client_json}" | jq -r '.[0].id // empty' 2>/dev/null || true)"

  if [[ -z "${client_uuid}" ]]; then
    kcadm_retry "create client ${realm}/${client_id}" \
      kcadm.sh create clients -r "${realm}" \
        -s "clientId=${client_id}" \
        -s "name=DeployKube SCIM bridge" \
        -s "protocol=openid-connect" \
        -s "enabled=true" \
        -s "publicClient=false" \
        -s "serviceAccountsEnabled=true" \
        -s "standardFlowEnabled=false" \
        -s "directAccessGrantsEnabled=false" \
        -s "clientAuthenticatorType=client-secret" >/dev/null
    client_json="$(kcadm_retry "lookup client ${realm}/${client_id} (post-create)" kcadm.sh get clients -r "${realm}" -q "clientId=${client_id}")"
    client_uuid="$(echo "${client_json}" | jq -r '.[0].id // empty' 2>/dev/null || true)"
  else
    kcadm_retry "reconcile client ${realm}/${client_id} settings" \
      kcadm.sh update "clients/${client_uuid}" -r "${realm}" \
        -s "enabled=true" \
        -s "publicClient=false" \
        -s "serviceAccountsEnabled=true" \
        -s "standardFlowEnabled=false" \
        -s "directAccessGrantsEnabled=false" \
        -s "clientAuthenticatorType=client-secret" >/dev/null
  fi

  [[ -n "${client_uuid}" ]] || fail "Client ${client_id} not found in realm ${realm} after ensure"

  token="$(master_admin_token)"
  sa_user_json="$(kcadm_retry "lookup service account user for ${realm}/${client_id}" \
    kcadm.sh get "clients/${client_uuid}/service-account-user" -r "${realm}")"
  sa_user_id="$(echo "${sa_user_json}" | jq -r '.id // empty' 2>/dev/null || true)"
  [[ -n "${sa_user_id}" ]] || fail "Service account user id missing for ${realm}/${client_id}"

  for role in manage-users query-users view-users manage-groups query-groups view-clients view-realm; do
    kcadm_best_effort "grant service-account role ${realm}/${client_id}:${role}" \
      kcadm.sh add-roles -r "${realm}" --uid "${sa_user_id}" --cclientid realm-management --rolename "${role}"
  done

  secret_value="$(fetch_client_secret "${realm}" "${client_id}")"
  [[ -n "${secret_value}" ]] || fail "Empty secret returned for client ${client_id}"

  {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: keycloak-scim-bridge
    darksite.cloud/managed-by: keycloak-bootstrap
type: Opaque
stringData:
  clientId: ${client_id}
  clientSecret: ${secret_value}
  realm: ${realm}
  tokenRealm: ${realm}
EOF
  } | kubectl apply -f -

  set_status "iam.scimBridge.realm" "${realm}"
  set_status "iam.scimBridge.clientId" "${client_id}"
}

secret_value_or_empty() {
  local namespace="$1" name="$2" key="$3"
  kubectl -n "${namespace}" get secret "${name}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

sanitize_mapper_name_fragment() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr -cs 'A-Za-z0-9._-' '-')"
  value="${value#-}"
  value="${value%-}"
  [[ -n "${value}" ]] || value="mapping"
  printf '%s' "${value}"
}

group_path() {
  local group="$1"
  if [[ "${group}" == /* ]]; then
    printf '%s' "${group}"
  else
    printf '/%s' "${group}"
  fi
}

ensure_realm_group_path() {
  local realm="$1"
  local target="$2"
  local name path token groups_json found
  name="${target##*/}"
  path="$(group_path "${target}")"
  [[ -n "${name}" ]] || fail "invalid group target '${target}' for realm ${realm}"

  token="$(master_admin_token)"
  groups_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/groups?search=${name}")"
  found="$(echo "${groups_json}" | jq -r --arg n "${name}" '.[] | select(.name==$n) | .name' | head -n 1)"

  if [[ -z "${found}" && "${target}" != */* ]]; then
    kcadm.sh create groups -r "${realm}" -s "name=${name}" >/dev/null 2>&1 || true
  fi

  printf '%s' "${path}"
}

identity_provider_mapper_id() {
  local realm="$1"
  local mapper_name="$2"
  local mapper_provider="$3"
  local mappers_json
  mappers_json="$(kcadm_retry "list IdP mappers ${realm}/${IAM_UPSTREAM_ALIAS}" \
    kcadm.sh get "identity-provider/instances/${IAM_UPSTREAM_ALIAS}/mappers" -r "${realm}")"
  echo "${mappers_json}" | jq -r --arg name "${mapper_name}" --arg provider "${mapper_provider}" \
    '.[] | select(.name==$name and .identityProviderMapper==$provider) | .id' | head -n 1
}

ensure_identity_provider_mapper() {
  local realm="$1"
  local mapper_name="$2"
  local mapper_provider="$3"
  local config_json="$4"
  local mapper_id payload_file

  mapper_id="$(identity_provider_mapper_id "${realm}" "${mapper_name}" "${mapper_provider}")"
  payload_file="${TMP_DIR}/idp-mapper-${realm}-$(sanitize_mapper_name_fragment "${mapper_name}").json"
  jq -n \
    --arg name "${mapper_name}" \
    --arg provider "${mapper_provider}" \
    --arg alias "${IAM_UPSTREAM_ALIAS}" \
    --argjson cfg "${config_json}" \
    '{name:$name,identityProviderAlias:$alias,identityProviderMapper:$provider,config:$cfg}' > "${payload_file}"

  if [[ -n "${mapper_id}" ]]; then
    kcadm_retry "update IdP mapper ${realm}/${mapper_name}" \
      kcadm.sh update "identity-provider/instances/${IAM_UPSTREAM_ALIAS}/mappers/${mapper_id}" -r "${realm}" -f "${payload_file}" >/dev/null
  else
    kcadm_retry "create IdP mapper ${realm}/${mapper_name}" \
      kcadm.sh create "identity-provider/instances/${IAM_UPSTREAM_ALIAS}/mappers" -r "${realm}" -f "${payload_file}" >/dev/null
  fi
}

cleanup_prefixed_idp_mappers() {
  local realm="$1"
  local name_prefix="$2"
  shift 2
  local -a keep=("$@")
  local mappers_json id name keep_name keep_it
  mappers_json="$(kcadm_retry "list IdP mappers for cleanup ${realm}/${IAM_UPSTREAM_ALIAS}" \
    kcadm.sh get "identity-provider/instances/${IAM_UPSTREAM_ALIAS}/mappers" -r "${realm}")"
  while IFS=$'\t' read -r id name; do
    [[ -n "${id}" && -n "${name}" ]] || continue
    [[ "${name}" == "${name_prefix}"* ]] || continue
    keep_it="false"
    for keep_name in "${keep[@]}"; do
      if [[ "${name}" == "${keep_name}" ]]; then
        keep_it="true"
        break
      fi
    done
    if [[ "${keep_it}" == "false" ]]; then
      kcadm.sh delete "identity-provider/instances/${IAM_UPSTREAM_ALIAS}/mappers/${id}" -r "${realm}" >/dev/null 2>&1 || true
    fi
  done < <(echo "${mappers_json}" | jq -r '.[] | [.id, .name] | @tsv')
}

ensure_upstream_oidc_group_mappings() {
  local realm="$1"
  local groups_claim source target target_path claims_json mapper_name config_json
  local -a mapper_names=()
  local count=0
  groups_claim="$(deployment_cfg '.spec.iam.upstream.oidc.groupsClaim')"
  [[ -n "${groups_claim}" ]] || groups_claim="groups"

  while IFS=$'\t' read -r source target; do
    [[ -n "${source}" && -n "${target}" ]] || continue
    target_path="$(ensure_realm_group_path "${realm}" "${target}")"
    claims_json="$(jq -cn --arg claim "${groups_claim}" --arg value "${source}" '{($claim): $value}')"
    config_json="$(jq -cn --arg claims "${claims_json}" --arg group "${target_path}" \
      '{"claims":$claims,"are.claim.values.regex":"false","group":$group}')"
    mapper_name="deploykube-oidc-group-$(sanitize_mapper_name_fragment "${source}")-to-$(sanitize_mapper_name_fragment "${target}")"
    ensure_identity_provider_mapper "${realm}" "${mapper_name}" "oidc-advanced-group-idp-mapper" "${config_json}"
    mapper_names+=("${mapper_name}")
    count=$((count + 1))
  done < <(yq -r '.spec.iam.upstream.oidc.groupMappings[]? | [.source, .target] | @tsv' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)

  cleanup_prefixed_idp_mappers "${realm}" "deploykube-oidc-group-" "${mapper_names[@]}"
  set_status "iam.realm.${realm}.oidc.groupMappings" "${count}"
}

ensure_upstream_saml_group_mappings() {
  local realm="$1"
  local groups_attribute source target target_path attrs_json mapper_name config_json
  local -a mapper_names=()
  local count=0
  groups_attribute="$(deployment_cfg '.spec.iam.upstream.saml.groupsAttribute')"
  [[ -n "${groups_attribute}" ]] || groups_attribute="groups"

  while IFS=$'\t' read -r source target; do
    [[ -n "${source}" && -n "${target}" ]] || continue
    target_path="$(ensure_realm_group_path "${realm}" "${target}")"
    attrs_json="$(jq -cn --arg attr "${groups_attribute}" --arg value "${source}" '{($attr): $value}')"
    config_json="$(jq -cn --arg attrs "${attrs_json}" --arg group "${target_path}" \
      '{"attributes":$attrs,"are.attribute.values.regex":"false","group":$group}')"
    mapper_name="deploykube-saml-group-$(sanitize_mapper_name_fragment "${source}")-to-$(sanitize_mapper_name_fragment "${target}")"
    ensure_identity_provider_mapper "${realm}" "${mapper_name}" "saml-advanced-group-idp-mapper" "${config_json}"
    mapper_names+=("${mapper_name}")
    count=$((count + 1))
  done < <(yq -r '.spec.iam.upstream.saml.groupMappings[]? | [.source, .target] | @tsv' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)

  cleanup_prefixed_idp_mappers "${realm}" "deploykube-saml-group-" "${mapper_names[@]}"
  set_status "iam.realm.${realm}.saml.groupMappings" "${count}"
}

browser_redirector_execution_id() {
  local realm="$1"
  local token="$2"
  local executions_json execution_id
  executions_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions")"
  execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector" and .level==0) | .id' | head -n 1)"
  if [[ -z "${execution_id}" ]]; then
    execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector") | .id' | head -n 1)"
  fi
  [[ -n "${execution_id}" ]] || fail "Identity Provider Redirector execution not found in browser flow for realm ${realm}"
  printf '%s' "${execution_id}"
}

set_browser_redirector_requirement() {
  local realm="$1"
  local requirement="$2"
  local token="$3"
  local executions_json execution_id current_requirement payload
  executions_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions")"
  execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector" and .level==0) | .id' | head -n 1)"
  if [[ -z "${execution_id}" ]]; then
    execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector") | .id' | head -n 1)"
  fi
  [[ -n "${execution_id}" ]] || fail "Identity Provider Redirector execution not found in browser flow for realm ${realm}"
  current_requirement="$(echo "${executions_json}" | jq -r --arg id "${execution_id}" '.[] | select(.id==$id) | .requirement // empty')"

  if [[ "${current_requirement}" == "${requirement}" ]]; then
    return 0
  fi

  payload="$(jq -n --arg id "${execution_id}" --arg req "${requirement}" '{id:$id,requirement:$req}')"
  curl -sSf -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    --data "${payload}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions" >/dev/null
}

ensure_browser_redirector_config() {
  local realm="$1"
  local upstream_alias="$2"
  local token="$3"
  local executions_json execution_id config_id config_json config_alias current_provider payload
  executions_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions")"
  execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector" and .level==0) | .id' | head -n 1)"
  if [[ -z "${execution_id}" ]]; then
    execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector") | .id' | head -n 1)"
  fi
  [[ -n "${execution_id}" ]] || fail "Identity Provider Redirector execution not found in browser flow for realm ${realm}"
  config_id="$(echo "${executions_json}" | jq -r --arg id "${execution_id}" '.[] | select(.id==$id) | .authenticationConfig // empty')"

  if [[ -n "${config_id}" ]]; then
    config_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
      "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/config/${config_id}")"
    current_provider="$(echo "${config_json}" | jq -r '.config.defaultProvider // empty')"
    if [[ "${current_provider}" != "${upstream_alias}" ]]; then
      config_alias="$(echo "${config_json}" | jq -r '.alias // "deploykube-upstream-redirect"')"
      payload="$(jq -n \
        --arg id "${config_id}" \
        --arg alias "${config_alias}" \
        --arg provider "${upstream_alias}" \
        '{id:$id,alias:$alias,config:{defaultProvider:$provider}}')"
      curl -sSf -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
        --data "${payload}" \
        "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/config/${config_id}" >/dev/null
    fi
  else
    payload="$(jq -n --arg alias "deploykube-upstream-redirect" --arg provider "${upstream_alias}" \
      '{alias:$alias,config:{defaultProvider:$provider}}')"
    curl -sSf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      --data "${payload}" \
      "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/executions/${execution_id}/config" >/dev/null
  fi
}

set_realm_upstream_preference() {
  local realm="$1"
  local preference="$2"
  local token="$3"

  case "${preference}" in
    upstream)
      ensure_browser_redirector_config "${realm}" "${IAM_UPSTREAM_ALIAS}" "${token}"
      set_browser_redirector_requirement "${realm}" "REQUIRED" "${token}"
      ;;
    local)
      set_browser_redirector_requirement "${realm}" "DISABLED" "${token}"
      ;;
    *)
      fail "Unsupported realm upstream preference '${preference}' for realm ${realm}"
      ;;
  esac
}

ensure_required_action_default() {
  local realm="$1"
  local action_alias="$2"
  local default_action="$3"
  kcadm.sh update "authentication/required-actions/${action_alias}" -r "${realm}" \
    -s "enabled=true" \
    -s "defaultAction=${default_action}" >/dev/null 2>&1 || \
      log "WARN: unable to set required action ${realm}/${action_alias} defaultAction=${default_action}"
}

ensure_offline_credential_policy() {
  local realm="$1"
  if [[ "${IAM_MODE}" != "hybrid" || "${IAM_OFFLINE_REQUIRED}" != "true" ]]; then
    ensure_required_action_default "${realm}" "UPDATE_PASSWORD" "false"
    ensure_required_action_default "${realm}" "CONFIGURE_TOTP" "false"
    ensure_required_action_default "${realm}" "webauthn-register" "false"
    return 0
  fi

  case "${IAM_OFFLINE_METHOD}" in
    password)
      ensure_required_action_default "${realm}" "UPDATE_PASSWORD" "true"
      ensure_required_action_default "${realm}" "CONFIGURE_TOTP" "false"
      ensure_required_action_default "${realm}" "webauthn-register" "false"
      ;;
    webauthn)
      ensure_required_action_default "${realm}" "UPDATE_PASSWORD" "false"
      ensure_required_action_default "${realm}" "CONFIGURE_TOTP" "false"
      ensure_required_action_default "${realm}" "webauthn-register" "true"
      ;;
    password+otp|*)
      ensure_required_action_default "${realm}" "UPDATE_PASSWORD" "true"
      ensure_required_action_default "${realm}" "CONFIGURE_TOTP" "true"
      ensure_required_action_default "${realm}" "webauthn-register" "false"
      ;;
  esac
}

ensure_upstream_idp_oidc() {
  local realm="$1"
  local issuer client_id client_secret display_name discovery_url idp_file
  issuer="$(deployment_cfg '.spec.iam.upstream.oidc.issuerUrl')"
  client_id="$(deployment_cfg '.spec.iam.upstream.oidc.clientId')"
  display_name="$(deployment_cfg '.spec.iam.upstream.displayName')"
  [[ -n "${display_name}" ]] || display_name="Upstream OIDC"
  [[ -n "${issuer}" ]] || fail "IAM mode ${IAM_MODE} requires spec.iam.upstream.oidc.issuerUrl for realm ${realm}"

  if client_secret="$(resolve_iam_value_ref '.spec.iam.upstream.oidc.clientSecretRef' 2>/dev/null)"; then
    :
  else
    client_secret="$(secret_value_or_empty "${NAMESPACE}" "keycloak-upstream-oidc" "clientSecret")"
  fi
  [[ -n "${client_secret}" ]] || fail "IAM OIDC upstream missing client secret reference (realm ${realm})"

  if [[ -z "${client_id}" ]]; then
    client_id="$(secret_value_or_empty "${NAMESPACE}" "keycloak-upstream-oidc" "clientId")"
  fi
  [[ -n "${client_id}" ]] || fail "IAM OIDC upstream missing clientId for realm ${realm}"

  discovery_url="${issuer%/}/.well-known/openid-configuration"
  idp_file="${TMP_DIR}/idp-oidc-${realm}.json"
  jq -n \
    --arg alias "${IAM_UPSTREAM_ALIAS}" \
    --arg display "${display_name}" \
    --arg issuer "${issuer}" \
    --arg discovery "${discovery_url}" \
    --arg cid "${client_id}" \
    --arg secret "${client_secret}" \
    '{
      alias: $alias,
      providerId: "oidc",
      enabled: true,
      displayName: $display,
      storeToken: true,
      trustEmail: true,
      firstBrokerLoginFlowAlias: "first broker login",
      config: {
        issuer: $issuer,
        discoveryUrl: $discovery,
        validateSignature: "true",
        useJwksUrl: "true",
        clientId: $cid,
        clientSecret: $secret,
        defaultScope: "openid profile email",
        syncMode: "FORCE"
      }
    }' > "${idp_file}"

  if kcadm.sh get "identity-provider/instances/${IAM_UPSTREAM_ALIAS}" -r "${realm}" >/dev/null 2>&1; then
    kcadm_retry "update OIDC upstream IdP ${realm}/${IAM_UPSTREAM_ALIAS}" \
      kcadm.sh update "identity-provider/instances/${IAM_UPSTREAM_ALIAS}" -r "${realm}" -f "${idp_file}" >/dev/null
  else
    kcadm_retry "create OIDC upstream IdP ${realm}/${IAM_UPSTREAM_ALIAS}" \
      kcadm.sh create identity-provider/instances -r "${realm}" -f "${idp_file}" >/dev/null
  fi

  ensure_upstream_oidc_group_mappings "${realm}"
}

ensure_upstream_idp_saml() {
  local realm="$1"
  local sso_url entity_id signing_cert display_name idp_file
  sso_url="$(deployment_cfg '.spec.iam.upstream.saml.ssoUrl')"
  entity_id="$(deployment_cfg '.spec.iam.upstream.saml.entityId')"
  display_name="$(deployment_cfg '.spec.iam.upstream.displayName')"
  [[ -n "${display_name}" ]] || display_name="Upstream SAML"
  [[ -n "${sso_url}" && -n "${entity_id}" ]] || fail "IAM SAML upstream requires spec.iam.upstream.saml.{ssoUrl,entityId} for realm ${realm}"

  if signing_cert="$(resolve_iam_value_ref '.spec.iam.upstream.saml.signingCertRef' 2>/dev/null)"; then
    :
  else
    signing_cert="$(secret_value_or_empty "${NAMESPACE}" "keycloak-upstream-saml" "signingCert")"
  fi
  [[ -n "${signing_cert}" ]] || fail "IAM SAML upstream missing signing certificate for realm ${realm}"

  idp_file="${TMP_DIR}/idp-saml-${realm}.json"
  jq -n \
    --arg alias "${IAM_UPSTREAM_ALIAS}" \
    --arg display "${display_name}" \
    --arg sso "${sso_url}" \
    --arg entity "${entity_id}" \
    --arg cert "${signing_cert}" \
    '{
      alias: $alias,
      providerId: "saml",
      enabled: true,
      displayName: $display,
      firstBrokerLoginFlowAlias: "first broker login",
      config: {
        singleSignOnServiceUrl: $sso,
        idpEntityId: $entity,
        syncMode: "FORCE",
        wantAuthnRequestsSigned: "false",
        validateSignature: "true",
        signingCertificate: $cert
      }
    }' > "${idp_file}"

  if kcadm.sh get "identity-provider/instances/${IAM_UPSTREAM_ALIAS}" -r "${realm}" >/dev/null 2>&1; then
    kcadm_retry "update SAML upstream IdP ${realm}/${IAM_UPSTREAM_ALIAS}" \
      kcadm.sh update "identity-provider/instances/${IAM_UPSTREAM_ALIAS}" -r "${realm}" -f "${idp_file}" >/dev/null
  else
    kcadm_retry "create SAML upstream IdP ${realm}/${IAM_UPSTREAM_ALIAS}" \
      kcadm.sh create identity-provider/instances -r "${realm}" -f "${idp_file}" >/dev/null
  fi

  ensure_upstream_saml_group_mappings "${realm}"
}

ensure_upstream_ldap_federation() {
  local realm="$1"
  local ldap_url users_dn groups_dn user_filter bind_dn bind_password start_tls operation_mode
  ldap_url="$(deployment_cfg '.spec.iam.upstream.ldap.url')"
  users_dn="$(deployment_cfg '.spec.iam.upstream.ldap.usersBaseDn')"
  groups_dn="$(deployment_cfg '.spec.iam.upstream.ldap.groupsBaseDn')"
  user_filter="$(deployment_cfg '.spec.iam.upstream.ldap.userFilter')"
  operation_mode="$(deployment_cfg '.spec.iam.upstream.ldap.operationMode')"
  start_tls="$(deployment_cfg '.spec.iam.upstream.ldap.startTls')"
  [[ -n "${ldap_url}" && -n "${users_dn}" ]] || fail "IAM LDAP upstream requires spec.iam.upstream.ldap.url and usersBaseDn for realm ${realm}"
  [[ -n "${operation_mode}" ]] || operation_mode="federation"

  if bind_dn="$(resolve_iam_value_ref '.spec.iam.upstream.ldap.bindDnRef' 2>/dev/null)"; then
    :
  else
    bind_dn="$(secret_value_or_empty "${NAMESPACE}" "keycloak-upstream-ldap" "bindDn")"
  fi
  if bind_password="$(resolve_iam_value_ref '.spec.iam.upstream.ldap.bindPasswordRef' 2>/dev/null)"; then
    :
  else
    bind_password="$(secret_value_or_empty "${NAMESPACE}" "keycloak-upstream-ldap" "bindPassword")"
  fi

  local component_file component_id mode_value
  component_file="${TMP_DIR}/ldap-component-${realm}.json"
  mode_value="READ_ONLY"
  if [[ "${operation_mode}" == "sync" ]]; then
    mode_value="WRITABLE"
  fi

  jq -n \
    --arg realm "${realm}" \
    --arg mode "${mode_value}" \
    --arg ldapUrl "${ldap_url}" \
    --arg usersDn "${users_dn}" \
    --arg bindDn "${bind_dn}" \
    --arg bindPassword "${bind_password}" \
    --arg startTls "${start_tls:-false}" \
    --arg userFilter "${user_filter}" \
    --arg groupsDn "${groups_dn}" \
    '{
      name: "deploykube-upstream-ldap",
      providerId: "ldap",
      providerType: "org.keycloak.storage.UserStorageProvider",
      parentId: $realm,
      config: {
        enabled: ["true"],
        priority: ["0"],
        editMode: [$mode],
        vendor: ["other"],
        connectionUrl: [$ldapUrl],
        usersDn: [$usersDn],
        bindDn: [$bindDn],
        bindCredential: [$bindPassword],
        authType: ["simple"],
        startTls: [$startTls],
        useTruststoreSpi: ["always"],
        usernameLDAPAttribute: ["uid"],
        rdnLDAPAttribute: ["uid"],
        uuidLDAPAttribute: ["entryUUID"],
        userObjectClasses: ["inetOrgPerson, organizationalPerson"],
        searchScope: ["2"],
        pagination: ["true"],
        importEnabled: ["true"],
        syncRegistrations: ["false"],
        userLDAPFilter: [$userFilter],
        groupsDn: [$groupsDn]
      }
    }' > "${component_file}"

  component_id="$(kcadm_retry "lookup LDAP federation component ${realm}" \
    kcadm.sh get components -r "${realm}" -q name=deploykube-upstream-ldap -q providerId=ldap | jq -r '.[0].id // empty')"
  if [[ -n "${component_id}" ]]; then
    kcadm_retry "update LDAP federation component ${realm}/${component_id}" \
      kcadm.sh update "components/${component_id}" -r "${realm}" -f "${component_file}" >/dev/null
  else
    kcadm_retry "create LDAP federation component ${realm}" \
      kcadm.sh create components -r "${realm}" -f "${component_file}" >/dev/null
  fi
}

ensure_iam_mode() {
  local realm="$1"
  local token
  token="$(master_admin_token)"
  case "${IAM_MODE}" in
    standalone)
      set_realm_upstream_preference "${realm}" "local" "${token}"
      ensure_offline_credential_policy "${realm}"
      set_status "iam.realm.${realm}.state" "standalone"
      ;;
    downstream)
      ensure_offline_credential_policy "${realm}"
      case "${IAM_UPSTREAM_TYPE}" in
        oidc)
          ensure_upstream_idp_oidc "${realm}"
          set_realm_upstream_preference "${realm}" "upstream" "${token}"
          ;;
        saml)
          ensure_upstream_idp_saml "${realm}"
          set_realm_upstream_preference "${realm}" "upstream" "${token}"
          ;;
        ldap)
          ensure_upstream_ldap_federation "${realm}"
          set_realm_upstream_preference "${realm}" "local" "${token}"
          ;;
        scim)
          if [[ "${realm}" == "${IAM_PRIMARY_REALM}" ]]; then
            ensure_scim_bridge_client "${realm}"
          fi
          set_realm_upstream_preference "${realm}" "local" "${token}"
          ;;
        *)
          fail "IAM downstream mode requires spec.iam.upstream.type for realm ${realm}"
          ;;
      esac
      set_status "iam.realm.${realm}.state" "downstream"
      ;;
    hybrid)
      ensure_offline_credential_policy "${realm}"
      case "${IAM_UPSTREAM_TYPE}" in
        oidc)
          ensure_upstream_idp_oidc "${realm}"
          ;;
        saml)
          ensure_upstream_idp_saml "${realm}"
          ;;
        ldap)
          ensure_upstream_ldap_federation "${realm}"
          ;;
        scim)
          if [[ "${realm}" == "${IAM_PRIMARY_REALM}" ]]; then
            ensure_scim_bridge_client "${realm}"
          fi
          log "IAM hybrid with SCIM upstream: SCIM is provisioning-only; login remains local unless an IdP is also configured."
          ;;
        *)
          fail "IAM hybrid mode requires spec.iam.upstream.type for realm ${realm}"
          ;;
      esac
      # Hybrid starts in local-visible mode; keycloak-iam-sync toggles upstream preference on healthy checks.
      set_realm_upstream_preference "${realm}" "local" "${token}"
      set_status "iam.realm.${realm}.state" "hybrid-local-visible"
      ;;
    *)
      fail "Unsupported IAM mode '${IAM_MODE}'"
      ;;
  esac
}

ensure_iam_mode_for_realms() {
  local realm
  for realm in "${IAM_TARGET_REALMS[@]}"; do
    ensure_iam_mode "${realm}"
  done
}

ensure_iam_handover_baseline_realm() {
  local realm="$1"
  local iam_group="dk-iam-admins"
  local role

  kcadm_best_effort "ensure IAM handover group ${realm}/${iam_group}" \
    kcadm.sh create groups -r "${realm}" -s "name=${iam_group}"

  for role in manage-users query-users view-users manage-groups view-realm view-clients; do
    kcadm_best_effort "grant IAM handover group role ${realm}/${iam_group}:${role}" \
      kcadm.sh add-roles -r "${realm}" --gname "${iam_group}" --cclientid realm-management --rolename "${role}"
  done

  set_status "iam.realm.${realm}.handover.group" "${iam_group}"
}

ensure_iam_handover_baseline() {
  local realm
  for realm in "${IAM_TARGET_REALMS[@]}"; do
    ensure_iam_handover_baseline_realm "${realm}"
  done
  set_status "iam.handover.script" "shared/scripts/keycloak-iam-handover.sh"
}

validate_tenant_id() {
  local label="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    fail "Tenant registry: missing ${label}"
  fi
  if [[ "${#value}" -gt 63 ]]; then
    fail "Tenant registry: ${label} too long (>63): ${value}"
  fi
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    fail "Tenant registry: ${label} must be DNS-label-safe ([a-z0-9-], start/end alnum): ${value}"
  fi
}

ensure_tenant_groups() {
  local registry="${TENANT_REGISTRY_PATH}"
  local realm="${KEYCLOAK_TENANT_GROUP_REALM:-deploykube-admin}"

  if [[ ! -f "${registry}" ]]; then
    log "Tenant registry not present at ${registry}; skipping tenant group reconcile."
    set_status "tenantGroups.lastSkip" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    return 0
  fi

  local kind api_version
  kind="$(yq -r '.kind // ""' "${registry}")"
  api_version="$(yq -r '.apiVersion // ""' "${registry}")"
  if [[ "${kind}" != "TenantRegistry" ]]; then
    fail "Tenant registry ${registry} has unexpected kind=${kind} (expected TenantRegistry)"
  fi
  if [[ -z "${api_version}" ]]; then
    fail "Tenant registry ${registry} missing apiVersion"
  fi

  log "Reconciling tenant groups from ${registry} (apiVersion=${api_version}) into realm ${realm}..."

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local token groups_json
  token="$(master_admin_token)"
  groups_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/groups")"

  declare -A existing_group=()
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    existing_group["${name}"]=1
  done < <(echo "${groups_json}" | jq -r '.[].name // empty')

  local created=0
  local total=0

  ensure_group() {
    local name="$1"
    total=$((total + 1))
    if [[ -n "${existing_group[${name}]:-}" ]]; then
      return 0
    fi
    log "Creating tenant group ${realm}/${name}..."
    kcadm_retry "create group ${realm}/${name}" kcadm.sh create groups -r "${realm}" -s "name=${name}" >/dev/null
    existing_group["${name}"]=1
    created=$((created + 1))
  }

  local tenants_count
  tenants_count="$(yq -r '.tenants | length' "${registry}")"
  if [[ -z "${tenants_count}" || "${tenants_count}" == "null" ]]; then
    tenants_count=0
  fi

  if [[ "${tenants_count}" -eq 0 ]]; then
    log "Tenant registry contains no tenants; nothing to do."
    set_status "tenantGroups.lastReconcile" "${timestamp}"
    set_status "tenantGroups.tenants" "0"
    set_status "tenantGroups.groupsCreated" "0"
    set_status "tenantGroups.groupsEnsured" "0"
    return 0
  fi

  local org_id project_id
  while IFS= read -r org_id; do
    [[ -z "${org_id}" ]] && continue
    validate_tenant_id "orgId" "${org_id}"

    ensure_group "dk-tenant-${org_id}-admins"
    ensure_group "dk-tenant-${org_id}-viewers"

    while IFS= read -r project_id; do
      [[ -z "${project_id}" ]] && continue
      validate_tenant_id "projectId" "${project_id}"
      ensure_group "dk-tenant-${org_id}-project-${project_id}-admins"
      ensure_group "dk-tenant-${org_id}-project-${project_id}-developers"
      ensure_group "dk-tenant-${org_id}-project-${project_id}-viewers"
    done < <(yq -r ".tenants[] | select(.orgId == \"${org_id}\") | .projects[]? | .projectId // \"\"" "${registry}" 2>/dev/null || true)
  done < <(yq -r '.tenants[].orgId // ""' "${registry}")

  set_status "tenantGroups.lastReconcile" "${timestamp}"
  set_status "tenantGroups.tenants" "${tenants_count}"
  set_status "tenantGroups.groupsCreated" "${created}"
  set_status "tenantGroups.groupsEnsured" "${total}"
}

main() {
  load_prev_status
  load_deployment_config_snapshot
  export_hosts_from_deployment_config
  read_iam_mode_from_deployment_config
  sync_tls_secret
  wait_for_ready_conditions
  keycloak_login
  ensure_master_admin
  import_realms
  ensure_iam_mode_for_realms
  ensure_iam_handover_baseline
  ensure_tenant_groups
  ensure_device_code_grant_enabled "deploykube-admin" "kubernetes-api"
  ensure_k8s_oidc_runtime_smoke_client
  sync_dev_user
  sync_automation_users
  sync_oidc_clients
  set_status "job.lastRun" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  set_status "job.keycloakHost" "${EXTERNAL_KEYCLOAK_HOST}"
  write_status_configmap
  log "Keycloak bootstrap completed successfully."
}

main "$@"
