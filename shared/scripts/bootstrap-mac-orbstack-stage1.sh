#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE0_SENTINEL="${STAGE0_SENTINEL:-${REPO_ROOT}/tmp/stage0-complete}"
CLUSTER_NAME="${CLUSTER_NAME:-deploykube-dev}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
KIND_REFRESH_KUBECONFIG_SCRIPT="${KIND_REFRESH_KUBECONFIG_SCRIPT:-${REPO_ROOT}/shared/scripts/kind-refresh-kubeconfig.sh}"

# Offline bundle (Phase 0): when set, Stage 1 must not fetch charts from the internet.
OFFLINE_BUNDLE_DIR="${OFFLINE_BUNDLE_DIR:-}"

# Helm environment (avoid broken user plugins like helm-secrets)
HELM_NO_USER_PLUGINS="${HELM_NO_USER_PLUGINS:-true}"
HELM_PLUGINS_EMPTY_DIR=""
HELM_SERVER_SIDE="${HELM_SERVER_SIDE:-auto}"
HELM_FORCE_CONFLICTS="${HELM_FORCE_CONFLICTS:-true}"
HELM_UPGRADE_HELP=""

FORGEJO_RELEASE="${FORGEJO_RELEASE:-forgejo}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
FORGEJO_CHART="${FORGEJO_CHART:-oci://code.forgejo.org/forgejo-helm/forgejo}"
FORGEJO_CHART_VERSION="${FORGEJO_CHART_VERSION:-15.0.2}"
FORGEJO_VALUES="${REPO_ROOT}/bootstrap/mac-orbstack/forgejo/values-bootstrap.yaml"
FORGEJO_ADMIN_USERNAME="${FORGEJO_ADMIN_USERNAME:-forgejo-admin}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-forgejo-admin@example.invalid}"
FORGEJO_ADMIN_SECRET_PATH="${FORGEJO_ADMIN_SECRET_PATH:-secret/forgejo/admin}"
FORGEJO_ORG="${FORGEJO_ORG:-platform}"
FORGEJO_REPO="${FORGEJO_REPO:-cluster-config}"
FORGEJO_REPO_TLS_SECRET="${FORGEJO_REPO_TLS_SECRET:-forgejo-repo-tls}"
FORGEJO_REPO_TLS_HOST="${FORGEJO_REPO_TLS_HOST:-forgejo-https.${FORGEJO_NAMESPACE}.svc.cluster.local}"
FORGEJO_PORT_FORWARD_PORT="${FORGEJO_PORT_FORWARD_PORT:-38080}"
FORGEJO_SEED_SENTINEL="${FORGEJO_SEED_SENTINEL:-${REPO_ROOT}/tmp/bootstrap/forgejo-repo-seeded}"
FORGEJO_FORCE_SEED="${FORGEJO_FORCE_SEED:-false}"
FORGEJO_ADMIN_PASSWORD=""

GITOPS_LOCAL_REPO="${REPO_ROOT}/platform/gitops"

ARGO_RELEASE="${ARGO_RELEASE:-argo-cd}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"
ARGO_CHART="${ARGO_CHART:-argo/argo-cd}"
ARGO_CHART_VERSION="${ARGO_CHART_VERSION:-9.1.0}"
ARGO_APP_VERSION="${ARGO_APP_VERSION:-v3.2.0}"
ARGO_VALUES="${REPO_ROOT}/bootstrap/mac-orbstack/argocd/values-bootstrap.yaml"
ARGO_VALUES_RESOURCES="${REPO_ROOT}/bootstrap/shared/argocd/values-resources.yaml"
ARGO_VALUES_PROBES="${REPO_ROOT}/bootstrap/shared/argocd/values-probes.yaml"
ARGO_APP_NAME="${ARGO_APP_NAME:-platform-apps}"
ARGO_APP_PATH="${ARGO_APP_PATH:-apps/environments/mac-orbstack-single}"
WAIT_FOR_PLATFORM_APPS="${WAIT_FOR_PLATFORM_APPS:-false}"
PLATFORM_APPS_AUTOSYNC="${PLATFORM_APPS_AUTOSYNC:-true}"
DEFAULT_AGE_KEY_PATH="${HOME}/.config/sops/age/keys.txt"
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-mac-orbstack-single}"
DEPLOYKUBE_STORAGE_PROFILE="${DEPLOYKUBE_STORAGE_PROFILE:-local-path}"
DEFAULT_DEPLOYMENT_AGE_KEY_PATH="${HOME}/.config/deploykube/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/sops/age.key"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-}"

