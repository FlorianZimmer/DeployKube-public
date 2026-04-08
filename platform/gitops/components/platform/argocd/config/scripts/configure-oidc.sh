#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="argocd-oidc-config"
NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
CONFIGMAP_NAME="${ARGOCD_CM_NAME:-argocd-cm}"
RBAC_CM_NAME="${ARGOCD_RBAC_CM_NAME:-argocd-rbac-cm}"
SECRET_NAME="${ARGOCD_SECRET_NAME:-argocd-secret}"
CA_SECRET_NAME="${ARGOCD_CA_SECRET_NAME:-argocd-oidc-ca}"
KEYCLOAK_APP="${KEYCLOAK_BOOTSTRAP_APP:-platform-keycloak-bootstrap}"
ARGOCD_HOST="${ARGOCD_HOST:?ARGOCD_HOST required}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:?KEYCLOAK_HOST required}"
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

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

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
  kubectl -n "${NAMESPACE}" patch configmap "${RBAC_CM_NAME}" --type merge -p "$(
    jq -n --arg policy "${policy_csv}" '{data:{"policy.csv":$policy,"policy.default":"role:readonly"}}'
  )"
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
  wait_for_application "${KEYCLOAK_APP}"
  wait_for_secret_key "${SECRET_NAME}" "oidc.clientSecret"
  wait_for_secret_key "${CA_SECRET_NAME}" "ca.crt"
  patch_configmap
  restart_workload deployment "${SERVER_DEPLOYMENT}"
  restart_workload deployment "${REPO_DEPLOYMENT}"
  restart_workload deployment "${APPSET_DEPLOYMENT}"
  restart_workload statefulset "${CONTROLLER_STATEFULSET}"
  log "Argo CD OIDC configuration updated"
}

main "$@"
