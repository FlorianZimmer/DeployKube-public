#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="argocd-oidc-config"
ISTIO_HELPER="${ISTIO_HELPER:-/helpers/istio-native-exit.sh}"
NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
CONFIGMAP_NAME="${ARGOCD_CM_NAME:-argocd-cm}"
RBAC_CM_NAME="${ARGOCD_RBAC_CM_NAME:-argocd-rbac-cm}"
SECRET_NAME="${ARGOCD_SECRET_NAME:-argocd-secret}"
CA_SECRET_NAME="${ARGOCD_CA_SECRET_NAME:-argocd-oidc-ca}"
KEYCLOAK_APP="${KEYCLOAK_BOOTSTRAP_APP:-platform-keycloak-bootstrap}"
DEPLOYMENT_CONFIG_FILE="${DEPLOYMENT_CONFIG_FILE:-/etc/deploykube/deployment-config/deployment-config.yaml}"
ARGOCD_HOST="${ARGOCD_HOST:-}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-deploykube-admin}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-argocd}"
OIDC_GROUPS_FIELD="${OIDC_GROUPS_FIELD:-groups}"
SCOPES=(openid profile email roles)
SERVER_DEPLOYMENT="${ARGOCD_SERVER_DEPLOYMENT:-argo-cd-argocd-server}"
REPO_DEPLOYMENT="${ARGOCD_REPO_DEPLOYMENT:-argo-cd-argocd-repo-server}"
APPSET_DEPLOYMENT="${ARGOCD_APPSET_DEPLOYMENT:-argo-cd-argocd-applicationset-controller}"
CONTROLLER_STATEFULSET="${ARGOCD_CONTROLLER_STATEFULSET:-argo-cd-argocd-application-controller}"
ROLL_OUT_TIMEOUT="${ROLL_OUT_TIMEOUT:-600s}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
STATE_CONFIGMAP="${OIDC_STATE_CONFIGMAP:-argocd-oidc-config-state}"
IDEMPOTENCE_VERSION="${IDEMPOTENCE_VERSION:-2026-03-02-v1}"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  log "missing dependency: sha256sum or shasum"
  return 1
}

build_policy_csv() {
  local policy_csv
  policy_csv=$'p, role:platform-admin, *, *, *, allow\n'
  policy_csv+=$'p, role:platform-operator, applications, *, platform/*, allow\n'
  policy_csv+=$'p, role:platform-operator, projects, get, platform, allow\n'
  policy_csv+=$'p, role:argocd-sync-bot, applications, get, platform/*, allow\n'
  policy_csv+=$'p, role:argocd-sync-bot, applications, sync, platform/*, allow\n'
  policy_csv+=$'p, role:app-admin, applications, *, apps-*/.*, allow\n'
  policy_csv+=$'p, role:app-admin, projects, get, apps-*, allow\n'
  policy_csv+=$'p, role:app-contrib, applications, get, apps-*/.*, allow\n'
  policy_csv+=$'p, role:app-contrib, applications, sync, apps-*/.*, allow\n'
  policy_csv+=$'p, role:auditor, applications, get, */.*, allow\n'
  policy_csv+=$'p, role:auditor, projects, get, *, allow\n'
  policy_csv+=$'g, dk-platform-admins, role:platform-admin\n'
  policy_csv+=$'g, dk-platform-operators, role:platform-operator\n'
  policy_csv+=$'g, dk-auditors, role:auditor\n'
  policy_csv+=$'g, dk-bot-argocd-sync, role:argocd-sync-bot\n'
  policy_csv+=$'g, dk-app-*-maintainers, role:app-admin\n'
  policy_csv+=$'g, dk-app-*-contributors, role:app-contrib\n'
  printf '%s' "${policy_csv}"
}

derive_hosts_from_deployment_config() {
  if [[ -n "${ARGOCD_HOST}" && -n "${KEYCLOAK_HOST}" ]]; then
    return
  fi
  if [[ ! -f "${DEPLOYMENT_CONFIG_FILE}" ]]; then
    log "deployment config missing at ${DEPLOYMENT_CONFIG_FILE}; set ARGOCD_HOST/KEYCLOAK_HOST explicitly to override"
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    log "missing dependency: yq (needed to parse ${DEPLOYMENT_CONFIG_FILE})"
    exit 1
  fi
  if [[ -z "${ARGOCD_HOST}" ]]; then
    ARGOCD_HOST="$(yq -r '.spec.dns.hostnames.argocd // ""' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)"
  fi
  if [[ -z "${KEYCLOAK_HOST}" ]]; then
    KEYCLOAK_HOST="$(yq -r '.spec.dns.hostnames.keycloak // ""' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)"
  fi
  if [[ -z "${ARGOCD_HOST}" || -z "${KEYCLOAK_HOST}" ]]; then
    log "unable to derive required hostnames from ${DEPLOYMENT_CONFIG_FILE}"
    exit 1
  fi
}