log() {
  printf '[stage1] %s\n' "$1" >&2
}

maybe_wire_offline_bundle() {
  if [[ -z "${OFFLINE_BUNDLE_DIR}" ]]; then
    return 0
  fi
  local charts_dir="${OFFLINE_BUNDLE_DIR}/charts"
  if [[ ! -d "${charts_dir}" ]]; then
    log "ERROR: OFFLINE_BUNDLE_DIR set but charts/ missing: ${charts_dir}"
    exit 1
  fi
  local bundle_gitops="${OFFLINE_BUNDLE_DIR}/gitops"
  if [[ -d "${bundle_gitops}" ]]; then
    GITOPS_LOCAL_REPO="${bundle_gitops}"
  fi

  local forgejo_chart="${charts_dir}/forgejo-${FORGEJO_CHART_VERSION}.tgz"
  local argocd_chart="${charts_dir}/argo-cd-${ARGO_CHART_VERSION}.tgz"
  if [[ ! -f "${forgejo_chart}" ]]; then
    log "ERROR: Offline mode: Forgejo chart missing from bundle: ${forgejo_chart}"
    exit 1
  fi
  if [[ ! -f "${argocd_chart}" ]]; then
    log "ERROR: Offline mode: Argo CD chart missing from bundle: ${argocd_chart}"
    exit 1
  fi
  FORGEJO_CHART="${forgejo_chart}"
  ARGO_CHART="${argocd_chart}"
  log "Offline mode enabled (OFFLINE_BUNDLE_DIR=${OFFLINE_BUNDLE_DIR})"
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  log "need shasum or sha256sum to compute SHA256"
  exit 1
}

deployment_environment_id() {
  # Best-effort; Stage 1 should not require yq.
  if [[ "${DEPLOYKUBE_DEPLOYMENT_ID}" == "proxmox-talos" ]]; then
    printf 'prod'
    return
  fi
  if [[ "${DEPLOYKUBE_DEPLOYMENT_ID}" == mac-orbstack* ]]; then
    printf 'dev'
    return
  fi
  local cfg="${REPO_ROOT}/platform/gitops/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/config.yaml"
  if command -v yq >/dev/null 2>&1 && [[ -f "${cfg}" ]]; then
    yq -r '.spec.environmentId // ""' "${cfg}" 2>/dev/null || true
    return
  fi
  printf ''
}

check_sops_age_key_custody_gate() {
  local env_id
  env_id="$(deployment_environment_id)"
  if [[ -z "${env_id}" ]]; then
    log "WARN: could not determine deployment environmentId for ${DEPLOYKUBE_DEPLOYMENT_ID}; skipping SOPS Age custody gate"
    return 0
  fi
  local sentinel="${REPO_ROOT}/tmp/bootstrap/sops-age-key-acked-${DEPLOYKUBE_DEPLOYMENT_ID}"
  local sha
  sha="$(sha256_file "${SOPS_AGE_KEY_FILE}")"

  if [[ ! -f "${sentinel}" ]]; then
    if [[ "${env_id}" == "prod" ]]; then
      log "ERROR: missing SOPS Age custody acknowledgement sentinel: ${sentinel}"
      log "Run: ./shared/scripts/sops-age-key-custody-ack.sh --deployment-id ${DEPLOYKUBE_DEPLOYMENT_ID} --age-key-file \"${SOPS_AGE_KEY_FILE}\" --storage-location '<...>'"
      exit 1
    fi
    log "WARN: SOPS Age custody acknowledgement sentinel missing for ${DEPLOYKUBE_DEPLOYMENT_ID} (env=${env_id}); recommended for prod"
    return 0
  fi

  local sha_expected
  sha_expected="$(grep -E '^age_key_sha256=' "${sentinel}" 2>/dev/null | head -n 1 | sed 's/^age_key_sha256=//')"
  if [[ -z "${sha_expected}" || "${sha_expected}" != "${sha}" ]]; then
    if [[ "${env_id}" == "prod" ]]; then
      log "ERROR: SOPS Age custody acknowledgement SHA mismatch for ${DEPLOYKUBE_DEPLOYMENT_ID}"
      log "  key file: ${SOPS_AGE_KEY_FILE}"
      log "  sha256:   ${sha}"
      log "  sentinel: ${sentinel}"
      exit 1
    fi
    log "WARN: SOPS Age custody acknowledgement SHA mismatch for ${DEPLOYKUBE_DEPLOYMENT_ID} (env=${env_id}); recommended to re-ack"
  fi
}

cleanup_stage1() {
  if [[ -n "${HELM_PLUGINS_EMPTY_DIR}" && -d "${HELM_PLUGINS_EMPTY_DIR}" ]]; then
    rm -rf "${HELM_PLUGINS_EMPTY_DIR}" || true
  fi
}

setup_helm_env() {
  if [[ "${HELM_NO_USER_PLUGINS}" != "true" ]]; then
    return 0
  fi
  HELM_PLUGINS_EMPTY_DIR="$(mktemp -d "/tmp/deploykube-helm-plugins.XXXXXX")"
  chmod 700 "${HELM_PLUGINS_EMPTY_DIR}"
  trap cleanup_stage1 EXIT INT TERM
}

helm_cmd() {
  if [[ "${HELM_NO_USER_PLUGINS}" == "true" ]]; then
    HELM_PLUGINS="${HELM_PLUGINS_EMPTY_DIR}" helm "$@"
  else
    helm "$@"
  fi
}

helm_upgrade_help() {
  if [[ -n "${HELM_UPGRADE_HELP}" ]]; then
    printf '%s' "${HELM_UPGRADE_HELP}"
    return 0
  fi
  HELM_UPGRADE_HELP="$(helm_cmd upgrade --help 2>&1 || true)"
  printf '%s' "${HELM_UPGRADE_HELP}"
}

helm_upgrade_extra_args() {
  local -a args=()
  local help_out
  help_out="$(helm_upgrade_help)"
  if printf '%s' "${help_out}" | grep -q -- '--server-side'; then
    args+=(--server-side "${HELM_SERVER_SIDE}")
  fi
  if [[ "${HELM_FORCE_CONFLICTS}" == "true" ]] && printf '%s' "${help_out}" | grep -q -- '--force-conflicts'; then
    args+=(--force-conflicts)
  fi
  printf '%s\n' "${args[@]}"
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    log "missing dependency '${bin}' – please install it before running stage 1"
    exit 1
  fi
}

ensure_prerequisites() {
  log "validating stage 0 prerequisites"
  check_dependency kubectl
  check_dependency kind
  check_dependency helm
  check_dependency git
  check_dependency curl
  check_dependency jq
  check_dependency python3
  check_dependency openssl
  check_dependency age-keygen
  setup_helm_env
  if [[ -x "${KIND_REFRESH_KUBECONFIG_SCRIPT}" ]]; then
    # Always refresh into ~/.kube/config (and a repo-local tmp kubeconfig) so the API port mapping
    # is correct even after clean re-creates.
    CLUSTER_NAME="${CLUSTER_NAME}" "${KIND_REFRESH_KUBECONFIG_SCRIPT}"
  else
    # Fallback: best-effort refresh into default kubeconfig.
    kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi
  if ! kubectl config get-contexts "${KIND_CONTEXT}" >/dev/null 2>&1; then
    log "kind context ${KIND_CONTEXT} not found after kubeconfig refresh; run stage 0 first"
    exit 1
  fi
  if [[ ! -d "${GITOPS_LOCAL_REPO}" ]]; then
    log "GitOps workspace ${GITOPS_LOCAL_REPO} missing"
    exit 1
  fi
  ensure_age_key_file
  if [[ ! -f "${STAGE0_SENTINEL}" ]]; then
    log "Stage 0 sentinel ${STAGE0_SENTINEL} not found – run stage 0 before stage 1"
    exit 1
  fi
  verify_stage0_artifacts
}