if [[ -f "${ISTIO_HELPER}" ]]; then
  # shellcheck disable=SC1090
  . "${ISTIO_HELPER}"
  trap deploykube_istio_quit_sidecar EXIT INT TERM
fi

wait_for_secret_key() {
  local secret="$1" key="$2" attempt=0 value=""
  local jsonpath_key
  jsonpath_key=${key//./\\.}
  while (( attempt < WAIT_ATTEMPTS )); do
    value=$(kubectl -n "${NAMESPACE}" get secret "${secret}" -o jsonpath="{.data.${jsonpath_key}}" 2>/dev/null || true)
    if [[ -n "${value}" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for secret ${secret} key ${key} (${attempt}/${WAIT_ATTEMPTS})"
    sleep "${WAIT_INTERVAL}"
  done
  log "secret ${secret} missing required key ${key}"
  return 1
}

wait_for_application() {
  local app="$1" attempt=0
  while (( attempt < WAIT_ATTEMPTS )); do
    local health sync
    health=$(kubectl -n "${NAMESPACE}" get applications.argoproj.io "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    sync=$(kubectl -n "${NAMESPACE}" get applications.argoproj.io "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    if [[ "${health}" == "Healthy" && "${sync}" == "Synced" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for Application ${app} (health=${health:-unknown} sync=${sync:-unknown})"
    sleep "${WAIT_INTERVAL}"
  done
  log "Application ${app} never reached Healthy/Synced"
  return 1
}

patch_configmap() {
  local url="https://${ARGOCD_HOST}"
  local oidc_config
  local scopes_csv
  local ca_b64
  local ca_pem
  local indented_ca
  scopes_csv=$(printf '"%s",' "${SCOPES[@]}" | sed 's/,$//')
  if [[ -n "${OIDC_CA_FILE:-}" && -f "${OIDC_CA_FILE}" ]]; then
    log "reading OIDC root CA from file ${OIDC_CA_FILE}"
    ca_pem=$(cat "${OIDC_CA_FILE}")
  else
    ca_b64=$(kubectl -n "${NAMESPACE}" get secret "${CA_SECRET_NAME}" -o jsonpath='{.data.ca\\.crt}')
    log "raw OIDC root CA b64 bytes=$(printf '%s' "${ca_b64}" | wc -c | tr -d ' ')"
    ca_pem=$(printf '%s' "${ca_b64}" | base64 -d)
  fi
  log "embedding OIDC root CA (bytes=$(printf '%s' "${ca_pem}" | wc -c | tr -d ' '))"
  indented_ca=$(printf '%s\n' "${ca_pem}" | sed 's/^/  /')
  oidc_config=$(cat <<CONFIG
name: Keycloak
issuer: https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}
clientID: ${OIDC_CLIENT_ID}
clientSecret: \$${SECRET_NAME}:oidc.clientSecret
rootCA: |
${indented_ca}
requestedScopes: [${scopes_csv}]
requestedIDTokenClaims:
  groups:
    essential: true
groupsFieldName: ${OIDC_GROUPS_FIELD}
logoutURL: https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/logout
CONFIG
)

  kubectl -n "${NAMESPACE}" patch configmap "${CONFIGMAP_NAME}" --type merge -p "$(
    jq -n --arg url "${url}" --arg oidc "${oidc_config}" '{data:{"url":$url,"application.instanceLabelKey":"argocd.argoproj.io/instance","admin.enabled":"false","kustomize.buildOptions":"--enable-helm","oidc.config":$oidc}}'
  )"

  local policy_csv
  policy_csv="$(build_policy_csv)"
  kubectl -n "${NAMESPACE}" patch configmap "${RBAC_CM_NAME}" --type merge -p "$(
    jq -n --arg policy "${policy_csv}" '{data:{"policy.csv":$policy,"policy.default":"role:readonly"}}'
  )"
}

record_idempotence_marker() {
  local scopes_csv policy_csv ca_marker existing_sha existing_version desired_sha now_utc
  scopes_csv=$(printf '%s,' "${SCOPES[@]}" | sed 's/,$//')
  policy_csv="$(build_policy_csv)"

  if [[ -n "${OIDC_CA_FILE:-}" && -f "${OIDC_CA_FILE}" ]]; then
    ca_marker="$(cat "${OIDC_CA_FILE}" | sha256_text)"
  else
    ca_marker="$(kubectl -n "${NAMESPACE}" get secret "${CA_SECRET_NAME}" -o jsonpath='{.data.ca\\.crt}' | sha256_text)"
  fi

  desired_sha="$(
    printf '%s' "${ARGOCD_HOST}|${KEYCLOAK_HOST}|${KEYCLOAK_REALM}|${OIDC_CLIENT_ID}|${OIDC_GROUPS_FIELD}|${scopes_csv}|${policy_csv}|${ca_marker}" \
      | sha256_text
  )"
  existing_sha="$(kubectl -n "${NAMESPACE}" get configmap "${STATE_CONFIGMAP}" -o jsonpath='{.data.configSha256}' 2>/dev/null || true)"
  existing_version="$(kubectl -n "${NAMESPACE}" get configmap "${STATE_CONFIGMAP}" -o jsonpath='{.data.configVersion}' 2>/dev/null || true)"
  if [[ "${existing_sha}" == "${desired_sha}" && "${existing_version}" == "${IDEMPOTENCE_VERSION}" ]]; then
    log "idempotence marker already current (${STATE_CONFIGMAP} sha=${desired_sha})"
    return 0
  fi

  now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kubectl -n "${NAMESPACE}" patch configmap "${STATE_CONFIGMAP}" --type merge -p "$(
    jq -n \
      --arg version "${IDEMPOTENCE_VERSION}" \
      --arg sha "${desired_sha}" \
      --arg ts "${now_utc}" \
      '{data:{"configVersion":$version,"configSha256":$sha,"lastAppliedAt":$ts}}'
  )"
  log "updated idempotence marker ${STATE_CONFIGMAP} (${IDEMPOTENCE_VERSION})"
}

restart_workload() {
  local kind="$1" name="$2"
  if [[ -z "${name}" ]]; then
    return
  fi
  if ! kubectl -n "${NAMESPACE}" get "${kind}/${name}" >/dev/null 2>&1; then
    log "${kind}/${name} not found; skipping restart"
    return
  fi
  log "restarting ${kind}/${name}"
  kubectl -n "${NAMESPACE}" rollout restart "${kind}/${name}"
  case "${kind}" in
    deployment)
      wait_for_deployment_ready "${name}"
      ;;
    statefulset)
      wait_for_statefulset_ready "${name}"
      ;;
    *)
      kubectl -n "${NAMESPACE}" rollout status "${kind}/${name}" --timeout="${ROLL_OUT_TIMEOUT}"
      ;;
  esac
}

wait_for_deployment_ready() {
  local name="$1" attempt=0
  while (( attempt < WAIT_ATTEMPTS )); do
    local desired updated available observed generation
    desired=$(kubectl -n "${NAMESPACE}" get deployment "${name}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    updated=$(kubectl -n "${NAMESPACE}" get deployment "${name}" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)
    available=$(kubectl -n "${NAMESPACE}" get deployment "${name}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
    observed=$(kubectl -n "${NAMESPACE}" get deployment "${name}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
    generation=$(kubectl -n "${NAMESPACE}" get deployment "${name}" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    desired="${desired:-1}"
    if [[ "${observed}" == "${generation}" && "${updated:-0}" == "${desired}" && "${available:-0}" == "${desired}" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for deployment/${name} rollout (${attempt}/${WAIT_ATTEMPTS}) desired=${desired} updated=${updated:-0} available=${available:-0}"
    sleep "${WAIT_INTERVAL}"
  done
  log "deployment/${name} rollout timed out"
  return 1
}

wait_for_statefulset_ready() {
  local name="$1" attempt=0
  while (( attempt < WAIT_ATTEMPTS )); do
    local desired ready observed generation current update
    desired=$(kubectl -n "${NAMESPACE}" get statefulset "${name}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    ready=$(kubectl -n "${NAMESPACE}" get statefulset "${name}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    observed=$(kubectl -n "${NAMESPACE}" get statefulset "${name}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
    generation=$(kubectl -n "${NAMESPACE}" get statefulset "${name}" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    current=$(kubectl -n "${NAMESPACE}" get statefulset "${name}" -o jsonpath='{.status.currentRevision}' 2>/dev/null || true)
    update=$(kubectl -n "${NAMESPACE}" get statefulset "${name}" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)
    desired="${desired:-1}"
    if [[ "${observed}" == "${generation}" && "${ready:-0}" == "${desired}" && "${current}" == "${update}" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for statefulset/${name} rollout (${attempt}/${WAIT_ATTEMPTS}) desired=${desired} ready=${ready:-0}"
    sleep "${WAIT_INTERVAL}"
  done
  log "statefulset/${name} rollout timed out"
  return 1
}

main() {
  log "waiting for Keycloak bootstrap (${KEYCLOAK_APP})"
  derive_hosts_from_deployment_config
  wait_for_application "${KEYCLOAK_APP}"
  wait_for_secret_key "${SECRET_NAME}" "oidc.clientSecret"
  wait_for_secret_key "${CA_SECRET_NAME}" "ca.crt"
  patch_configmap
  restart_workload deployment "${SERVER_DEPLOYMENT}"
  restart_workload deployment "${REPO_DEPLOYMENT}"
  restart_workload deployment "${APPSET_DEPLOYMENT}"
  restart_workload statefulset "${CONTROLLER_STATEFULSET}"
  record_idempotence_marker
  log "Argo CD OIDC configuration updated"
}

main "$@"