ensure_age_key_file() {
  local target=""
  if [[ -n "${SOPS_AGE_KEY_FILE}" ]]; then
    target="${SOPS_AGE_KEY_FILE}"
  elif [[ -f "${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}" ]]; then
    target="${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}"
  else
    target="${DEFAULT_AGE_KEY_PATH}"
  fi
  if [[ -f "${target}" ]]; then
    SOPS_AGE_KEY_FILE="${target}"
    export SOPS_AGE_KEY_FILE
    log "using existing SOPS Age key at ${SOPS_AGE_KEY_FILE}"
    return
  fi
  log "SOPS Age key missing at ${target}"
  log "DSB contract: restore the deployment Age key from out-of-band storage before running Stage 1."
  log "Defaults:"
  log "  - deployment-scoped: ${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}"
  log "  - legacy fallback:   ${DEFAULT_AGE_KEY_PATH}"
  exit 1
}

verify_stage0_artifacts() {
  local missing=()
  if ! kubectl --context "${KIND_CONTEXT}" get storageclass shared-rwo >/dev/null 2>&1; then
    missing+=("StorageClass shared-rwo")
  fi

  case "${DEPLOYKUBE_STORAGE_PROFILE}" in
    shared-nfs)
      if ! kubectl --context "${KIND_CONTEXT}" get namespace storage-system >/dev/null 2>&1; then
        missing+=("namespace storage-system (shared storage)")
      fi
      local provisioner="nfs-provisioner-nfs-subdir-external-provisioner"
      if ! kubectl --context "${KIND_CONTEXT}" -n storage-system get deployment "${provisioner}" >/dev/null 2>&1; then
        missing+=("shared storage deployment ${provisioner}")
      else
        if ! kubectl --context "${KIND_CONTEXT}" -n storage-system rollout status deployment/"${provisioner}" --timeout=5s >/dev/null 2>&1; then
          missing+=("shared storage deployment ${provisioner} not Ready")
        fi
      fi
      ;;
    local-path)
      if ! kubectl --context "${KIND_CONTEXT}" get namespace storage-system >/dev/null 2>&1; then
        missing+=("namespace storage-system (local-path provisioner)")
      fi
      local provisioner="local-path-provisioner"
      if ! kubectl --context "${KIND_CONTEXT}" -n storage-system get deployment "${provisioner}" >/dev/null 2>&1; then
        missing+=("local-path provisioner deployment ${provisioner}")
      else
        if ! kubectl --context "${KIND_CONTEXT}" -n storage-system rollout status deployment/"${provisioner}" --timeout=5s >/dev/null 2>&1; then
          missing+=("local-path provisioner deployment ${provisioner} not Ready")
        fi
      fi
      ;;
    *)
      missing+=("unknown DEPLOYKUBE_STORAGE_PROFILE=${DEPLOYKUBE_STORAGE_PROFILE}")
      ;;
  esac
  if ((${#missing[@]} > 0)); then
    log "stage 0 appears incomplete; missing: ${missing[*]}"
    log "run shared/scripts/bootstrap-mac-orbstack-stage0.sh before stage 1"
    exit 1
  fi
}

get_password_from_secret() {
  kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode
}

fetch_forgejo_admin_password() {
  local secret_pw
  secret_pw=$(get_password_from_secret || true)
  if [[ -n "${secret_pw}" ]]; then
    log "retrieved Forgejo admin password from Kubernetes secret"
    printf '%s' "${secret_pw}"
    return
  fi
  if command -v vault >/dev/null 2>&1 && [[ -n "${VAULT_ADDR:-}" ]] && [[ -n "${VAULT_TOKEN:-}" ]]; then
    local vault_pw
    if vault_pw=$(vault kv get -field=password "${FORGEJO_ADMIN_SECRET_PATH}" 2>/dev/null); then
      log "retrieved Forgejo admin password from Vault (${FORGEJO_ADMIN_SECRET_PATH})"
      printf '%s' "${vault_pw}"
      return
    fi
  fi
  log "Vault credentials unavailable; generating temporary Forgejo admin password"
  openssl rand -base64 24
}

ensure_forgejo_bootstrap() {
  local admin_password
  admin_password=$(fetch_forgejo_admin_password)

  ensure_forgejo_namespace
  ensure_forgejo_ca_secret

  log "installing/upgrading Forgejo (bootstrap mode)"
  local -a upgrade_args=()
  mapfile -t upgrade_args < <(helm_upgrade_extra_args)
  local -a forgejo_version_args=(--version "${FORGEJO_CHART_VERSION}")
  if [[ -f "${FORGEJO_CHART}" ]]; then
    forgejo_version_args=()
  fi
  helm_cmd upgrade --install "${FORGEJO_RELEASE}" "${FORGEJO_CHART}" \
    "${forgejo_version_args[@]}" \
    --namespace "${FORGEJO_NAMESPACE}" \
    --create-namespace \
    --kube-context "${KIND_CONTEXT}" \
    --values "${FORGEJO_VALUES}" \
    "${upgrade_args[@]}" \
    --set "gitea.admin.username=${FORGEJO_ADMIN_USERNAME}" \
    --set "gitea.admin.password=${admin_password}" \
    --set "gitea.admin.email=${FORGEJO_ADMIN_EMAIL}"

  log "waiting for Forgejo deployment"
  kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" rollout status deployment/"${FORGEJO_RELEASE}" --timeout=600s

  local final_password
  final_password=$(get_password_from_secret || true)
  if [[ -z "${final_password}" ]]; then
    final_password="${admin_password}"
  else
    log "updated Forgejo admin password from secret"
  fi
  FORGEJO_ADMIN_PASSWORD="${final_password}"
}

ensure_forgejo_namespace() {
  if kubectl --context "${KIND_CONTEXT}" get namespace "${FORGEJO_NAMESPACE}" >/dev/null 2>&1; then
    return
  fi
  log "creating namespace ${FORGEJO_NAMESPACE}"
  kubectl --context "${KIND_CONTEXT}" create namespace "${FORGEJO_NAMESPACE}" >/dev/null
}

ensure_forgejo_ca_secret() {
  local ca_file="${REPO_ROOT}/shared/certs/deploykube-root-ca.crt"
  if [[ ! -f "${ca_file}" ]]; then
    log "missing DeployKube root CA at ${ca_file}; run Step CA bootstrap before Stage 1"
    exit 1
  fi
  log "ensuring forgejo-oidc-ca secret exists in ${FORGEJO_NAMESPACE}"
  kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" create secret generic forgejo-oidc-ca \
    --from-file=ca.crt="${ca_file}" \
    --dry-run=client -o yaml | kubectl --context "${KIND_CONTEXT}" apply -f -
}

ensure_forgejo_repo_tls_secret() {
  if kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_REPO_TLS_SECRET}" >/dev/null 2>&1; then
    return 0
  fi

  log "creating Forgejo internal TLS secret ${FORGEJO_REPO_TLS_SECRET}"
  local tmp_dir key_file crt_file openssl_cnf
  tmp_dir="$(mktemp -d)"
  key_file="${tmp_dir}/tls.key"
  crt_file="${tmp_dir}/tls.crt"
  openssl_cnf="${tmp_dir}/openssl.cnf"
  cat >"${openssl_cnf}" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req
[req_distinguished_name]
CN = ${FORGEJO_REPO_TLS_HOST}
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = forgejo-https
DNS.2 = forgejo-https.${FORGEJO_NAMESPACE}
DNS.3 = forgejo-https.${FORGEJO_NAMESPACE}.svc
DNS.4 = forgejo-https.${FORGEJO_NAMESPACE}.svc.cluster.local
DNS.5 = ${FORGEJO_REPO_TLS_HOST}
EOF
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${key_file}" \
    -out "${crt_file}" \
    -config "${openssl_cnf}" >/dev/null 2>&1

  kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" create secret tls "${FORGEJO_REPO_TLS_SECRET}" \
    --cert="${crt_file}" \
    --key="${key_file}" \
    --dry-run=client -o yaml | kubectl --context "${KIND_CONTEXT}" apply -f -
  rm -rf "${tmp_dir}"
}

ensure_forgejo_repo_tls_proxy() {
  log "ensuring Forgejo internal TLS proxy endpoint"
  cat <<EOF | kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: forgejo-tls-proxy-nginx
data:
  nginx.conf: |
    pid /tmp/nginx.pid;
    error_log /dev/stderr info;
    events {}
    http {
      access_log /dev/stdout;
      client_body_temp_path /tmp/nginx-client-body;
      proxy_temp_path /tmp/nginx-proxy-temp;
      fastcgi_temp_path /tmp/nginx-fastcgi-temp;
      uwsgi_temp_path /tmp/nginx-uwsgi-temp;
      scgi_temp_path /tmp/nginx-scgi-temp;
      server {
        listen 8443 ssl;
        ssl_certificate /tls/tls.crt;
        ssl_certificate_key /tls/tls.key;
        client_max_body_size 0;
        location / {
          proxy_pass http://forgejo-http.${FORGEJO_NAMESPACE}.svc.cluster.local:3000;
          proxy_http_version 1.1;
          proxy_set_header Host \$host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: forgejo-tls-proxy
  labels:
    app.kubernetes.io/name: forgejo-tls-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: forgejo-tls-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: forgejo-tls-proxy
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - containerPort: 8443
              name: https
          readinessProbe:
            tcpSocket:
              port: 8443
          livenessProbe:
            tcpSocket:
              port: 8443
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: tls
              mountPath: /tls
              readOnly: true
            - name: tmp
              mountPath: /tmp
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
      volumes:
        - name: nginx-conf
          configMap:
            name: forgejo-tls-proxy-nginx
        - name: tls
          secret:
            secretName: ${FORGEJO_REPO_TLS_SECRET}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: forgejo-https
  labels:
    app.kubernetes.io/name: forgejo-tls-proxy
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: forgejo-tls-proxy
  ports:
    - name: https
      port: 443
      targetPort: https
EOF
  kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" rollout status deployment/forgejo-tls-proxy --timeout=300s
}

ensure_forgejo_repo_tls_endpoint() {
  ensure_forgejo_repo_tls_secret
  ensure_forgejo_repo_tls_proxy
}

run_forgejo_repo_seed() {
  local helper="${REPO_ROOT}/shared/scripts/forgejo-seed-repo.sh"
  if [[ ! -x "${helper}" ]]; then
    log "Forgejo repo seed helper ${helper} missing or not executable"
    exit 1
  fi
  local args=(--context "${KIND_CONTEXT}" --gitops-path "${GITOPS_LOCAL_REPO}" --sentinel "${FORGEJO_SEED_SENTINEL}" --port "${FORGEJO_PORT_FORWARD_PORT}")
  if [[ "${FORGEJO_FORCE_SEED}" == "true" ]]; then
    args+=("--force")
  fi
  log "running Forgejo repo seed helper"
  "${helper}" "${args[@]}"
}

preflight_gitops_seed_guardrail() {
  local helper="${REPO_ROOT}/shared/scripts/preflight-gitops-seed-guardrail.sh"
  if [[ ! -x "${helper}" ]]; then
    log "preflight guardrail helper missing or not executable: ${helper}"
    exit 1
  fi
  "${helper}" \
    --deployment-id "${DEPLOYKUBE_DEPLOYMENT_ID}" \
    --seed-sentinel "${FORGEJO_SEED_SENTINEL}" \
    --force-seed "${FORGEJO_FORCE_SEED}"
}

ensure_argocd_bootstrap() {
  log "installing/upgrading Argo CD (bootstrap mode)"
  if [[ -z "${OFFLINE_BUNDLE_DIR}" ]]; then
    helm_cmd repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  else
    log "Offline mode: skipping 'helm repo add' for Argo CD (using local chart: ${ARGO_CHART})"
  fi

  # On reruns (especially after Istio + namespace injection are enabled), Helm can get stuck waiting
  # on a previous redis secret-init hook Job that never completes (sidecar injected, stuck NotReady).
  # Remove it best-effort before attempting the upgrade.
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" delete job \
    "${ARGO_RELEASE}-argocd-redis-secret-init" \
    "${ARGO_RELEASE}-redis-secret-init" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" delete pod \
    -l job-name="${ARGO_RELEASE}-argocd-redis-secret-init" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true

  local -a upgrade_args=()
  mapfile -t upgrade_args < <(helm_upgrade_extra_args)

  local -a argocd_version_args=(--version "${ARGO_CHART_VERSION}")
  if [[ -f "${ARGO_CHART}" ]]; then
    argocd_version_args=()
  fi
  helm_cmd upgrade --install "${ARGO_RELEASE}" "${ARGO_CHART}" \
    --namespace "${ARGO_NAMESPACE}" \
    --create-namespace \
    --kube-context "${KIND_CONTEXT}" \
    --values "${ARGO_VALUES}" \
    --values "${ARGO_VALUES_RESOURCES}" \
    --values "${ARGO_VALUES_PROBES}" \
    "${argocd_version_args[@]}" \
    "${upgrade_args[@]}" \
    --set "global.image.tag=${ARGO_APP_VERSION}"

  log "waiting for Argo CD deployments"
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" rollout status deployment/"${ARGO_RELEASE}"-argocd-server --timeout=300s
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" rollout status deployment/"${ARGO_RELEASE}"-argocd-repo-server --timeout=300s
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" rollout status deployment/"${ARGO_RELEASE}"-argocd-redis --timeout=300s
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" rollout status statefulset/"${ARGO_RELEASE}"-argocd-application-controller --timeout=300s
}

ensure_argocd_sops_secret() {
  log "ensuring Argo CD namespace and SOPS age key secret"
  kubectl --context "${KIND_CONTEXT}" create namespace "${ARGO_NAMESPACE}" --dry-run=client -o yaml | kubectl --context "${KIND_CONTEXT}" apply -f -
  check_sops_age_key_custody_gate
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" create secret generic argocd-sops-age \
    --from-file=age.key="${SOPS_AGE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl --context "${KIND_CONTEXT}" apply -f -
}

get_argocd_admin_password() {
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null || true
}

register_git_repository_with_argocd() {
  local admin_password="${FORGEJO_ADMIN_PASSWORD:-}"
  if [[ -z "${admin_password}" ]]; then
    admin_password=$(get_password_from_secret || true)
  fi
  if [[ -z "${admin_password}" ]]; then
    log "unable to determine Forgejo admin password for Argo registration"
    exit 1
  fi
  local repo_url="https://${FORGEJO_REPO_TLS_HOST}/${FORGEJO_ORG}/${FORGEJO_REPO}.git"

  log "registering Forgejo repository with Argo CD"
  cat <<EOF | kubectl --context "${KIND_CONTEXT}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: forgejo-bootstrap-repo
  namespace: ${ARGO_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  url: ${repo_url}
  username: ${FORGEJO_ADMIN_USERNAME}
  password: ${admin_password}
  type: git
EOF
}

ensure_argocd_forgejo_tls_trust() {
  log "configuring Argo CD trust for Forgejo internal TLS endpoint"
  local cert repo_server_deploy cert_key
  cert="$(kubectl --context "${KIND_CONTEXT}" -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_REPO_TLS_SECRET}" -o jsonpath='{.data.tls\.crt}' | base64 --decode)"
  cert_key="${FORGEJO_REPO_TLS_HOST}"
  cat <<EOF | kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-tls-certs-cm
  labels:
    app.kubernetes.io/part-of: argocd
data:
  ${cert_key}: |
$(printf '%s\n' "${cert}" | sed 's/^/    /')
EOF
  repo_server_deploy="${ARGO_RELEASE}-argocd-repo-server"
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" rollout restart deployment "${repo_server_deploy}" >/dev/null 2>&1 || true
  kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" rollout status deployment "${repo_server_deploy}" --timeout=300s
}

apply_root_application() {
  local repo_url="https://${FORGEJO_REPO_TLS_HOST}/${FORGEJO_ORG}/${FORGEJO_REPO}.git"

  local autosync_yaml=""
  if [[ "${PLATFORM_APPS_AUTOSYNC}" == "true" ]]; then
    autosync_yaml="$(cat <<EOF
    automated:
      prune: true
      selfHeal: true
EOF
)"
  fi

  log "applying root Argo CD Application (${ARGO_APP_NAME})"
  cat <<EOF | kubectl --context "${KIND_CONTEXT}" apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGO_APP_NAME}
  namespace: ${ARGO_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  destination:
    name: in-cluster
    namespace: ${ARGO_NAMESPACE}
  source:
    repoURL: ${repo_url}
    targetRevision: main
    path: ${ARGO_APP_PATH}
  syncPolicy:
${autosync_yaml}
    syncOptions:
      - CreateNamespace=true
EOF
}

ensure_argocd_platform_project() {
  local appproject="${REPO_ROOT}/platform/gitops/apps/base/appproject-platform.yaml"
  if [[ ! -f "${appproject}" ]]; then
    log "ERROR: missing AppProject manifest: ${appproject}"
    exit 1
  fi
  log "applying Argo CD AppProject/platform"
  kubectl --context "${KIND_CONTEXT}" apply -f "${appproject}"
}

ensure_bootstrap_namespaces_for_root_app() {
  # platform-apps renders tenant-registry ConfigMaps in these namespaces before child
  # Applications may have created them; precreate to avoid root sync failures.
  local ns
  for ns in keycloak vault-system garage rbac-system backup-system; do
    kubectl --context "${KIND_CONTEXT}" create namespace "${ns}" --dry-run=client -o yaml | \
      kubectl --context "${KIND_CONTEXT}" apply -f - >/dev/null
  done
}

wait_for_application_synced() {
  if [[ "${WAIT_FOR_PLATFORM_APPS}" != "true" ]]; then
    log "skipping wait for ${ARGO_APP_NAME} health (WAIT_FOR_PLATFORM_APPS=${WAIT_FOR_PLATFORM_APPS})"
    return
  fi
  log "waiting for Argo Application ${ARGO_APP_NAME} to become Healthy/Synced"
  local attempts=0
  local max_attempts=60
  while (( attempts < max_attempts )); do
    local sync_status health_status
    sync_status=$(kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" get applications.argoproj.io "${ARGO_APP_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health_status=$(kubectl --context "${KIND_CONTEXT}" -n "${ARGO_NAMESPACE}" get applications.argoproj.io "${ARGO_APP_NAME}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
      log "Argo Application ${ARGO_APP_NAME} is Healthy/Synced"
      return
    fi
    sleep 5
    attempts=$((attempts + 1))
  done
  log "warning: Argo Application ${ARGO_APP_NAME} did not reach Healthy/Synced after ${max_attempts} attempts"
}

main() {
  ensure_prerequisites
  maybe_wire_offline_bundle
  preflight_gitops_seed_guardrail
  ensure_forgejo_bootstrap
  run_forgejo_repo_seed
  ensure_forgejo_repo_tls_endpoint
  ensure_argocd_sops_secret
  ensure_argocd_bootstrap
  ensure_argocd_forgejo_tls_trust
  register_git_repository_with_argocd
  ensure_argocd_platform_project
  ensure_bootstrap_namespaces_for_root_app
  apply_root_application
  wait_for_application_synced
  local argocd_pw
  argocd_pw=$(get_argocd_admin_password)
  if [[ -n "${argocd_pw}" ]]; then
    log "Argo CD admin password: ${argocd_pw}"
  else
    log "Argo CD local admin account disabled (admin.enabled=false)"
  fi
  log "Stage 1 complete – Forgejo and Argo CD are ready for GitOps"
}

main "$@"
