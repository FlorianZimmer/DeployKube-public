#!/usr/bin/env bash
set -euo pipefail

# Flow (high-level)
#   ┌────────────────┐
#   │Stage bootstrap │  – ensure prerequisites + sync root app
#   └──────┬─────────┘
#          │
#   ┌──────▼─────────┐    ┌─────────────┐
#   │Pause Argo CD   │    │Pause root   │
#   │(controller +   │◄───┤Application  │
#   │auto-sync)      │    └────┬────────┘
#   └──────┬─────────┘         │
#          │                   │
#   ┌──────▼─────────┐         │
#   │Wipe core →     │─────────┘ delete + scrub storage
#   │ reinit + sync  │
#   │Reapply secrets │
#   │Seed/verify deps│
#   └──────┬─────────┘
#          │ cleanup handler resumes Argo + root app
#   ┌──────▼─────────┐
#   │Resume Argo CD  │
#   └────────────────┘

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}" )/../.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-deploykube-dev}"

# Deployment Secrets Bundle (DSB)
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-}"
DEPLOYKUBE_DEPLOYMENTS_DIR="${DEPLOYKUBE_DEPLOYMENTS_DIR:-${REPO_ROOT}/platform/gitops/deployments}"
DEPLOYMENT_DIR=""
DEPLOYMENT_CONFIG_YAML=""

DEFAULT_AGE_KEY_PATH="${HOME}/.config/sops/age/keys.txt"
DEFAULT_DEPLOYMENT_AGE_KEY_PATH=""
if [[ -n "${DEPLOYKUBE_DEPLOYMENT_ID}" ]]; then
  DEFAULT_DEPLOYMENT_AGE_KEY_PATH="${HOME}/.config/deploykube/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/sops/age.key"
fi
AGE_KEY_FILE_DEFAULT="${SOPS_AGE_KEY_FILE:-${DEFAULT_AGE_KEY_PATH}}"
AGE_KEY_FILE="${AGE_KEY_FILE:-${AGE_KEY_FILE_DEFAULT}}"

resolve_deployment_id() {
  if [[ -n "${DEPLOYKUBE_DEPLOYMENT_ID}" ]]; then
    return 0
  fi
  if [[ "${KUBE_CONTEXT}" == kind-* ]]; then
    DEPLOYKUBE_DEPLOYMENT_ID="mac-orbstack"
    return 0
  fi
  log "DEPLOYKUBE_DEPLOYMENT_ID is required for non-kind clusters (set it to the deployment directory name under ${DEPLOYKUBE_DEPLOYMENTS_DIR})"
  exit 1
}

resolve_dsb_paths() {
  resolve_deployment_id
  local dep_dir="${DEPLOYKUBE_DEPLOYMENTS_DIR}/${DEPLOYKUBE_DEPLOYMENT_ID}"
  DEPLOYMENT_DIR="${dep_dir}"
  DEPLOYMENT_CONFIG_YAML="${dep_dir}/config.yaml"
  if [[ ! -d "${dep_dir}" ]]; then
    log "deployment directory ${dep_dir} missing"
    exit 1
  fi
  if [[ ! -f "${dep_dir}/.sops.yaml" ]]; then
    log "deployment SOPS config missing: ${dep_dir}/.sops.yaml"
    exit 1
  fi
  if [[ ! -d "${dep_dir}/secrets" ]]; then
    log "deployment secrets directory missing: ${dep_dir}/secrets"
    exit 1
  fi

  # Default secret paths (overrideable via env vars below).
  KMS_SHIM_KEY_SECRET_PATH_DEFAULT="${dep_dir}/secrets/kms-shim-key.secret.sops.yaml"
  KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH_DEFAULT="${dep_dir}/secrets/kms-shim-token.vault-system.secret.sops.yaml"
  KMS_SHIM_TOKEN_SECRET_SHIM_PATH_DEFAULT="${dep_dir}/secrets/kms-shim-token.vault-seal-system.secret.sops.yaml"
  CORE_SECRET_PATH_DEFAULT="${dep_dir}/secrets/vault-init.secret.sops.yaml"
  SOPS_CONFIG_DEFAULT="${dep_dir}/.sops.yaml"

  KMS_SHIM_KEY_SECRET_PATH="${KMS_SHIM_KEY_SECRET_PATH:-${KMS_SHIM_KEY_SECRET_PATH_DEFAULT}}"
  KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH="${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH:-${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH_DEFAULT}}"
  KMS_SHIM_TOKEN_SECRET_SHIM_PATH="${KMS_SHIM_TOKEN_SECRET_SHIM_PATH:-${KMS_SHIM_TOKEN_SECRET_SHIM_PATH_DEFAULT}}"
  CORE_SECRET_PATH="${CORE_SECRET_PATH:-${CORE_SECRET_PATH_DEFAULT}}"

  # Prefer deployment-scoped key if present; fall back to legacy.
  if [[ -n "${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}" && -f "${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}" ]]; then
    AGE_KEY_FILE_DEFAULT="${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}"
  fi
  AGE_KEY_FILE="${AGE_KEY_FILE:-${AGE_KEY_FILE_DEFAULT}}"
}

detect_root_of_trust() {
  if [[ -z "${DEPLOYMENT_CONFIG_YAML}" || ! -f "${DEPLOYMENT_CONFIG_YAML}" ]]; then
    ROOT_OF_TRUST_PROVIDER="kmsShim"
    ROOT_OF_TRUST_MODE="inCluster"
    ROOT_OF_TRUST_EXTERNAL_ADDR=""
    return 0
  fi

  ROOT_OF_TRUST_PROVIDER="$(yq -r '.spec.secrets.rootOfTrust.provider // "kmsShim"' "${DEPLOYMENT_CONFIG_YAML}" 2>/dev/null || echo "kmsShim")"
  ROOT_OF_TRUST_MODE="$(yq -r '.spec.secrets.rootOfTrust.mode // "inCluster"' "${DEPLOYMENT_CONFIG_YAML}" 2>/dev/null || echo "inCluster")"
  ROOT_OF_TRUST_EXTERNAL_ADDR="$(yq -r '.spec.secrets.rootOfTrust.external.address // ""' "${DEPLOYMENT_CONFIG_YAML}" 2>/dev/null || echo "")"

  case "${ROOT_OF_TRUST_PROVIDER}" in
    kmsShim) ;;
    *)
      log "invalid root-of-trust provider in ${DEPLOYMENT_CONFIG_YAML}: ${ROOT_OF_TRUST_PROVIDER} (want kmsShim)"
      exit 1
      ;;
  esac
  case "${ROOT_OF_TRUST_MODE}" in
    inCluster|external) ;;
    *)
      log "invalid root-of-trust mode in ${DEPLOYMENT_CONFIG_YAML}: ${ROOT_OF_TRUST_MODE} (want inCluster|external)"
      exit 1
      ;;
  esac

  :
}

CORE_NAMESPACE="${CORE_NAMESPACE:-vault-system}"
CORE_STATEFULSET="${CORE_STATEFULSET:-vault}"
CORE_SECRET_NAME="${CORE_SECRET_NAME:-vault-init}"
CORE_SECRET_PATH_DEFAULT=""
CORE_SECRET_PATH="${CORE_SECRET_PATH:-}"
CORE_EXTRA_PVCS=(${CORE_EXTRA_PVCS:-vault-raft-backup})
CORE_BACKUP_PVC_NAME="${CORE_BACKUP_PVC_NAME:-vault-raft-backup}"
CORE_BACKUP_WARMUP_WAIT_TIMEOUT="${CORE_BACKUP_WARMUP_WAIT_TIMEOUT:-300s}"
CORE_NFS_DIRS=(${CORE_NFS_DIRS:-rwo/vault-system-data-vault-0 rwo/vault-system-data-vault-1 rwo/vault-system-data-vault-2 rwo/vault-system-vault-raft-backup})
CORE_BOOTSTRAP_JOB_TIMEOUT="${CORE_BOOTSTRAP_JOB_TIMEOUT:-1800s}"
SECRETS_BOOTSTRAP_JOB_TIMEOUT="${SECRETS_BOOTSTRAP_JOB_TIMEOUT:-900s}"

ROOT_OF_TRUST_PROVIDER="kmsShim"
ROOT_OF_TRUST_MODE="inCluster"
ROOT_OF_TRUST_EXTERNAL_ADDR=""

KMS_SHIM_NAMESPACE="${KMS_SHIM_NAMESPACE:-vault-seal-system}"
KMS_SHIM_APP="${KMS_SHIM_APP:-secrets-kms-shim}"
KMS_SHIM_KEY_SECRET_NAME="${KMS_SHIM_KEY_SECRET_NAME:-kms-shim-key}"
KMS_SHIM_TOKEN_SECRET_NAME="${KMS_SHIM_TOKEN_SECRET_NAME:-kms-shim-token}"
KMS_SHIM_KEY_SECRET_PATH_DEFAULT=""
KMS_SHIM_KEY_SECRET_PATH="${KMS_SHIM_KEY_SECRET_PATH:-}"
KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH_DEFAULT=""
KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH="${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH:-}"
KMS_SHIM_TOKEN_SECRET_SHIM_PATH_DEFAULT=""
KMS_SHIM_TOKEN_SECRET_SHIM_PATH="${KMS_SHIM_TOKEN_SECRET_SHIM_PATH:-}"

CORE_APP="${CORE_APP:-secrets-vault}"
SECRETS_APP="${SECRETS_APP:-secrets-bootstrap}"
ROOT_APP="${ROOT_APP:-platform-apps}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"
CORE_DEP_APPS=(${CORE_DEP_APPS:-secrets-vault-safeguard secrets-vault-bootstrap secrets-vault-config secrets-vault})
VAULT_CONFIGURE_COMPLETE_CONFIGMAP="${VAULT_CONFIGURE_COMPLETE_CONFIGMAP:-vault-configure-complete}"
STEP_CA_NAMESPACE="${STEP_CA_NAMESPACE:-step-system}"
STEP_CA_SEED_APP="${STEP_CA_SEED_APP:-certificates-step-ca-seed}"
STEP_CA_SEED_JOB="${STEP_CA_SEED_JOB:-step-ca-vault-seed}"
STEP_CA_SECRETS_APP="${STEP_CA_SECRETS_APP:-certificates-step-ca-secrets}"
STEP_CA_APP="${STEP_CA_APP:-certificates-step-ca}"
STEP_CA_BOOTSTRAP_APP="${STEP_CA_BOOTSTRAP_APP:-certificates-step-ca-bootstrap}"
STEP_CA_STATEFULSET="${STEP_CA_STATEFULSET:-step-ca-step-certificates}"
STEP_CA_RELEASE_NAME="${STEP_CA_RELEASE_NAME:-step-ca-step-certificates}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
STEP_CA_TLS_SECRET_NAME="${STEP_CA_TLS_SECRET_NAME:-step-ca-root-ca}"
STEP_CA_SECRET_TARGETS=(${STEP_CA_SECRET_TARGETS:-step-ca-step-certificates-config step-ca-step-certificates-certs step-ca-step-certificates-secrets step-ca-step-certificates-ca-password step-ca-step-certificates-provisioner-password})
TENANT_ESO_STORE_NAME="${TENANT_ESO_STORE_NAME:-vault-tenant-smoke-project-demo}"
TENANT_ESO_WAIT_TIMEOUT="${TENANT_ESO_WAIT_TIMEOUT:-300s}"
TENANT_ESO_WAIT_STRICT="${TENANT_ESO_WAIT_STRICT:-false}"
NFS_VOLUME="${NFS_VOLUME:-deploykube-nfs-data}"
DEPLOYKUBE_STORAGE_PROFILE="${DEPLOYKUBE_STORAGE_PROFILE:-}"
LOCAL_PATH_SCRUB_ENABLED=false
LOCAL_PATH_BASE="${LOCAL_PATH_BASE:-/var/mnt/deploykube/local-path}"
GITOPS_DIR="${REPO_ROOT}/platform/gitops"
AUTOUNSEAL_TOKEN_PREFIX="${AUTOUNSEAL_TOKEN_PREFIX:-vtkn-}"
BOOTSTRAP_STATUS_CONFIGMAP="${BOOTSTRAP_STATUS_CONFIGMAP:-vault-bootstrap-status}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
FORGEJO_RELEASE="${FORGEJO_RELEASE:-forgejo}"
FORGEJO_ADMIN_USERNAME="${FORGEJO_ADMIN_USERNAME:-forgejo-admin}"
FORGEJO_ADMIN_SECRET_PATH="${FORGEJO_ADMIN_SECRET_PATH:-secret/forgejo/admin}"
FORGEJO_DB_SECRET_PATH="${FORGEJO_DB_SECRET_PATH:-secret/forgejo/database}"
FORGEJO_REDIS_SECRET_PATH="${FORGEJO_REDIS_SECRET_PATH:-secret/forgejo/redis}"
FORGEJO_DB_NAME="${FORGEJO_DB_NAME:-forgejo}"
FORGEJO_DB_USERNAME="${FORGEJO_DB_USERNAME:-forgejo}"
FORGEJO_ORG="${FORGEJO_ORG:-platform}"
FORGEJO_REPO="${FORGEJO_REPO:-cluster-config}"
FORGEJO_PASSWORD_FILE="${FORGEJO_PASSWORD_FILE:-${REPO_ROOT}/tmp/forgejo-bootstrap-admin.txt}"
FORGEJO_PORT_FORWARD_PORT="${FORGEJO_PORT_FORWARD_PORT:-38080}"
FORGEJO_ARGO_REPO_SECRET_PATH="${FORGEJO_ARGO_REPO_SECRET_PATH:-secret/forgejo/argocd-repo}"
ARGO_REPO_SECRET_NAME="${ARGO_REPO_SECRET_NAME:-repo-forgejo-platform}"
ARGO_REPO_URL="${ARGO_REPO_URL:-https://forgejo-https.forgejo.svc.cluster.local/platform/cluster-config.git}"
PDNS_DB_SECRET_PATH="${PDNS_DB_SECRET_PATH:-secret/dns/powerdns/postgres}"
PDNS_API_SECRET_PATH="${PDNS_API_SECRET_PATH:-secret/dns/powerdns/api}"
PDNS_DB_NAME="${PDNS_DB_NAME:-powerdns}"
PDNS_DB_USERNAME="${PDNS_DB_USERNAME:-powerdns}"
SEED_DNS_VAULT_SECRETS="${SEED_DNS_VAULT_SECRETS:-true}"
SEED_FORGEJO_VAULT_SECRETS="${SEED_FORGEJO_VAULT_SECRETS:-true}"
GITOPS_PUSH="${GITOPS_PUSH:-true}"
NFS_VOLUME_READY=false
ROOT_APP_PAUSED=false
ARGO_CONTROLLER_KIND=""
ARGO_CONTROLLER_RESTORED=false
ARGO_CONTROLLER_PREVIOUS_REPLICAS=""

SKIP_CORE=false
WIPE_CORE=false
REINIT_CORE=false
FORCE=false
UPDATED_SECRETS=false
NEED_SOPS_CONFIGMAP_REFRESH=false
FORGEJO_PF_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]
  --skip-core                   Skip core init
  --wipe-core-data              Delete core StatefulSet/PVCs and scrub NFS paths
  --reinit-core                 Force core `vault operator init`
  --force                       Overwrite existing SOPS files
  --age-key-file <path>         Override Age key path

Environment overrides:
  CORE_BOOTSTRAP_JOB_TIMEOUT      Default ${CORE_BOOTSTRAP_JOB_TIMEOUT}
  SECRETS_BOOTSTRAP_JOB_TIMEOUT   Default ${SECRETS_BOOTSTRAP_JOB_TIMEOUT}
USAGE
}

log() { printf '[vault-init] %s\n' "$1" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || { log "missing dependency: $1"; exit 1; }; }

b64decode() {
  # Use python for portability (macOS base64 flags differ from GNU coreutils).
  python3 -c 'import sys,base64; sys.stdout.write(base64.b64decode(sys.stdin.buffer.read()).decode())'
}

run_kubectl() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

ensure_namespace() {
  local ns="$1"
  run_kubectl create namespace "${ns}" --dry-run=client -o yaml | run_kubectl apply -f - >/dev/null
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-core) SKIP_CORE=true ; shift ;;
      --wipe-core-data) WIPE_CORE=true ; shift ;;
      --reinit-core) REINIT_CORE=true ; shift ;;
      --force) FORCE=true ; shift ;;
      --age-key-file) AGE_KEY_FILE="$2" ; shift 2 ;;
      -h|--help) usage ; exit 0 ;;
      *) log "unknown option: $1" ; usage ; exit 1 ;;
    esac
  done
}

ensure_age_key() {
  local target="${AGE_KEY_FILE:-${DEFAULT_AGE_KEY_PATH}}"
  if [[ -z "${target}" ]]; then
    log "Age key path not specified; set AGE_KEY_FILE or SOPS_AGE_KEY_FILE"
    exit 1
  fi
  if [[ ! -f "${target}" ]]; then
    log "Age key missing at ${target}"
    log "DSB contract: restore the deployment-scoped Age key from out-of-band storage before running this script."
    log "Defaults:"
    if [[ -n "${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}" ]]; then
      log "  - deployment-scoped: ${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}"
    fi
    log "  - legacy fallback:   ${DEFAULT_AGE_KEY_PATH}"
    log ""
    log "If this is a brand-new deployment, use:"
    log "  ./scripts/deployments/scaffold.sh --deployment-id <id> --environment dev|prod|staging --base-domain <domain>"
    exit 1
  fi
  AGE_KEY_FILE="${target}"
  export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"
  AGE_RECIPIENT=$(age-keygen -y "$AGE_KEY_FILE")
}

wait_statefulset() {
  local ns="$1" sts="$2"
  local json replicas
  local attempts=${WAIT_STATEFULSET_APPEAR_ATTEMPTS:-180}
  for _ in $(seq 1 "${attempts}"); do
    if json=$(run_kubectl -n "$ns" get statefulset "$sts" -o json 2>/dev/null); then
      replicas=$(jq -r '.spec.replicas // 1' <<<"$json" 2>/dev/null || echo "1")
      [[ -z "$replicas" ]] && replicas=1
      local wait_mode="running"
      if [[ "$ns" == "$CORE_NAMESPACE" && "$sts" == "$CORE_STATEFULSET" ]]; then
        wait_mode="exec"
      fi
      local i
      for i in $(seq 0 $((replicas-1))); do
        if [[ "$wait_mode" == "exec" ]]; then
          wait_pod_exec_ready "$ns" "${sts}-${i}" || return 1
        else
          wait_pod_running "$ns" "$sts" "$i" || return 1
        fi
      done
      return 0
    fi
    sleep 5
  done
  log "statefulset $ns/$sts did not appear after $((attempts * 5))s"
  return 1
}

wait_deployment_ready() {
  local ns="$1" deploy="$2" timeout="${3:-600s}"
  run_kubectl -n "${ns}" rollout status "deployment/${deploy}" --timeout="${timeout}"
}

wait_job_exists() {
  local ns="$1" job="$2"
  for _ in {1..120}; do
    if run_kubectl -n "$ns" get job "$job" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  log "job ${job} in namespace ${ns} did not appear"
  return 1
}

delete_hook_job() {
  local ns="$1" job="$2"
  # Argo hook Jobs carry a finalizer that can block deletion forever if the hook never completes.
  run_kubectl -n "$ns" patch job "$job" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  run_kubectl -n "$ns" delete job "$job" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

clear_stuck_hook_operation() {
  local app="$1" job="$2" job_namespace="${3:-$CORE_NAMESPACE}"
  local app_json message
  app_json=$(run_kubectl -n argocd get application "$app" -o json 2>/dev/null || true)
  message=$(jq -r '.status.operationState.message // ""' <<<"$app_json" 2>/dev/null || echo "")
  if [[ "$message" != *"hook batch/Job/${job}"* && "$message" != *"healthy state of batch/Job/${job}"* ]]; then
    return 0
  fi
  if run_kubectl -n "$job_namespace" get job "$job" >/dev/null 2>&1; then
    return 0
  fi
  log "clearing stuck Argo hook operation for ${app} (${job_namespace}/${job} missing)"
  pause_self_heal "$app" || true
  run_kubectl -n argocd patch application "$app" --type=json -p '[{"op":"remove","path":"/operation"}]' >/dev/null 2>&1 || true
  resume_self_heal "$app" || true
}

wait_job_complete() {
  local ns="$1" job="$2" timeout="$3"
  # kubectl wait doesn't short-circuit on Job failures; poll so we can surface
  # failures immediately and avoid the full timeout hang.
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=600
  local end=$(( $(date +%s) + timeout_s ))
  local seen=false
  while true; do
    local json
    if ! json=$(run_kubectl -n "$ns" get job "$job" -o json 2>/dev/null); then
      # Many DeployKube Jobs are Argo hooks with delete-on-success (e.g. HookSucceeded).
      # After we've observed the Job exist, it can legitimately disappear *because it
      # succeeded* and Argo deleted it before our poll caught `.status.succeeded`.
      #
      # Treat "Job not found" as completion to avoid flaky bootstrap runs.
      if [[ "${seen}" == "true" ]]; then
        log "job ${job} in namespace ${ns} no longer exists (likely Argo hook deletion); treating as complete"
        return 0
      fi
      log "job ${job} in namespace ${ns} does not exist"
      return 1
    fi
    seen=true
    local succeeded failed
    succeeded=$(jq -r '.status.succeeded // 0' <<<"$json" 2>/dev/null || echo 0)
    failed=$(jq -r '.status.failed // 0' <<<"$json" 2>/dev/null || echo 0)
    if (( succeeded > 0 )); then
      return 0
    fi
    if (( failed > 0 )); then
      log "job ${job} in namespace ${ns} failed; recent logs:"
      run_kubectl -n "$ns" logs "job/${job}" || true
      return 1
    fi
    if (( $(date +%s) >= end )); then
      log "job ${job} in namespace ${ns} did not complete within ${timeout}"
      return 1
    fi
    sleep 5
  done
}

wait_vault_secret() {
  local token="$1" path="$2" timeout="${3:-900s}"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=900
  local end=$(( $(date +%s) + timeout_s ))
  while true; do
    if vault_secret_exists "${token}" "${path}"; then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      log "vault secret ${path} did not appear within ${timeout}"
      return 1
    fi
    sleep 5
  done
}

vault_secret_version() {
  local token="$1" path="$2"
  local payload version
  payload=$(run_kubectl -n "$CORE_NAMESPACE" exec "${CORE_STATEFULSET}-0" -c vault -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$token" \
    VAULT_TOKEN="$token" \
    sh -c "vault kv get -format=json \"$path\" 2>/dev/null || true" 2>/dev/null || true)
  if [[ -z "${payload}" ]]; then
    echo 0
    return 0
  fi
  version=$(jq -r '.data.metadata.version // 0' <<<"$payload" 2>/dev/null || echo "0")
  if ! [[ "$version" =~ ^[0-9]+$ ]]; then
    version=0
  fi
  echo "${version}"
}

wait_vault_secret_version_gt() {
  local token="$1" path="$2" baseline="$3" timeout="${4:-900s}"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=900
  local end=$(( $(date +%s) + timeout_s ))
  local current=0
  while true; do
    current=$(vault_secret_version "$token" "$path")
    if (( current > baseline )); then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      log "vault secret ${path} version did not advance beyond ${baseline} within ${timeout} (current=${current})"
      return 1
    fi
    sleep 5
  done
}

wait_step_ca_seed_material_refreshed() {
  local token="$1" timeout="$2" config_before="$3" certs_before="$4" keys_before="$5" passwords_before="$6"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=300
  local end=$(( $(date +%s) + timeout_s ))
  while true; do
    local config_now certs_now keys_now passwords_now
    config_now=$(vault_secret_version "$token" "secret/step-ca/config")
    certs_now=$(vault_secret_version "$token" "secret/step-ca/certs")
    keys_now=$(vault_secret_version "$token" "secret/step-ca/keys")
    passwords_now=$(vault_secret_version "$token" "secret/step-ca/passwords")
    if (( config_now > config_before && certs_now > certs_before && keys_now > keys_before && passwords_now > passwords_before )); then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      log "Step CA seed material did not refresh within ${timeout} (versions: config=${config_now}/${config_before} certs=${certs_now}/${certs_before} keys=${keys_now}/${keys_before} passwords=${passwords_now}/${passwords_before})"
      return 1
    fi
    sleep 5
  done
}

wait_configmap_exists() {
  local ns="$1" name="$2" timeout="$3"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=600
  local end=$(( $(date +%s) + timeout_s ))
  while true; do
    if run_kubectl -n "$ns" get configmap "$name" >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      log "configmap ${ns}/${name} did not appear within ${timeout}"
      return 1
    fi
    sleep 5
  done
}

wait_secret() {
  local ns="$1" secret="$2"
  local timeout="${3:-600s}"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=600
  local end=$(( $(date +%s) + timeout_s ))
  while true; do
    if run_kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      break
    fi
    sleep 5
  done
  log "secret ${secret} in namespace ${ns} did not appear within ${timeout}"
  return 1
}

ensure_core_backup_pvc_bound() {
  local pvc="${CORE_BACKUP_PVC_NAME}"
  [[ -z "${pvc}" ]] && return 0

  if ! run_kubectl -n "${CORE_NAMESPACE}" get pvc "${pvc}" >/dev/null 2>&1; then
    return 0
  fi

  local phase
  phase=$(run_kubectl -n "${CORE_NAMESPACE}" get pvc "${pvc}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${phase}" == "Bound" ]]; then
    return 0
  fi

  local storage_class binding_mode
  storage_class=$(run_kubectl -n "${CORE_NAMESPACE}" get pvc "${pvc}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
  if [[ -n "${storage_class}" ]]; then
    binding_mode=$(run_kubectl get storageclass "${storage_class}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || true)
  else
    binding_mode=""
  fi

  if [[ "${phase}" == "Pending" && "${binding_mode}" == "WaitForFirstConsumer" ]]; then
    local manual_job="vault-raft-backup-warmup-manual-$(date -u +%s)"
    local tmp
    tmp=$(mktemp)
    log "backup PVC ${CORE_NAMESPACE}/${pvc} is Pending with WaitForFirstConsumer; running manual warmup job (${manual_job})"
    cat >"${tmp}" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${manual_job}
  namespace: ${CORE_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      containers:
      - name: warmup
        image: registry.example.internal/deploykube/bootstrap-tools:1.4
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          ls -la /backup >/dev/null
        volumeMounts:
        - name: backup
          mountPath: /backup
      volumes:
      - name: backup
        persistentVolumeClaim:
          claimName: ${pvc}
YAML
    run_kubectl apply -f "${tmp}" >/dev/null
    rm -f "${tmp}"

    if ! wait_job_complete "${CORE_NAMESPACE}" "${manual_job}" "${CORE_BACKUP_WARMUP_WAIT_TIMEOUT}"; then
      log "manual backup PVC warmup job failed; recent logs:"
      run_kubectl -n "${CORE_NAMESPACE}" logs "job/${manual_job}" || true
      return 1
    fi
    run_kubectl -n "${CORE_NAMESPACE}" delete job "${manual_job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  if ! run_kubectl -n "${CORE_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${pvc}" --timeout="${CORE_BACKUP_WARMUP_WAIT_TIMEOUT}" >/dev/null 2>&1; then
    log "backup PVC ${CORE_NAMESPACE}/${pvc} did not reach Bound within ${CORE_BACKUP_WARMUP_WAIT_TIMEOUT}"
    run_kubectl -n "${CORE_NAMESPACE}" describe pvc "${pvc}" || true
    return 1
  fi
}

wait_pod_deleted() {
  local ns="$1" sts="$2" ordinal="${3:-0}"
  local pod="${sts}-${ordinal}"
  for attempt in {1..120}; do
    if ! run_kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1; then
      return 0
    fi
    # Best-effort cleanup for stuck terminating pods (common after PV/CSI hiccups).
    # We try a force delete after ~2 minutes, and again later if needed.
    if [[ "$attempt" == "24" || "$attempt" == "60" ]]; then
      run_kubectl -n "$ns" patch pod "$pod" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      run_kubectl -n "$ns" delete pod "$pod" --grace-period=0 --force >/dev/null 2>&1 || true
    fi
    sleep 5
  done
  log "pod $pod failed to terminate cleanly"
  return 1
}

wait_statefulset_pods_deleted() {
  local ns="$1" sts="$2" replicas="$3"
  [[ -z "$replicas" || "$replicas" -lt 1 ]] && replicas=1
  for i in $(seq 0 $((replicas-1))); do
    wait_pod_deleted "$ns" "$sts" "$i" || return 1
  done
}

wait_pod_running() {
  local ns="$1" sts="$2" ordinal="${3:-0}"
  local pod="${sts}-${ordinal}"
  for _ in {1..180}; do
    local phase json status_reason=""
    json=$(run_kubectl -n "$ns" get pod "$pod" -o json 2>/dev/null || true)
    phase=$(jq -r '.status.phase // empty' <<<"$json" 2>/dev/null || true)
    if [[ "$phase" == "Running" ]]; then
      return 0
    fi
    if [[ "$phase" == "Failed" ]]; then
      log "pod $pod reported phase Failed"
      return 1
    fi
    if [[ -n "$json" ]]; then
      status_reason=$(jq -r '.status.containerStatuses[]? | select(.state.waiting != null) | .state.waiting.reason' <<<"$json" 2>/dev/null | tr '\n' ' ')
      # CrashLoopBackOff can be transient during Vault bring-up (e.g. transit seal not ready yet).
      # Treat it as "keep waiting" and only fail fast on hard image/config errors.
      if [[ "$status_reason" =~ (ErrImagePull|ImagePullBackOff|CreateContainerConfigError) ]]; then
        log "pod $pod waiting: ${status_reason}"
        return 1
      fi
    fi
    sleep 5
  done
  log "pod $pod failed to reach Running within timeout"
  return 1
}

wait_pod_exec_ready() {
  local ns="$1" pod="$2" container="${3:-vault}" timeout="${4:-900s}"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=900
  local end=$(( $(date +%s) + timeout_s ))
  while true; do
    if run_kubectl -n "$ns" exec "$pod" -c "$container" -- sh -c 'true' >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      log "pod $pod failed exec readiness check within ${timeout}"
      return 1
    fi
    local json status_reason="" phase=""
    json=$(run_kubectl -n "$ns" get pod "$pod" -o json 2>/dev/null || true)
    if [[ -n "$json" ]]; then
      phase=$(jq -r '.status.phase // empty' <<<"$json" 2>/dev/null || true)
      if [[ "$phase" == "Failed" ]]; then
        log "pod $pod reported phase Failed"
        return 1
      fi
      status_reason=$(jq -r '.status.containerStatuses[]? | select(.state.waiting != null) | .state.waiting.reason' <<<"$json" 2>/dev/null | tr '\n' ' ')
      if [[ "$status_reason" =~ (ErrImagePull|ImagePullBackOff|CreateContainerConfigError) ]]; then
        log "pod $pod waiting: ${status_reason}"
        return 1
      fi
    fi
    sleep 5
  done
}

wait_clustersecretstore_ready() {
  local name="$1" timeout="${2:-900s}"
  local timeout_s=${timeout%s}
  [[ -z "${timeout_s}" ]] && timeout_s=900
  local end=$(( $(date +%s) + timeout_s ))
  local last_message=""
  local last_forced_reconcile=0
  while true; do
    local json ready reason message
    json=$(run_kubectl get clustersecretstore "$name" -o json 2>/dev/null || true)
    if [[ -n "$json" ]]; then
      ready=$(jq -r '.status.conditions[]? | select(.type=="Ready") | .status' <<<"$json" 2>/dev/null | head -n 1 || true)
      reason=$(jq -r '.status.conditions[]? | select(.type=="Ready") | .reason // ""' <<<"$json" 2>/dev/null | head -n 1 || true)
      message=$(jq -r '.status.conditions[]? | select(.type=="Ready") | .message // ""' <<<"$json" 2>/dev/null | head -n 1 || true)
      if [[ "$ready" == "True" ]]; then
        return 0
      fi
      if [[ -n "$message" && "$message" != "$last_message" ]]; then
        log "ClusterSecretStore ${name} not ready (${reason:-unknown}): ${message}"
        last_message="$message"
      fi
      # External Secrets can hold InvalidProviderConfig until a reconcile tick after Vault auth roles
      # are corrected. Force a reconcile periodically to make bootstrap deterministic.
      if [[ "${reason}" == "InvalidProviderConfig" ]]; then
        local now
        now=$(date +%s)
        if (( now - last_forced_reconcile >= 30 )); then
          run_kubectl annotate clustersecretstore "$name" "deploykube.io/force-reconcile=${now}" --overwrite >/dev/null 2>&1 || true
          last_forced_reconcile=$now
        fi
      fi
    fi
    if (( $(date +%s) >= end )); then
      log "ClusterSecretStore ${name} did not become Ready within ${timeout}"
      return 1
    fi
    sleep 5
  done
}

run_manual_vault_configure_job() {
  local manual_job="vault-configure-manual-$(date -u +%s)"
  local config_app
  config_app="$(resolve_core_config_app)"
  local tmp
  tmp=$(mktemp)
  log "vault-configure hook missing/incomplete; running manual configure job (${manual_job})"
  cat >"${tmp}" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${manual_job}
  namespace: ${CORE_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
        sidecar.istio.io/nativeSidecar: 'true'
    spec:
      serviceAccountName: vault-bootstrap
      restartPolicy: Never
      containers:
      - name: configure
        image: registry.example.internal/deploykube/bootstrap-tools:1.4
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - /scripts/configure.sh
        volumeMounts:
        - name: script
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: script
        configMap:
          name: vault-configure-script
          defaultMode: 0755
YAML
  run_kubectl apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"
  if ! wait_job_complete "$CORE_NAMESPACE" "${manual_job}" "900s"; then
    log "manual vault-configure job failed; recent logs:"
    run_kubectl -n "$CORE_NAMESPACE" logs "job/${manual_job}" || true
    exit 1
  fi
  run_kubectl -n "$CORE_NAMESPACE" delete job "${manual_job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  clear_stuck_hook_operation "${config_app}" vault-configure || true
}

vault_kubernetes_auth_ready() {
  local root_token pod
  root_token=$(get_vault_root_token || true)
  [[ -z "${root_token}" ]] && return 1
  pod="${CORE_STATEFULSET}-0"
  run_kubectl -n "$CORE_NAMESPACE" exec "$pod" -c vault -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="${root_token}" \
    VAULT_TOKEN="${root_token}" \
    sh -c '
      set -eu
      vault read auth/kubernetes/config >/dev/null
      vault read auth/kubernetes/role/external-secrets >/dev/null
    ' >/dev/null 2>&1
}

vault_status_json() {
  local ns="$1" target="$2"
  run_kubectl -n "$ns" exec "$target" -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null || true
}

vault_initialized() {
  local ns="$1" target="$2"
  local status initialized
  status=$(vault_status_json "$ns" "$target")
  initialized=$(jq -r '.initialized // false' <<<"$status" 2>/dev/null || echo "false")
  [[ "$initialized" == "true" ]]
}

get_k8s_secret_field() {
  local ns="$1" secret="$2" field="$3"
  local raw=""
  raw=$(run_kubectl -n "$ns" get secret "$secret" -o "jsonpath={.data.${field}}" 2>/dev/null || true)
  if [[ -z "$raw" ]]; then
    return 1
  fi
  printf '%s' "$raw" | b64decode 2>/dev/null
}

ensure_kms_shim_secret_material() {
  if [[ "${ROOT_OF_TRUST_MODE}" == "external" ]]; then
    if [[ -f "${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH}" ]]; then
      return 0
    fi

    local token
    token=$(get_k8s_secret_field "${CORE_NAMESPACE}" "${KMS_SHIM_TOKEN_SECRET_NAME}" "token" || true)
    if [[ -z "${token}" ]]; then
      token=$(generate_autounseal_token)
    fi
    write_kms_shim_token_secrets "${token}"
    return 0
  fi

  if [[ -f "${KMS_SHIM_KEY_SECRET_PATH}" && -f "${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH}" && -f "${KMS_SHIM_TOKEN_SECRET_SHIM_PATH}" ]]; then
    return 0
  fi

  local token age_key
  token=$(get_k8s_secret_field "${CORE_NAMESPACE}" "${KMS_SHIM_TOKEN_SECRET_NAME}" "token" || true)
  [[ -z "${token}" ]] && token=$(get_k8s_secret_field "${KMS_SHIM_NAMESPACE}" "${KMS_SHIM_TOKEN_SECRET_NAME}" "token" || true)
  age_key=$(get_kms_shim_age_key_from_cluster || true)

  if [[ -z "${token}" ]]; then
    token=$(generate_autounseal_token)
  fi
  if [[ -z "${age_key}" ]]; then
    age_key="$(age-keygen)"
  fi

  if [[ ! -f "${KMS_SHIM_KEY_SECRET_PATH}" ]]; then
    write_kms_shim_key_secret "${age_key}"
  fi
  if [[ ! -f "${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH}" || ! -f "${KMS_SHIM_TOKEN_SECRET_SHIM_PATH}" ]]; then
    write_kms_shim_token_secrets "${token}"
  fi
}

ensure_core_secret_material() {
  if [[ -f "${CORE_SECRET_PATH}" ]]; then
    return 0
  fi

  local root_token recovery_key
  root_token=$(get_k8s_secret_field "$CORE_NAMESPACE" "$CORE_SECRET_NAME" "root-token" || true)
  recovery_key=$(get_k8s_secret_field "$CORE_NAMESPACE" "$CORE_SECRET_NAME" "recovery-key" || true)

  if [[ -z "$root_token" || -z "$recovery_key" ]]; then
    log "core vault is initialized but required init material is missing from repo and cluster (Secret ${CORE_NAMESPACE}/${CORE_SECRET_NAME})"
    log "if this is a new cluster, rerun after secrets-bootstrap is healthy; otherwise wipe/reinit core explicitly"
    exit 1
  fi

  local tmp
  tmp=$(mktemp)
  cat > "${tmp}" <<EOT
apiVersion: v1
kind: Secret
metadata:
  name: vault-init
  namespace: ${CORE_NAMESPACE}
stringData:
  root-token: ${root_token}
  recovery-key: ${recovery_key}
  bootstrap-notes: Reconstructed $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOT
  write_secret "${tmp}" "${CORE_SECRET_PATH}"
  rm -f "${tmp}"
}

wait_unsealed() {
  local ns="$1" sts="$2"
  for _ in {1..120}; do
    local status
    status=$(vault_status_json "$ns" statefulset/"$sts")
    if [[ -n "$status" ]] && [[ $(jq -r '.sealed' <<<"$status" 2>/dev/null) == "false" ]]; then
      return 0
    fi
    sleep 5
  done
  log "$sts remains sealed"
  exit 1
}

wait_initialized() {
  local ns="$1" target="$2"
  for _ in {1..60}; do
    local status initialized
    status=$(vault_status_json "$ns" "$target")
    initialized=$(jq -r '.initialized' <<<"$status" 2>/dev/null || echo "false")
    if [[ "$initialized" == "true" ]]; then
      return 0
    fi
    sleep 5
  done
  log "vault instance $target failed to initialize"
  exit 1
}

ensure_app_exists() {
  local app="$1"
  for _ in {1..120}; do
    if run_kubectl -n argocd get application "$app" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  log "application $app not found in argocd namespace"
  exit 1
}

argocd_app_exists() {
  local app="$1"
  run_kubectl -n argocd get application "$app" >/dev/null 2>&1
}

ensure_core_bootstrap_app_materialized() {
  if argocd_app_exists "secrets-vault-bootstrap"; then
    return
  fi
  log "waiting for root app ${ROOT_APP} to materialize secrets-vault-bootstrap"
  sync_app "${ROOT_APP}"
  ensure_app_exists "secrets-vault-bootstrap"
}

resolve_core_bootstrap_app() {
  if argocd_app_exists "secrets-vault-bootstrap"; then
    printf '%s\n' "secrets-vault-bootstrap"
    return
  fi
  log "application secrets-vault-bootstrap not found; falling back to ${CORE_APP}"
  printf '%s\n' "${CORE_APP}"
}

resolve_core_config_app() {
  if argocd_app_exists "secrets-vault-config"; then
    printf '%s\n' "secrets-vault-config"
    return
  fi
  log "application secrets-vault-config not found; falling back to ${CORE_APP}"
  printf '%s\n' "${CORE_APP}"
}

apply_vault_config_overlay_direct() {
  local config_overlay="${GITOPS_DIR}/components/secrets/vault/overlays/${DEPLOYKUBE_DEPLOYMENT_ID}/config"
  if [[ ! -d "${config_overlay}" ]]; then
    log "vault config overlay missing: ${config_overlay}"
    exit 1
  fi
  log "secrets-vault-config Application not found; applying vault config overlay directly (${DEPLOYKUBE_DEPLOYMENT_ID})"
  if run_kubectl get crd destinationrules.networking.istio.io >/dev/null 2>&1; then
    run_kubectl apply -k "${config_overlay}" >/dev/null
    return
  fi

  log "DestinationRule CRD not present yet; applying vault config overlay without networking.istio.io resources"
  local tmp
  tmp=$(mktemp)
  run_kubectl kustomize "${config_overlay}" |
    yq eval 'select((.apiVersion // "") | contains("networking.istio.io/") | not)' - >"${tmp}"
  run_kubectl apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"
}

sync_app() {
  local app="$1"
  ensure_app_exists "$app"
  # Force Argo to refresh its cached Git state. This matters after a forced Forgejo
  # reseed, where Argo can keep using an older cached tree.
  run_kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  run_kubectl -n argocd patch application "$app" --type merge \
    -p '{"operation":{"sync":{"revision":"main","prune":true}}}' >/dev/null
}

pause_self_heal() {
  local app="$1"
  if ! argocd_app_exists "${app}"; then
    return 0
  fi
  run_kubectl -n argocd patch application "${app}" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
}

resume_self_heal() {
  local app="$1"
  if ! argocd_app_exists "${app}"; then
    return 0
  fi
  run_kubectl -n argocd patch application "${app}" --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
}

pause_root_app() {
  if [[ "${ROOT_APP_PAUSED}" == "true" ]]; then
    return
  fi
  if [[ -n "${ROOT_APP}" ]]; then
    log "pausing root Argo Application ${ROOT_APP}"
    pause_self_heal "${ROOT_APP}"
    ROOT_APP_PAUSED=true
  fi
}

should_pause_root_app() {
  # Pausing the root app is important when wiping/reinitializing (to avoid Argo racing our
  # destructive actions). During a *fresh* bootstrap, pausing too early can deadlock the
  # cluster (Argo can't run nodeprep/hooks needed for Vault pods to schedule).
  if [[ "${VAULT_INIT_PAUSE_ROOT_APP:-false}" == "true" ]]; then
    return 0
  fi
  if [[ "${WIPE_CORE}" == "true" || "${REINIT_CORE}" == "true" ]]; then
    return 0
  fi
  return 1
}

ensure_argocd_controller_running() {
  if ! run_kubectl get namespace "${ARGO_NAMESPACE}" >/dev/null 2>&1; then
    return
  fi
  local kind="" jsonpath="" waitpath=""
  if run_kubectl -n "${ARGO_NAMESPACE}" get statefulset argo-cd-argocd-application-controller >/dev/null 2>&1; then
    kind="statefulset"
    jsonpath='{.spec.replicas}'
    waitpath='{.status.readyReplicas}'
  elif run_kubectl -n "${ARGO_NAMESPACE}" get deployment argo-cd-argocd-application-controller >/dev/null 2>&1; then
    kind="deployment"
    jsonpath='{.spec.replicas}'
    waitpath='{.status.availableReplicas}'
  else
    return
  fi
  local replicas
  replicas=$(run_kubectl -n "${ARGO_NAMESPACE}" get "${kind}" argo-cd-argocd-application-controller -o jsonpath="${jsonpath}" 2>/dev/null || echo "1")
  ARGO_CONTROLLER_KIND="${kind}"
  ARGO_CONTROLLER_PREVIOUS_REPLICAS="${replicas}"
  if [[ "${replicas}" -ge 1 ]]; then
    return
  fi
  log "scaling Argo CD ${kind} argo-cd-argocd-application-controller to 1 replica for manual syncs"
  run_kubectl -n "${ARGO_NAMESPACE}" scale "${kind}" argo-cd-argocd-application-controller --replicas=1 >/dev/null 2>&1 || return
  run_kubectl -n "${ARGO_NAMESPACE}" wait --for=jsonpath="${waitpath}"=1 "${kind}/argo-cd-argocd-application-controller" --timeout=120s >/dev/null 2>&1 || true
  ARGO_CONTROLLER_RESTORED=true
}

restore_argocd_controller() {
  if [[ "${ARGO_CONTROLLER_RESTORED}" != "true" ]]; then
    return
  fi
  if [[ -z "${ARGO_CONTROLLER_KIND}" ]] || [[ -z "${ARGO_CONTROLLER_PREVIOUS_REPLICAS}" ]]; then
    return
  fi
  log "restoring Argo CD ${ARGO_CONTROLLER_KIND} argo-cd-argocd-application-controller to ${ARGO_CONTROLLER_PREVIOUS_REPLICAS} replicas"
  run_kubectl -n "${ARGO_NAMESPACE}" scale "${ARGO_CONTROLLER_KIND}" argo-cd-argocd-application-controller --replicas="${ARGO_CONTROLLER_PREVIOUS_REPLICAS}" >/dev/null 2>&1 || true
}

resume_root_app() {
  if [[ "${ROOT_APP_PAUSED}" != "true" ]]; then
    return
  fi
  if [[ -n "${ROOT_APP}" ]]; then
    log "resuming root Argo Application ${ROOT_APP}"
    resume_self_heal "${ROOT_APP}"
  fi
  ROOT_APP_PAUSED=false
}

cleanup() {
  resume_root_app
  restore_argocd_controller
}

ensure_bootstrap_status_configmap() {
  run_kubectl -n "$ARGO_NAMESPACE" create configmap "$BOOTSTRAP_STATUS_CONFIGMAP" \
    --dry-run=client -o yaml | run_kubectl apply -f - >/dev/null
}

compute_secret_sha() {
  local ns="$1" secret="$2"
  run_kubectl -n "$ns" get secret "$secret" -o json |
    jq -r '.data | to_entries[] | "\(.key)=\(.value)"' |
    LC_ALL=C sort |
    sha256sum |
    awk '{print $1}'
}

annotate_secret_with_sha() {
  local ns="$1" secret="$2" sha="$3"
  local patch
  patch=$(cat <<JSON
{"metadata":{"annotations":{"deploykube.gitops/secret-sha":"${sha}"}}}
JSON
  )
  run_kubectl -n "$ns" patch secret "$secret" --type merge -p "$patch" >/dev/null
}

record_bootstrap_status() {
  local scope="$1" secret_ns="$2" secret_name="$3" pvc_ns="$4" pvc_name="$5"
  ensure_bootstrap_status_configmap
  local secret_sha
  secret_sha=$(compute_secret_sha "$secret_ns" "$secret_name") || {
    log "unable to compute ${scope} secret checksum"
    return
  }
  annotate_secret_with_sha "$secret_ns" "$secret_name" "$secret_sha"
  local pvc_uid=""
  if [[ -n "$pvc_name" ]]; then
    pvc_uid=$(run_kubectl -n "$pvc_ns" get pvc "$pvc_name" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  fi
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local patch
  patch=$(cat <<JSON
{"data":{
"${scope}-secret-sha":"${secret_sha}",
"${scope}-pvc-uid":"${pvc_uid}",
"${scope}-initialized-at":"${timestamp}"
}}
JSON
  )
  run_kubectl -n "$ARGO_NAMESPACE" patch configmap "$BOOTSTRAP_STATUS_CONFIGMAP" --type merge -p "$patch" >/dev/null
}

guard_preserve_mode() {
  if [[ "${BOOTSTRAP_SKIP_VAULT_INIT:-false}" == "true" ]]; then
    log "BOOTSTRAP_SKIP_VAULT_INIT=true detected; skipping init-vault-secrets.sh"
    exit 0
  fi
}

validate_skip_matrix() {
  local scope="$1" skip="$2" wipe="$3" reinit="$4"
  # `--skip-<scope>` is intended to skip *initialization*, but it can be useful to
  # still *wipe* legacy state (e.g. moving from transit -> kmsShim and wanting to
  # delete the old transit Vault data).
  if [[ "$skip" == "true" ]] && [[ "$reinit" == "true" ]]; then
    log "--skip-${scope} cannot be combined with --reinit-${scope}"
    exit 1
  fi
  if [[ "$skip" == "true" ]] && [[ "$wipe" == "true" ]]; then
    if [[ "${scope}" == "transit" ]]; then
      # Allowed: wipe transit remnants but skip transit init.
      return 0
    fi
    log "--skip-${scope} cannot be combined with --wipe-${scope}-data"
    exit 1
  fi
}

autodetect_storage_profile() {
  if [[ -n "${DEPLOYKUBE_STORAGE_PROFILE}" ]]; then
    return 0
  fi

  # Best-effort: infer from the `shared-rwo` StorageClass provisioner.
  # - Standard profiles: NFS-backed (`nfs-subdir-external-provisioner`).
  # - Single-node profile: local-path (`darksite.cloud/local-path`).
  local provisioner=""
  provisioner=$(run_kubectl get storageclass shared-rwo -o jsonpath='{.provisioner}' 2>/dev/null || true)
  case "${provisioner}" in
    darksite.cloud/local-path|rancher.io/local-path)
      DEPLOYKUBE_STORAGE_PROFILE="local-path"
      ;;
    *nfs-subdir-external-provisioner*)
      DEPLOYKUBE_STORAGE_PROFILE="shared-nfs"
      ;;
    *)
      # Unknown or not yet present; leave unset and keep defaults.
      DEPLOYKUBE_STORAGE_PROFILE=""
      ;;
  esac
}

configure_nfs_scrub_backend() {
  autodetect_storage_profile
  if [[ "${DEPLOYKUBE_STORAGE_PROFILE}" == "local-path" ]]; then
    # In the single-node local-path profile, Vault PVCs are node-local hostPath volumes inside the kind node.
    # There is no OrbStack NFS export to scrub, and requiring the Docker volume breaks clean bootstraps.
    NFS_VOLUME=""
    NFS_VOLUME_READY=true
    LOCAL_PATH_SCRUB_ENABLED=true
    log "detected local-path shared-rwo; skipping OrbStack NFS volume scrub checks"
  fi
}

ensure_nfs_volume_ready() {
  if [[ -z "$NFS_VOLUME" || "$NFS_VOLUME_READY" == "true" ]]; then
    return
  fi
  require docker
  if [[ "$NFS_VOLUME" == */* ]]; then
    if [[ ! -d "$NFS_VOLUME" ]]; then
      log "NFS path ${NFS_VOLUME} not found; ensure the OrbStack export exists before wiping data"
      exit 1
    fi
  else
    if ! docker volume inspect "$NFS_VOLUME" >/dev/null 2>&1; then
      log "Docker volume ${NFS_VOLUME} missing; start orb-nfs-host.sh before running with --wipe-*"
      exit 1
    fi
  fi
  NFS_VOLUME_READY=true
}

remove_pvc() {
  local ns="$1" pvc="$2"
  run_kubectl -n "$ns" patch pvc "$pvc" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  run_kubectl -n "$ns" delete pvc "$pvc" --ignore-not-found >/dev/null 2>&1 || true
}

delete_pods_using_pvc() {
  local ns="$1" pvc="$2"
  local pods
  pods=$(
    run_kubectl -n "${ns}" get pods -o json 2>/dev/null \
      | jq -r --arg pvc "${pvc}" '
        .items[]
        | select(.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $pvc))
        | .metadata.name
      ' \
      | sort -u
  ) || true

  if [[ -z "${pods}" ]]; then
    return 0
  fi

  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    # Completed hook pods (e.g. *-backup-warmup) can keep pvc-protection finalizers stuck on backup PVCs.
    # Delete them to allow the PVC to be removed cleanly before re-syncing.
    run_kubectl -n "${ns}" patch pod "${pod}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    run_kubectl -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done <<<"${pods}"
}

scrub_nfs() {
  local dirs=("$@")
  if [[ ${#dirs[@]} -eq 0 ]]; then
    log "no NFS directories specified for scrub; skipping"
    return
  fi

  # Prefer an in-cluster scrub for standard NFS-backed profiles (e.g. Proxmox/Talos).
  # The previous host-based scrub (Docker volume / OrbStack NFS) is dev-only and breaks clean bootstraps
  # when run against remote NFS exports.
  autodetect_storage_profile
  if [[ "${DEPLOYKUBE_STORAGE_PROFILE}" == "shared-nfs" ]]; then
    if scrub_shared_nfs_via_provisioner "${dirs[@]}"; then
      return 0
    fi
    if [[ "${KUBE_CONTEXT}" != kind-* ]]; then
      log "unable to scrub shared-nfs export via in-cluster provisioner; aborting wipe (required for non-kind clusters)"
      exit 1
    fi
    log "shared-nfs scrub via in-cluster provisioner failed; falling back to host-based scrub (dev only)"
  fi

  [[ -z "$NFS_VOLUME" ]] && return
  ensure_nfs_volume_ready
  docker run --rm -v "$NFS_VOLUME:/data" alpine sh -c '
	set -e
	for target in "$@"; do
	  clean="${target#/}"
	  case "$clean" in
	    ""|"."|".."|*"../"*|*"/.."*)
	      echo "refusing to scrub suspicious path: $target" >&2
	      exit 1
	      ;;
	  esac
	  case "$clean" in
	    *"*"*|*"?"*|*"["*)
	      rm -rf /data/$clean
	      ;;
	    *)
	      rm -rf "/data/$clean"
	      mkdir -p "/data/$clean"
	      chown -R 100:100 "/data/$clean"
	      ;;
	  esac
	done
	' -- "${dirs[@]}" >/dev/null
}

scrub_shared_nfs_via_provisioner() {
  local dirs=("$@")
  local ns="${NFS_PROVISIONER_NAMESPACE:-storage-system}"
  local deploy="${NFS_PROVISIONER_DEPLOYMENT:-nfs-provisioner-nfs-subdir-external-provisioner}"

  local json
  json=$(run_kubectl -n "${ns}" get deploy "${deploy}" -o json 2>/dev/null || true)
  if [[ -z "${json}" ]]; then
    log "shared-nfs scrub: Deployment ${ns}/${deploy} not found"
    return 1
  fi

  if ! run_kubectl -n "${ns}" rollout status "deploy/${deploy}" --timeout=600s >/dev/null 2>&1; then
    log "shared-nfs scrub: Deployment ${ns}/${deploy} not Ready"
    return 1
  fi

  local nfs_server nfs_path
  nfs_server="$(jq -r '.spec.template.spec.containers[]?.env[]? | select(.name=="NFS_SERVER") | .value' <<<"${json}" 2>/dev/null | head -n1 || true)"
  nfs_path="$(jq -r '.spec.template.spec.containers[]?.env[]? | select(.name=="NFS_PATH") | .value' <<<"${json}" 2>/dev/null | head -n1 || true)"
  if [[ -z "${nfs_server}" || "${nfs_server}" == "null" || -z "${nfs_path}" || "${nfs_path}" == "null" ]]; then
    log "shared-nfs scrub: could not determine NFS_SERVER/NFS_PATH from ${ns}/${deploy}"
    return 1
  fi

  local pod="deploykube-nfs-scrub-$(date +%s)-${RANDOM}"
  local mount="/nfs"

  log "scrubbing shared-nfs export via in-cluster scrub pod (${ns}/${pod}): ${nfs_server}:${nfs_path}"

  local tmp
  tmp=$(mktemp)
  cat >"${tmp}" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
  - name: scrub
    image: alpine:3.22.2
    command: ["/bin/sh","-c"]
    args:
    - |
      set -euo pipefail
      base="${mount}"
      for rel in "\$@"; do
        clean="\${rel#/}"
        case "\$clean" in
          ""|"."|".."|*"../"*|*"/.."*)
            echo "refusing to scrub suspicious path: \$rel" >&2
            exit 1
            ;;
        esac
        case "\$clean" in
          *"*"*|*"?"*|*"["*)
            rm -rf "\$base"/\$clean
            ;;
          *)
            rm -rf "\$base/\$clean"
            mkdir -p "\$base/\$clean"
            chown -R 100:100 "\$base/\$clean" || true
            ;;
        esac
      done
    - scrub
YAML

  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    printf "    - '%s'\n" "${rel}" >>"${tmp}"
  done <<<"$(printf '%s\n' "${dirs[@]}")"

  cat >>"${tmp}" <<YAML
    volumeMounts:
    - name: nfs
      mountPath: ${mount}
  volumes:
  - name: nfs
    nfs:
      server: ${nfs_server}
      path: ${nfs_path}
YAML

  run_kubectl -n "${ns}" apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"

  if ! run_kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s pod/"${pod}" >/dev/null 2>&1; then
    log "shared-nfs scrub pod ${pod} did not complete; recent logs:"
    run_kubectl -n "${ns}" logs pod/"${pod}" --tail=200 || true
    run_kubectl -n "${ns}" describe pod/"${pod}" || true
    run_kubectl -n "${ns}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi

  run_kubectl -n "${ns}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
  return 0
}

scrub_local_path_for_namespace() {
  local target_ns="$1"
  if [[ "${LOCAL_PATH_SCRUB_ENABLED}" != "true" ]]; then
    return 0
  fi
  if [[ -z "${target_ns}" ]]; then
    log "local-path scrub called without namespace"
    exit 1
  fi

  local ns="storage-system"
  if ! run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
    ns="default"
  fi

  local entries
  entries=$(
    run_kubectl get pv -o json 2>/dev/null \
      | jq -r --arg target_ns "${target_ns}" '
        .items[]
        | select(.metadata.annotations["pv.kubernetes.io/provisioned-by"] == "darksite.cloud/local-path")
        | select(.spec.claimRef.namespace == $target_ns)
        | select((.spec.hostPath.path // "") | startswith("/var/mnt/deploykube/local-path/"))
        | "\(.metadata.annotations["local.path.provisioner/selected-node"] // "")|\(.spec.hostPath.path)"
      ' \
      | sort -u
  ) || true

  if [[ -z "${entries}" ]]; then
    log "no local-path PV directories found for namespace ${target_ns}; skipping scrub"
    return 0
  fi

  log "scrubbing local-path PV directories for namespace ${target_ns}"

  local line node path rel
  declare -A node_paths=()
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    node="${line%%|*}"
    path="${line#*|}"
    rel="${path#${LOCAL_PATH_BASE}/}"
    if [[ "${rel}" == "${path}" ]]; then
      log "WARN: local-path PV path outside ${LOCAL_PATH_BASE}: ${path} (skipping)"
      continue
    fi
    node_paths["${node}"]+="${rel}"$'\n'
  done <<<"${entries}"

  local node_key
  for node_key in "${!node_paths[@]}"; do
    local pod suffix tmp
    suffix=$(printf '%s' "${target_ns}-${node_key}" | shasum -a 256 | awk '{print substr($1,1,8)}')
    pod="local-path-scrub-${suffix}"

    run_kubectl -n "${ns}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true

    tmp="$(mktemp "/tmp/deploykube-local-path-scrub.${suffix}.XXXXXX.yaml")"
    cat >"${tmp}" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    app.kubernetes.io/name: local-path-scrub
spec:
  restartPolicy: Never
  nodeName: ${node_key}
  containers:
  - name: scrub
    image: alpine:3.20
    command: ["/bin/sh","-c"]
    args:
    - |
      set -euo pipefail
      base="/host/local-path"
      for rel in "\$@"; do
        rm -rf "\$base/\$rel"
      done
    - scrub
YAML

    while IFS= read -r rel; do
      [[ -z "${rel}" ]] && continue
      printf "    - '%s'\n" "${rel}" >>"${tmp}"
    done <<<"${node_paths[${node_key}]}"

    cat >>"${tmp}" <<YAML
    volumeMounts:
    - name: local-path
      mountPath: /host/local-path
  volumes:
  - name: local-path
    hostPath:
      path: ${LOCAL_PATH_BASE}
      type: DirectoryOrCreate
YAML

    run_kubectl -n "${ns}" apply -f "${tmp}" >/dev/null
    rm -f "${tmp}"

    if ! run_kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s pod/"${pod}" >/dev/null 2>&1; then
      log "local-path scrub pod ${pod} did not complete; recent logs:"
      run_kubectl -n "${ns}" logs pod/"${pod}" --tail=200 || true
      run_kubectl -n "${ns}" describe pod/"${pod}" || true
      exit 1
    fi
    run_kubectl -n "${ns}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
  done
}

wipe_cluster() {
  local label="$1" ns="$2" sts="$3" app="$4" extra_pvcs=(${5}) ; shift 5 || true
  local nfs_dirs=("$@")
  log "wiping $label"
  local app_present=true
  if [[ -z "${app}" ]]; then
    app_present=false
  elif ! argocd_app_exists "${app}"; then
    app_present=false
    log "Argo Application ${app} not found; proceeding with best-effort wipe (no sync/recovery checks)"
  fi
  pause_self_heal "$app"
  local resume_requested=true
  cleanup_resume() {
    if [[ "${resume_requested}" == "true" ]]; then
      resume_self_heal "$app"
    fi
  }
  trap cleanup_resume RETURN
  local replicas
  replicas=$(run_kubectl -n "$ns" get statefulset "$sts" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [[ "${app_present}" == "true" ]]; then
    for _ in {1..60}; do
      if run_kubectl -n "$ns" get statefulset "$sts" >/dev/null 2>&1; then
        break
      fi
      sleep 5
    done
  fi
  run_kubectl -n "$ns" delete statefulset "$sts" --ignore-not-found >/dev/null 2>&1 || true
  # Explicitly delete pods as well; StatefulSet deletion should do this, but it can hang
  # when controllers disappear mid-flight or nodes/PVs misbehave.
  for i in $(seq 0 $((replicas-1))); do
    run_kubectl -n "$ns" delete pod "${sts}-${i}" --ignore-not-found >/dev/null 2>&1 || true
  done
  if ! wait_statefulset_pods_deleted "$ns" "$sts" "$replicas"; then
    log "pods for $label failed to terminate cleanly"
    trap - RETURN
    resume_self_heal "$app"
    return 1
  fi
  # Pods from Jobs (especially Argo hooks like *-backup-warmup) can hold pvc-protection finalizers
  # on backup PVCs and make wipes appear stuck. Delete those pods before deleting PVCs.
  local pvc
  for pvc in "${extra_pvcs[@]}"; do
    [[ -n "${pvc}" ]] && delete_pods_using_pvc "${ns}" "${pvc}"
  done
  local pvcs
  pvcs=$(run_kubectl -n "$ns" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [[ -n "$pvcs" ]]; then
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      remove_pvc "$ns" "$pvc"
    done <<<"$pvcs"
  fi
  for pvc in "${extra_pvcs[@]}"; do
    [[ -n "$pvc" ]] && remove_pvc "$ns" "$pvc"
  done
  scrub_local_path_for_namespace "${ns}"
  scrub_nfs "${nfs_dirs[@]}"
  trap - RETURN
  resume_self_heal "$app"
  resume_requested=false
  if [[ "${app_present}" != "true" ]]; then
    return 0
  fi

  log "triggering Argo sync for ${app} after $label wipe"
  sync_app "$app"
  if ! wait_statefulset "$ns" "$sts"; then
    log "statefulset ${ns}/${sts} did not recover after ${label} wipe; Argo debug for ${app}:"
    run_kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}' 2>/dev/null || true
    run_kubectl -n argocd get application "$app" -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null || true
    run_kubectl -n argocd describe application "$app" || true
    run_kubectl -n "$ns" get all || true
    return 1
  fi
}

run_with_retries() {
  local ns="$1" target="$2" cmd="$3"
  for _ in {1..30}; do
    if output=$(run_kubectl -n "$ns" exec "$target" -c vault -- sh -c "$cmd" 2>/dev/null); then
      printf '%s' "$output"
      return 0
    fi
    sleep 5
  done
  return 1
}

generate_autounseal_token() {
  local rand
  rand=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 26)
  printf '%s%s' "${AUTOUNSEAL_TOKEN_PREFIX}" "$rand"
}

validate_autounseal_token() {
  local token="$1"
  if [[ -z "$token" ]]; then
    log "auto-unseal token is empty"
    exit 1
  fi
  case "$token" in
    hvs.*)
      log "auto-unseal token uses forbidden prefix 'hvs.'; regenerate secrets with $(basename "$0")"
      exit 1
      ;;
  esac
}

get_kms_shim_age_key_from_cluster() {
  local raw=""
  raw=$(run_kubectl -n "${KMS_SHIM_NAMESPACE}" get secret "${KMS_SHIM_KEY_SECRET_NAME}" -o "jsonpath={.data.age\\.key}" 2>/dev/null || true)
  if [[ -z "${raw}" ]]; then
    return 1
  fi
  printf '%s' "${raw}" | b64decode 2>/dev/null
}

write_kms_shim_token_secrets() {
  local token="$1"
  validate_autounseal_token "${token}"

  local addr_yaml=""
  if [[ "${ROOT_OF_TRUST_MODE}" == "external" ]]; then
    if [[ -z "${ROOT_OF_TRUST_EXTERNAL_ADDR}" ]]; then
      log "kmsShim external mode selected but external.address is empty in ${DEPLOYMENT_CONFIG_YAML}"
      exit 1
    fi
    addr_yaml="$(cat <<EOF
  address: ${ROOT_OF_TRUST_EXTERNAL_ADDR}
EOF
)"
  fi

  cat > /tmp/kms-shim-token-system.yaml <<EOT
apiVersion: v1
kind: Secret
metadata:
  name: ${KMS_SHIM_TOKEN_SECRET_NAME}
  namespace: ${CORE_NAMESPACE}
  labels:
    deploykube.gitops/component: vault-core
    deploykube.gitops/managed-by: gitops
stringData:
  token: ${token}
${addr_yaml}type: Opaque
EOT
  write_secret /tmp/kms-shim-token-system.yaml "${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH}"

  if [[ "${ROOT_OF_TRUST_MODE}" == "inCluster" ]]; then
    cat > /tmp/kms-shim-token-shim.yaml <<EOT
apiVersion: v1
kind: Secret
metadata:
  name: ${KMS_SHIM_TOKEN_SECRET_NAME}
  namespace: ${KMS_SHIM_NAMESPACE}
  labels:
    deploykube.gitops/component: kms-shim
    deploykube.gitops/managed-by: gitops
stringData:
  token: ${token}
type: Opaque
EOT
    write_secret /tmp/kms-shim-token-shim.yaml "${KMS_SHIM_TOKEN_SECRET_SHIM_PATH}"
    rm -f /tmp/kms-shim-token-shim.yaml
  fi

  rm -f /tmp/kms-shim-token-system.yaml
}

write_kms_shim_key_secret() {
  local age_key="$1"
  local indented
  indented="$(printf '%s\n' "${age_key}" | sed 's/^/    /')"
  cat > /tmp/kms-shim-key.yaml <<EOT
apiVersion: v1
kind: Secret
metadata:
  name: ${KMS_SHIM_KEY_SECRET_NAME}
  namespace: ${KMS_SHIM_NAMESPACE}
  labels:
    deploykube.gitops/component: kms-shim
    deploykube.gitops/managed-by: gitops
stringData:
  age.key: |
${indented}
  bootstrap-notes: Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
type: Opaque
EOT
  write_secret /tmp/kms-shim-key.yaml "${KMS_SHIM_KEY_SECRET_PATH}"
  rm -f /tmp/kms-shim-key.yaml
}

start_forgejo_port_forward() {
  if [[ -n "${FORGEJO_PF_PID:-}" ]]; then
    return
  fi
  kubectl --context "${KUBE_CONTEXT}" -n "${FORGEJO_NAMESPACE}" port-forward \
    svc/"${FORGEJO_RELEASE}"-http "${FORGEJO_PORT_FORWARD_PORT}:3000" \
    >/tmp/forgejo-port-forward.log 2>&1 &
  FORGEJO_PF_PID=$!
  sleep 3
}

stop_forgejo_port_forward() {
  if [[ -n "${FORGEJO_PF_PID:-}" ]]; then
    kill "${FORGEJO_PF_PID}" >/dev/null 2>&1 || true
    wait "${FORGEJO_PF_PID}" 2>/dev/null || true
    FORGEJO_PF_PID=""
  fi
}

get_forgejo_password_from_secret() {
  local raw
  if ! raw=$(run_kubectl -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null); then
    return 1
  fi
  printf '%s' "$raw" | b64decode 2>/dev/null
}

resolve_forgejo_password() {
  local password=""
  if password=$(get_forgejo_password_from_secret 2>/dev/null); then
    mkdir -p "$(dirname "${FORGEJO_PASSWORD_FILE}")"
    printf '%s' "$password" > "${FORGEJO_PASSWORD_FILE}"
    printf '%s' "$password"
    return
  fi
  if [[ -f "${FORGEJO_PASSWORD_FILE}" ]]; then
    password=$(cat "${FORGEJO_PASSWORD_FILE}")
    if [[ -n "${password}" ]]; then
      printf '%s' "${password}"
      return
    fi
  fi
  log "Forgejo admin password unavailable; ensure ${FORGEJO_RELEASE}-admin Secret exists or update ${FORGEJO_PASSWORD_FILE}"
  exit 1
}

push_gitops_repo() {
  if [[ "${GITOPS_PUSH}" != "true" ]]; then
    log "GITOPS_PUSH=false; skipping Forgejo push"
    return 0
  fi
  # The Forgejo mirror is a snapshot of platform/gitops (not a shared, merge-based repo).
  # Stage 1 seeds it using shared/scripts/forgejo-seed-repo.sh which creates a fresh commit.
  # Using a normal `git push` here can fail with non-fast-forward after a wipe/reseed.
  local helper="${REPO_ROOT}/shared/scripts/forgejo-seed-repo.sh"
  if [[ ! -x "${helper}" ]]; then
    log "Forgejo seed helper missing: ${helper}"
    exit 1
  fi
  local seed_log
  seed_log=$(mktemp)
  if ! "${helper}" \
    --force \
    --context "${KUBE_CONTEXT}" \
    --gitops-path "${GITOPS_DIR}" \
    --port "${FORGEJO_PORT_FORWARD_PORT}" >"${seed_log}" 2>&1; then
    log "Forgejo seed failed; recent output:"
    tail -n 160 "${seed_log}" >&2 || true
    rm -f "${seed_log}" || true
    exit 1
  fi
  rm -f "${seed_log}" || true
}

commit_gitops_secrets() {
  git -C "${GITOPS_DIR}" add "deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/secrets" >/dev/null
  if git -C "${GITOPS_DIR}" diff --cached --quiet; then
    return 1
  fi
  local msg="[vault] Refresh init secrets $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  DK_ALLOW_MAIN_COMMIT=1 git -C "${GITOPS_DIR}" commit -m "${msg}" >/dev/null
  return 0
}

publish_gitops_secrets() {
  if ! commit_gitops_secrets; then
    log "no gitops secret changes detected; skipping commit/push"
    return
  fi
  push_gitops_repo
}

write_secret() {
  local src="$1" dest="$2"
  local tmp sops_config
  tmp=$(mktemp)
  cp "$src" "$tmp"
  mkdir -p "$(dirname "$dest")"
  cp "$tmp" "$dest"
  sops_config="${SOPS_CONFIG:-${SOPS_CONFIG_DEFAULT:-${REPO_ROOT}/.sops.yaml}}"
  SOPS_CONFIG="${sops_config}" SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    sops --encrypt --in-place "$dest"
  SOPS_CONFIG="${sops_config}" SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --decrypt "$dest" > "$tmp"
  run_kubectl apply -f "$tmp" >/dev/null
  rm -f "$tmp"
  UPDATED_SECRETS=true
  NEED_SOPS_CONFIGMAP_REFRESH=true
}

apply_sops_secret_file_to_cluster() {
  local namespace="$1" path="$2"
  if [[ -z "${path}" || ! -f "${path}" ]]; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  if ! sops --decrypt "${path}" >"${tmp}"; then
    log "failed to decrypt ${path}"
    rm -f "${tmp}" || true
    exit 1
  fi
  run_kubectl -n "${namespace}" apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"
}

get_vault_root_token() {
  local token
  if ! token=$(run_kubectl -n "$CORE_NAMESPACE" get secret vault-init -o jsonpath='{.data.root-token}' 2>/dev/null | b64decode); then
    return 1
  fi
  printf '%s' "$token"
}

vault_secret_exists() {
  local token="$1" path="$2"
  run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" SECRET_PATH="$path" \
    sh -c 'set -euo pipefail; vault kv get "$SECRET_PATH" >/dev/null 2>&1'
}

get_vault_secret_json() {
  local token="$1" path="$2"
  run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" SECRET_PATH="$path" \
    sh -c 'set -euo pipefail; vault kv get -format=json "$SECRET_PATH"' 2>/dev/null
}

extract_secret_field() {
  local json="$1" field="$2"
  if [[ -z "$json" ]]; then
    printf ''
    return
  fi
  jq -r --arg field "$field" '.data.data[$field] // empty' <<<"$json" 2>/dev/null || printf ''
}

seed_powerdns_vault_secrets() {
  if [[ "${SEED_DNS_VAULT_SECRETS}" != "true" ]]; then
    log "skipping PowerDNS secret seed (SEED_DNS_VAULT_SECRETS=false)"
    return
  fi
  if [[ "$SKIP_CORE" == "true" ]]; then
    log "skipping PowerDNS secret seed (SKIP_CORE=true)"
    return
  fi
  wait_unsealed "$CORE_NAMESPACE" "$CORE_STATEFULSET"
  local root_token
  if ! root_token=$(get_vault_root_token); then
    log "unable to read vault root token; aborting PowerDNS secret seed"
    return 1
  fi

  if ! vault_secret_exists "$root_token" "$PDNS_DB_SECRET_PATH"; then
    local db_password
    db_password=$(openssl rand -hex 24)
    if ! run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
      SECRET_PATH="$PDNS_DB_SECRET_PATH" DB_NAME="$PDNS_DB_NAME" DB_USER="$PDNS_DB_USERNAME" \
      DB_PASSWORD="$db_password" \
      sh -c 'set -euo pipefail
vault kv put "$SECRET_PATH" database="$DB_NAME" username="$DB_USER" password="$DB_PASSWORD" >/dev/null'; then
      log "failed seeding PowerDNS database credentials"
      return 1
    fi
    log "seeded PowerDNS database credentials at ${PDNS_DB_SECRET_PATH}"
  else
    log "PowerDNS database secret already exists at ${PDNS_DB_SECRET_PATH}; skipping"
  fi

  if ! vault_secret_exists "$root_token" "$PDNS_API_SECRET_PATH"; then
    local api_token
    api_token=$(openssl rand -hex 32)
    if ! run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
      SECRET_PATH="$PDNS_API_SECRET_PATH" API_KEY="$api_token" \
      sh -c 'set -euo pipefail
vault kv put "$SECRET_PATH" apiKey="$API_KEY" >/dev/null'; then
      log "failed seeding PowerDNS API token"
      return 1
    fi
    log "seeded PowerDNS API token at ${PDNS_API_SECRET_PATH}"
  else
    log "PowerDNS API secret already exists at ${PDNS_API_SECRET_PATH}; skipping"
  fi

  return 0
}

get_forgejo_admin_username_from_cluster() {
  run_kubectl -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_RELEASE}-admin" -o jsonpath='{.data.username}' 2>/dev/null | b64decode 2>/dev/null || true
}

get_forgejo_admin_password_from_cluster() {
  run_kubectl -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null | b64decode 2>/dev/null || true
}

get_forgejo_admin_token_from_cluster() {
  run_kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin-token -o jsonpath='{.data.token}' 2>/dev/null | b64decode 2>/dev/null || true
}

ensure_argocd_repo_secret_in_vault() {
  # Ensure the Vault secret backing Argo's repo credentials exists and matches Forgejo.
  # This avoids Argo ComparisonError loops when old admin creds or expired passwords are used.
  local root_token="$1"

  local desired_user desired_password
  desired_user=$(get_forgejo_admin_username_from_cluster)
  desired_password=$(get_forgejo_admin_token_from_cluster)
  if [[ -z "${desired_password}" ]]; then
    desired_password=$(get_forgejo_admin_password_from_cluster)
  fi

  if [[ -z "${desired_user}" || -z "${desired_password}" ]]; then
    log "unable to resolve Forgejo repo credentials from cluster; skipping Vault seed for ${FORGEJO_ARGO_REPO_SECRET_PATH}"
    return 0
  fi

  local existing_json existing_user existing_pass
  existing_json=$(get_vault_secret_json "${root_token}" "${FORGEJO_ARGO_REPO_SECRET_PATH}" || true)
  existing_user=$(extract_secret_field "${existing_json}" "username")
  existing_pass=$(extract_secret_field "${existing_json}" "password")

  if [[ "${existing_user}" == "${desired_user}" && "${existing_pass}" == "${desired_password}" ]]; then
    return 0
  fi

  if ! run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    SECRET_PATH="$FORGEJO_ARGO_REPO_SECRET_PATH" USERNAME="$desired_user" PASSWORD="$desired_password" \
    sh -c 'set -euo pipefail; vault kv put "$SECRET_PATH" username="$USERNAME" password="$PASSWORD" >/dev/null'; then
    log "failed to upsert ${FORGEJO_ARGO_REPO_SECRET_PATH} in Vault"
    return 1
  fi
  log "ensured Argo repo credentials in Vault at ${FORGEJO_ARGO_REPO_SECRET_PATH}"
  return 0
}

ensure_argocd_repo_secret_in_cluster() {
  # Best-effort immediate repair: if ESO created a repo secret with stale creds,
  # patch it so Argo can fetch manifests right away (ESO will later converge to Vault).
  local username="$1" password="$2"
  if ! run_kubectl -n "${ARGO_NAMESPACE}" get secret "${ARGO_REPO_SECRET_NAME}" >/dev/null 2>&1; then
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  run_kubectl -n "${ARGO_NAMESPACE}" create secret generic "${ARGO_REPO_SECRET_NAME}" \
    --from-literal=type=git \
    --from-literal=url="${ARGO_REPO_URL}" \
    --from-literal=username="${username}" \
    --from-literal=password="${password}" \
    --dry-run=client -o yaml >"${tmp}"
  run_kubectl -n "${ARGO_NAMESPACE}" label -f "${tmp}" -o yaml \
    argocd.argoproj.io/secret-type=repository --overwrite >"${tmp}.l"
  run_kubectl apply -f "${tmp}.l" >/dev/null || true
  rm -f "${tmp}" "${tmp}.l" || true
  log "patched Argo repo secret ${ARGO_NAMESPACE}/${ARGO_REPO_SECRET_NAME} (best effort)"
}

seed_forgejo_vault_secrets() {
  if [[ "${SEED_FORGEJO_VAULT_SECRETS}" != "true" ]]; then
    log "skipping Forgejo secret seed (SEED_FORGEJO_VAULT_SECRETS=false)"
    return
  fi
  if [[ "$SKIP_CORE" == "true" ]]; then
    log "skipping Forgejo secret seed (SKIP_CORE=true)"
    return
  fi
  wait_unsealed "$CORE_NAMESPACE" "$CORE_STATEFULSET"
  local root_token
  if ! root_token=$(get_vault_root_token); then
    log "unable to read vault root token; aborting Forgejo secret seed"
    return 1
  fi

  # Ensure Forgejo admin creds in Vault match the cluster. Old values here can later break
  # Argo repo auth (via ESO) with misleading "credentials expired" messages.
  local admin_user admin_password
  admin_user=$(get_forgejo_admin_username_from_cluster)
  admin_password=$(get_forgejo_admin_password_from_cluster)
  if [[ -z "${admin_password}" && -f "${FORGEJO_PASSWORD_FILE}" ]]; then
    admin_password=$(cat "${FORGEJO_PASSWORD_FILE}")
  fi
  if [[ -z "${admin_user}" ]]; then
    admin_user="${FORGEJO_ADMIN_USERNAME}"
  fi
  if [[ -n "${admin_password}" ]]; then
    local existing_admin_json existing_admin_user existing_admin_password
    existing_admin_json=$(get_vault_secret_json "$root_token" "$FORGEJO_ADMIN_SECRET_PATH" || true)
    existing_admin_user=$(extract_secret_field "$existing_admin_json" "username")
    existing_admin_password=$(extract_secret_field "$existing_admin_json" "password")
    if [[ "${existing_admin_user}" != "${admin_user}" || "${existing_admin_password}" != "${admin_password}" ]]; then
      if ! run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
        env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
        SECRET_PATH="$FORGEJO_ADMIN_SECRET_PATH" ADMIN_USER="$admin_user" ADMIN_PASSWORD="$admin_password" \
        sh -c 'set -euo pipefail; vault kv put "$SECRET_PATH" username="$ADMIN_USER" password="$ADMIN_PASSWORD" >/dev/null'; then
        log "failed seeding Forgejo admin credentials"
        return 1
      fi
      log "ensured Forgejo admin credentials in Vault at ${FORGEJO_ADMIN_SECRET_PATH}"
    else
      log "Forgejo admin secret already matches at ${FORGEJO_ADMIN_SECRET_PATH}; skipping"
    fi
  else
    log "unable to read Forgejo admin password from Kubernetes or ${FORGEJO_PASSWORD_FILE}; skipping admin secret seed"
  fi

  # Ensure Argo repo credentials exist in Vault and patch the in-cluster Argo secret best-effort.
  local repo_user repo_password
  repo_user=$(get_forgejo_admin_username_from_cluster)
  repo_password=$(get_forgejo_admin_token_from_cluster)
  [[ -z "${repo_password}" ]] && repo_password=$(get_forgejo_admin_password_from_cluster)
  if [[ -n "${repo_user}" && -n "${repo_password}" ]]; then
    ensure_argocd_repo_secret_in_vault "$root_token" || true
    ensure_argocd_repo_secret_in_cluster "${repo_user}" "${repo_password}" || true
  fi

  local db_secret_exists="false" db_secret_json=""
  if vault_secret_exists "$root_token" "$FORGEJO_DB_SECRET_PATH"; then
    db_secret_exists="true"
    db_secret_json=$(get_vault_secret_json "$root_token" "$FORGEJO_DB_SECRET_PATH" || true)
  fi

  local existing_db_name existing_db_user existing_password existing_app_password existing_superuser_password existing_superuser_user
  existing_db_name=$(extract_secret_field "$db_secret_json" "database")
  [[ -z "$existing_db_name" ]] && existing_db_name="$FORGEJO_DB_NAME"
  existing_db_user=$(extract_secret_field "$db_secret_json" "username")
  [[ -z "$existing_db_user" ]] && existing_db_user="$FORGEJO_DB_USERNAME"
  existing_password=$(extract_secret_field "$db_secret_json" "password")
  existing_app_password=$(extract_secret_field "$db_secret_json" "appPassword")
  existing_superuser_password=$(extract_secret_field "$db_secret_json" "superuserPassword")
  existing_superuser_user=$(extract_secret_field "$db_secret_json" "superuserUsername")
  [[ -z "$existing_superuser_user" ]] && existing_superuser_user="postgres"

  local missing_app_password="false" missing_superuser_password="false"
  [[ -z "$existing_app_password" ]] && missing_app_password="true"
  [[ -z "$existing_superuser_password" ]] && missing_superuser_password="true"

  local app_password superuser_password
  if [[ -n "$existing_app_password" ]]; then
    app_password="$existing_app_password"
  elif [[ -n "$existing_password" ]]; then
    app_password="$existing_password"
  else
    app_password=$(openssl rand -hex 24)
  fi

  if [[ -n "$existing_superuser_password" ]]; then
    superuser_password="$existing_superuser_password"
  else
    superuser_password=$(openssl rand -hex 24)
  fi

  local needs_update="false"
  if [[ "$db_secret_exists" != "true" ]]; then
    needs_update="true"
  elif [[ "$missing_app_password" == "true" || "$missing_superuser_password" == "true" ]]; then
    needs_update="true"
  fi

  if [[ "$needs_update" == "true" ]]; then
    if ! run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
      SECRET_PATH="$FORGEJO_DB_SECRET_PATH" DB_NAME="$existing_db_name" \
      DB_USER="$existing_db_user" APP_PASSWORD="$app_password" \
      SUPERUSER_PASSWORD="$superuser_password" SUPERUSER_USER="$existing_superuser_user" \
      sh -c 'set -euo pipefail
vault kv put "$SECRET_PATH" \
  database="$DB_NAME" \
  username="$DB_USER" \
  password="$APP_PASSWORD" \
  appPassword="$APP_PASSWORD" \
  superuserUsername="$SUPERUSER_USER" \
  superuserPassword="$SUPERUSER_PASSWORD" >/dev/null'; then
      log "failed seeding Forgejo database secret"
      return 1
    fi
    if [[ "$db_secret_exists" == "true" ]]; then
      log "updated Forgejo database secret at ${FORGEJO_DB_SECRET_PATH} with app/superuser credentials"
    else
      log "seeded Forgejo database secret at ${FORGEJO_DB_SECRET_PATH}"
    fi
  else
    log "Forgejo database secret already contains required app/superuser credentials; skipping"
  fi

  if ! vault_secret_exists "$root_token" "$FORGEJO_REDIS_SECRET_PATH"; then
    local redis_password
    redis_password=$(openssl rand -hex 24)
    if ! run_kubectl -n "$CORE_NAMESPACE" exec "statefulset/${CORE_STATEFULSET}" -c vault -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
      SECRET_PATH="$FORGEJO_REDIS_SECRET_PATH" REDIS_PASSWORD="$redis_password" \
      sh -c 'set -euo pipefail
vault kv put "$SECRET_PATH" password="$REDIS_PASSWORD" >/dev/null'; then
      log "failed seeding Forgejo redis credentials"
      return 1
    fi
    log "seeded Forgejo redis credentials at ${FORGEJO_REDIS_SECRET_PATH}"
  else
    log "Forgejo redis secret already exists at ${FORGEJO_REDIS_SECRET_PATH}; skipping"
  fi

  return 0
}

init_kms_shim() {
  log "root-of-trust provider is kmsShim (mode=${ROOT_OF_TRUST_MODE})"

  if [[ "${ROOT_OF_TRUST_MODE}" == "external" ]] && [[ -z "${ROOT_OF_TRUST_EXTERNAL_ADDR}" ]]; then
    log "kmsShim external mode requires spec.secrets.rootOfTrust.external.address in ${DEPLOYMENT_CONFIG_YAML}"
    exit 1
  fi

  if [[ "${ROOT_OF_TRUST_MODE}" == "inCluster" ]]; then
    ensure_namespace "${KMS_SHIM_NAMESPACE}"
    ensure_app_exists "${KMS_SHIM_APP}"
  fi

  ensure_kms_shim_secret_material
  if [[ "$UPDATED_SECRETS" == "true" ]]; then
    publish_gitops_secrets
    UPDATED_SECRETS=false
    rerun_secrets_apps
  fi

  apply_sops_secret_file_to_cluster "${CORE_NAMESPACE}" "${KMS_SHIM_TOKEN_SECRET_SYSTEM_PATH}"
  if [[ "${ROOT_OF_TRUST_MODE}" == "inCluster" ]]; then
    apply_sops_secret_file_to_cluster "${KMS_SHIM_NAMESPACE}" "${KMS_SHIM_KEY_SECRET_PATH}"
    apply_sops_secret_file_to_cluster "${KMS_SHIM_NAMESPACE}" "${KMS_SHIM_TOKEN_SECRET_SHIM_PATH}"

    sync_app "${KMS_SHIM_APP}"
    wait_deployment_ready "${KMS_SHIM_NAMESPACE}" "kms-shim" "${KMS_SHIM_WAIT_TIMEOUT:-900s}"
  fi
}

init_core() {
  wait_statefulset "$CORE_NAMESPACE" "$CORE_STATEFULSET"
  local pod="${CORE_STATEFULSET}-0"
  wait_pod_exec_ready "$CORE_NAMESPACE" "$pod"
  if vault_initialized "$CORE_NAMESPACE" "pod/$pod"; then
    if [[ "${REINIT_CORE}" == "true" && "${WIPE_CORE}" != "true" ]]; then
      log "core vault is already initialized; --reinit-core requires --wipe-core-data to be set (destructive)"
      exit 1
    fi
    log "core vault already initialized; skipping operator init"
    ensure_core_secret_material
    return 0
  fi
  log "initializing core"
  local json
  json=$(run_with_retries "$CORE_NAMESPACE" "pod/$pod" \
    'set -euo pipefail; export VAULT_ADDR=http://127.0.0.1:8200; vault operator init -format=json')
  local root_token recovery_key
  root_token=$(jq -r '.root_token' <<<"$json")
  recovery_key=$(jq -r '.recovery_keys_b64[0]' <<<"$json")
  local tmp
  tmp=$(mktemp)
  cat > "${tmp}" <<EOT
apiVersion: v1
kind: Secret
metadata:
  name: vault-init
  namespace: ${CORE_NAMESPACE}
stringData:
  root-token: ${root_token}
  recovery-key: ${recovery_key}
  bootstrap-notes: Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOT
  write_secret "${tmp}" "$CORE_SECRET_PATH"
  rm -f "${tmp}"
  wait_initialized "$CORE_NAMESPACE" "pod/${CORE_STATEFULSET}-0"
}

rerun_secrets_apps() {
  log "rerunning secrets bootstrap"
  pause_self_heal "$SECRETS_APP" || true
  trap 'resume_self_heal "$SECRETS_APP" || true' RETURN
  refresh_sops_configmap
  run_kubectl -n argocd delete job "$SECRETS_APP" --ignore-not-found >/dev/null
  # Prefer running the Job from local manifests if the RBAC is already present.
  # This avoids relying on Argo pulling a just-force-pushed Forgejo revision
  # (Forgejo can be temporarily unhealthy during cluster bootstrap).
  if run_kubectl -n argocd get serviceaccount secrets-bootstrap >/dev/null 2>&1; then
    run_kubectl -n argocd apply -f "${REPO_ROOT}/platform/gitops/components/secrets/bootstrap/job.yaml" >/dev/null
  else
    sync_app "$SECRETS_APP"
  fi
  for _ in {1..60}; do
    if run_kubectl -n argocd get job "$SECRETS_APP" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  if ! wait_job_complete "argocd" "$SECRETS_APP" "${SECRETS_BOOTSTRAP_JOB_TIMEOUT}"; then
    log "secrets bootstrap job did not complete; recent status:"
    run_kubectl -n argocd get job "$SECRETS_APP" -o wide || true
    run_kubectl -n argocd describe job "$SECRETS_APP" || true
    run_kubectl -n argocd get pods -l job-name="$SECRETS_APP" -o wide || true
    trap - RETURN
    resume_self_heal "$SECRETS_APP" || true
    return 1
  fi
  trap - RETURN
  resume_self_heal "$SECRETS_APP" || true
}

refresh_sops_configmap() {
  if [[ "${NEED_SOPS_CONFIGMAP_REFRESH}" != "true" ]]; then
    return
  fi
  log "updating deployment secrets bundle ConfigMap with refreshed SOPS blobs"
  local tmp
  tmp=$(mktemp)
  local -a from_files=()
  local dep_secrets_dir="${DEPLOYKUBE_DEPLOYMENTS_DIR}/${DEPLOYKUBE_DEPLOYMENT_ID}/secrets"
  local f base
  while IFS= read -r f; do
    base="$(basename "${f}")"
    from_files+=(--from-file="${base}=${f}")
  done < <(find "${dep_secrets_dir}" -maxdepth 1 -type f -name '*.secret.sops.yaml' -print | sort)
  kubectl --context "${KUBE_CONTEXT}" -n argocd create configmap deploykube-deployment-secrets \
    "${from_files[@]}" \
    --dry-run=client -o yaml >"$tmp"
  kubectl --context "${KUBE_CONTEXT}" apply -f "$tmp" >/dev/null
  rm -f "$tmp"

  # Keep the DeploymentConfig ConfigMap aligned as well (non-secret, but the job branches on it).
  tmp=$(mktemp)
  kubectl --context "${KUBE_CONTEXT}" -n argocd create configmap deploykube-deployment-config \
    --from-file="deployment-config.yaml=${DEPLOYKUBE_DEPLOYMENTS_DIR}/${DEPLOYKUBE_DEPLOYMENT_ID}/config.yaml" \
    --dry-run=client -o yaml >"$tmp"
  kubectl --context "${KUBE_CONTEXT}" apply -f "$tmp" >/dev/null
  rm -f "$tmp"

  # Keep the bootstrap script ConfigMap aligned as well, so the job can run without
  # relying on Argo/Forgejo to refresh manifests during rotations.
  tmp=$(mktemp)
  kubectl --context "${KUBE_CONTEXT}" -n argocd create configmap secrets-bootstrap-script \
    --from-file="bootstrap.sh=${REPO_ROOT}/platform/gitops/components/secrets/bootstrap/scripts/bootstrap.sh" \
    --dry-run=client -o yaml >"$tmp"
  kubectl --context "${KUBE_CONTEXT}" apply -f "$tmp" >/dev/null
  rm -f "$tmp"

  NEED_SOPS_CONFIGMAP_REFRESH=false
}

rerun_core_bootstrap() {
  local repause_root=false
  if [[ "${ROOT_APP_PAUSED}" == "true" ]]; then
    resume_root_app
    repause_root=true
  fi
  ensure_core_bootstrap_app_materialized
  if [[ "${repause_root}" == "true" ]]; then
    pause_root_app
  fi
  local bootstrap_app config_app has_config_app=false
  bootstrap_app="$(resolve_core_bootstrap_app)"
  config_app="$(resolve_core_config_app)"
  if argocd_app_exists "secrets-vault-config"; then
    has_config_app=true
  fi
  log "rerunning core bootstrap"
  run_kubectl -n "$CORE_NAMESPACE" delete job vault-init --ignore-not-found --wait=false >/dev/null 2>&1 || true
  clear_stuck_hook_operation "${bootstrap_app}" vault-init
  delete_hook_job "$CORE_NAMESPACE" vault-configure
  delete_hook_job "$CORE_NAMESPACE" vault-raft-backup-warmup
  # The vault-configure job is an Argo PostSync hook with delete-on-success. Use a completion
  # marker ConfigMap to avoid races where the Job is deleted before our poll sees success.
  run_kubectl -n "$CORE_NAMESPACE" delete configmap "${VAULT_CONFIGURE_COMPLETE_CONFIGMAP}" --ignore-not-found >/dev/null 2>&1 || true
  clear_stuck_hook_operation "${config_app}" vault-configure
  clear_stuck_hook_operation "${config_app}" vault-raft-backup-warmup
  sync_app "${bootstrap_app}"
  if ! wait_job_exists "$CORE_NAMESPACE" "vault-init"; then
    log "unable to detect core vault-init job creation"
    exit 1
  fi
  if ! wait_job_complete "$CORE_NAMESPACE" "vault-init" "${CORE_BOOTSTRAP_JOB_TIMEOUT}"; then
    log "core vault-init job failed; inspect with kubectl -n ${CORE_NAMESPACE} logs job/vault-init"
    exit 1
  fi
  if [[ "${has_config_app}" == "true" ]]; then
    sync_app "${config_app}"
  else
    apply_vault_config_overlay_direct
  fi
  if [[ -n "${CORE_BACKUP_PVC_NAME}" ]] && ! run_kubectl -n "${CORE_NAMESPACE}" get pvc "${CORE_BACKUP_PVC_NAME}" >/dev/null 2>&1; then
    local app_msg
    app_msg=$(run_kubectl -n argocd get application "${config_app}" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
    if [[ "${app_msg}" == *"batch/Job/vault-raft-backup-warmup"* ]]; then
      log "backup warmup hook is blocking ${config_app} while PVC ${CORE_NAMESPACE}/${CORE_BACKUP_PVC_NAME} is missing; resetting hook operation"
      delete_hook_job "${CORE_NAMESPACE}" vault-raft-backup-warmup
      clear_stuck_hook_operation "${config_app}" vault-raft-backup-warmup
      sync_app "${config_app}"
    fi
  fi
  ensure_core_backup_pvc_bound || exit 1
  # Ensure the scripts ConfigMap exists before considering any manual fallback. During initial
  # bootstrap, Argo can legitimately take >60s to reach the PostSync hook (e.g. waiting for
  # WaitForFirstConsumer PVC binding), and the manual job must not be created before the
  # ConfigMap is applied.
  if ! wait_configmap_exists "$CORE_NAMESPACE" "vault-configure-script" "600s"; then
    log "vault-configure-script ConfigMap missing after syncing ${config_app}"
    log "Argo status for ${config_app}:"
    run_kubectl -n argocd get application "${config_app}" -o jsonpath='{.status.operationState.phase} {.status.operationState.message}{"\n"}' || true
    exit 1
  fi
  local configure_job_present=false
  for _ in {1..60}; do
    if run_kubectl -n "$CORE_NAMESPACE" get configmap "${VAULT_CONFIGURE_COMPLETE_CONFIGMAP}" >/dev/null 2>&1; then
      configure_job_present=true
      break
    fi
    if run_kubectl -n "$CORE_NAMESPACE" get job vault-configure >/dev/null 2>&1; then
      configure_job_present=true
      break
    fi
    sleep 5
  done
  if [[ "${configure_job_present}" != "true" ]]; then
    run_manual_vault_configure_job
  fi
  # Don't require observing the hook Job object: Argo can create and delete it quickly
  # (HookSucceeded), and a 5s poll interval is enough to miss it entirely.
  if ! wait_configmap_exists "$CORE_NAMESPACE" "${VAULT_CONFIGURE_COMPLETE_CONFIGMAP}" "180s"; then
    log "core vault-configure completion marker not observed quickly; running manual configure fallback"
    run_manual_vault_configure_job
  fi
  if ! wait_configmap_exists "$CORE_NAMESPACE" "${VAULT_CONFIGURE_COMPLETE_CONFIGMAP}" "300s"; then
    if run_kubectl -n "$CORE_NAMESPACE" get job vault-configure >/dev/null 2>&1; then
      log "core vault-configure completion marker missing; recent logs:"
      run_kubectl -n "$CORE_NAMESPACE" logs job/vault-configure || true
    fi
    log "core vault-configure completion marker missing after fallback; inspect Argo application ${config_app} and vault-system events"
    exit 1
  fi
  # Argo hook races can still leave Vault without kubernetes auth or the external-secrets role
  # even when the hook operation appears complete. Verify and self-heal before continuing.
  if ! vault_kubernetes_auth_ready; then
    log "vault kubernetes auth not fully configured after hook completion; rerunning manual configure job"
    run_manual_vault_configure_job
    if ! wait_configmap_exists "$CORE_NAMESPACE" "${VAULT_CONFIGURE_COMPLETE_CONFIGMAP}" "900s"; then
      log "core vault-configure completion marker still missing after manual rerun"
      exit 1
    fi
  fi
  if ! vault_kubernetes_auth_ready; then
    log "vault kubernetes auth/role setup still missing after manual configure retry"
    exit 1
  fi
  sync_app "$CORE_APP"
  wait_statefulset "$CORE_NAMESPACE" "$CORE_STATEFULSET"
  wait_unsealed "$CORE_NAMESPACE" "$CORE_STATEFULSET"
}

rerun_tenant_eso_config() {
  local cronjob="vault-tenant-eso-config"
  if ! run_kubectl -n "$CORE_NAMESPACE" get cronjob "${cronjob}" >/dev/null 2>&1; then
    log "tenant ESO CronJob ${cronjob} not found; skipping tenant role reconciliation"
    return
  fi
  local manual_job="vault-tenant-eso-config-manual-$(date -u +%s)"
  log "rerunning tenant ESO role reconciliation job (${manual_job})"
  run_kubectl -n "$CORE_NAMESPACE" create job --from="cronjob/${cronjob}" "${manual_job}" >/dev/null
  if ! wait_job_complete "$CORE_NAMESPACE" "${manual_job}" "600s"; then
    log "tenant ESO reconciliation job failed; recent logs:"
    run_kubectl -n "$CORE_NAMESPACE" logs "job/${manual_job}" || true
    exit 1
  fi
  run_kubectl -n "$CORE_NAMESPACE" delete job "${manual_job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  if run_kubectl get clustersecretstore "${TENANT_ESO_STORE_NAME}" >/dev/null 2>&1; then
    if ! wait_clustersecretstore_ready "${TENANT_ESO_STORE_NAME}" "${TENANT_ESO_WAIT_TIMEOUT}"; then
      if [[ "${TENANT_ESO_WAIT_STRICT}" == "true" ]]; then
        log "tenant ClusterSecretStore ${TENANT_ESO_STORE_NAME} not ready after ${TENANT_ESO_WAIT_TIMEOUT} (strict mode)"
        exit 1
      fi
      log "tenant ClusterSecretStore ${TENANT_ESO_STORE_NAME} not ready after ${TENANT_ESO_WAIT_TIMEOUT}; continuing bootstrap and relying on later reconciliation"
    fi
  fi
}

rerun_vault_safeguard() {
  log "rerunning vault safeguard job"
  if ! run_kubectl -n "$CORE_NAMESPACE" delete job vault-safeguard --ignore-not-found >/dev/null 2>&1; then
    :
  fi
  sync_app secrets-vault-safeguard
  for _ in {1..60}; do
    if run_kubectl -n "$CORE_NAMESPACE" get job/vault-safeguard >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
run_kubectl -n "$CORE_NAMESPACE" wait --for=condition=complete job/vault-safeguard --timeout=600s >/dev/null
}

run_manual_step_ca_seed_job() {
  local manual_job="step-ca-vault-seed-manual-$(date -u +%s)"
  local tmp
  tmp=$(mktemp)
  log "step-ca seed hook missing/incomplete; running manual seed job (${manual_job})"
  cat >"${tmp}" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${manual_job}
  namespace: ${ARGO_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  template:
    metadata:
      annotations:
        sidecar.istio.io/nativeSidecar: 'true'
    spec:
      serviceAccountName: step-ca-vault-seed
      restartPolicy: OnFailure
      containers:
      - name: seed
        image: registry.example.internal/deploykube/bootstrap-tools:1.4
        command:
        - /bin/sh
        - /scripts/seed.sh
        env:
        - name: SOPS_AGE_KEY_FILE
          value: /var/run/sops/age.key
        - name: STEP_CA_SEED_FILE
          value: /config/step-ca-vault-seed.secret.sops.yaml
        - name: VAULT_ADDR
          value: http://vault.vault-system.svc:8200
        - name: VAULT_NAMESPACE
          value: vault-system
        volumeMounts:
        - name: script
          mountPath: /scripts
          readOnly: true
        - name: istio-native-exit
          mountPath: /helpers
          readOnly: true
        - name: seed
          mountPath: /config/step-ca-vault-seed.secret.sops.yaml
          subPath: step-ca-vault-seed.secret.sops.yaml
        - name: age-key
          mountPath: /var/run/sops
          readOnly: true
      volumes:
      - name: script
        configMap:
          name: step-ca-vault-seed-script
          defaultMode: 0755
      - name: istio-native-exit
        configMap:
          name: istio-native-exit-script
          defaultMode: 0444
      - name: seed
        configMap:
          name: deploykube-deployment-secrets
          defaultMode: 0440
      - name: age-key
        secret:
          secretName: argocd-sops-age
          defaultMode: 0400
YAML
  run_kubectl apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"
  if ! wait_job_complete "${ARGO_NAMESPACE}" "${manual_job}" "900s"; then
    log "manual Step CA seed job failed; recent logs:"
    run_kubectl -n "${ARGO_NAMESPACE}" logs "job/${manual_job}" || true
    exit 1
  fi
  run_kubectl -n "${ARGO_NAMESPACE}" delete job "${manual_job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

rerun_step_ca_seed() {
  if [[ "$SKIP_CORE" == "true" ]]; then
    log "skipping Step CA seed rerun (SKIP_CORE=true)"
    return
  fi
  wait_unsealed "$CORE_NAMESPACE" "$CORE_STATEFULSET"
  local root_token
  if ! root_token=$(get_vault_root_token); then
    log "unable to read vault root token; cannot verify Step CA vault seed"
    exit 1
  fi
  local config_before certs_before keys_before passwords_before
  config_before=$(vault_secret_version "$root_token" "secret/step-ca/config")
  certs_before=$(vault_secret_version "$root_token" "secret/step-ca/certs")
  keys_before=$(vault_secret_version "$root_token" "secret/step-ca/keys")
  passwords_before=$(vault_secret_version "$root_token" "secret/step-ca/passwords")
  log "rerunning Step CA vault seed job ${STEP_CA_SEED_JOB}"
  delete_hook_job "$ARGO_NAMESPACE" "$STEP_CA_SEED_JOB"
  clear_stuck_hook_operation "$STEP_CA_SEED_APP" "$STEP_CA_SEED_JOB" "$ARGO_NAMESPACE"
  sync_app "$STEP_CA_SEED_APP"

  # step-ca-vault-seed is an Argo hook with HookSucceeded deletion and can leave operation state stuck.
  # Verify success via KV version bumps; if Argo hook doesn't refresh material quickly, run a manual fallback.
  local hook_timeout="${STEP_CA_SEED_HOOK_WAIT_TIMEOUT:-180s}"
  if ! wait_step_ca_seed_material_refreshed "$root_token" "${hook_timeout}" "$config_before" "$certs_before" "$keys_before" "$passwords_before"; then
    run_manual_step_ca_seed_job
    wait_step_ca_seed_material_refreshed "$root_token" "${STEP_CA_SEED_MANUAL_WAIT_TIMEOUT:-300s}" "$config_before" "$certs_before" "$keys_before" "$passwords_before" || exit 1
  fi
  log "Step CA vault seed material present"
}

rerun_step_ca_secrets() {
  if [[ "$SKIP_CORE" == "true" ]]; then
    log "skipping Step CA ExternalSecrets sync (SKIP_CORE=true)"
    return
  fi
  log "syncing Step CA ExternalSecrets via ${STEP_CA_SECRETS_APP}"
  sync_app "$STEP_CA_SECRETS_APP"
  # The ExternalSecrets controller will surface SecretSyncedError until the Vault auth role is configured
  # and the Vault service endpoints are reachable. Make this explicit so bootstrap doesn't appear "stuck".
  wait_clustersecretstore_ready "vault-core" "${STEP_CA_SECRETS_WAIT_TIMEOUT:-1800s}" || exit 1
  local secret_timeout="${STEP_CA_SECRETS_WAIT_TIMEOUT:-1800s}"
  local secret
  for secret in "${STEP_CA_SECRET_TARGETS[@]}"; do
    wait_secret "$STEP_CA_NAMESPACE" "$secret" "$secret_timeout"
  done
  log "Step CA runtime secrets present"
}

run_manual_step_ca_root_secret_bootstrap_job() {
  local manual_job="step-ca-root-secret-bootstrap-manual-$(date -u +%s)"
  local tmp
  tmp=$(mktemp)
  log "step-ca root TLS hook missing/incomplete; running manual bootstrap job (${manual_job})"
  cat >"${tmp}" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${manual_job}
  namespace: ${STEP_CA_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: step-ca-root-secret-bootstrap
      restartPolicy: OnFailure
      containers:
      - name: bootstrap
        image: registry.example.internal/deploykube/bootstrap-tools:1.4
        command:
        - /bin/sh
        - /scripts/step-ca-root-secret-bootstrap.sh
        env:
        - name: STEP_CA_FULLNAME
          value: ${STEP_CA_RELEASE_NAME}
        - name: STEP_CA_NAMESPACE
          value: ${STEP_CA_NAMESPACE}
        - name: CERT_MANAGER_NAMESPACE
          value: ${CERT_MANAGER_NAMESPACE}
        - name: STEP_CA_TLS_SECRET_NAME
          value: ${STEP_CA_TLS_SECRET_NAME}
        volumeMounts:
        - name: script
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: script
        configMap:
          name: step-ca-root-secret-bootstrap-script
          defaultMode: 0755
YAML
  run_kubectl apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"
  if ! wait_job_complete "${STEP_CA_NAMESPACE}" "${manual_job}" "900s"; then
    log "manual Step CA root TLS bootstrap job failed; recent logs:"
    run_kubectl -n "${STEP_CA_NAMESPACE}" logs "job/${manual_job}" || true
    exit 1
  fi
  run_kubectl -n "${STEP_CA_NAMESPACE}" delete job "${manual_job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

ensure_step_ca_release() {
  if [[ "$SKIP_CORE" == "true" ]]; then
    log "skipping Step CA release sync (SKIP_CORE=true)"
    return
  fi
  log "ensuring Step CA StatefulSet reconciles"
  sync_app "$STEP_CA_APP"
  wait_statefulset "$STEP_CA_NAMESPACE" "$STEP_CA_STATEFULSET"
  log "ensuring Step CA bootstrap job refreshes TLS secret"
  run_kubectl -n "$STEP_CA_NAMESPACE" delete job step-ca-root-secret-bootstrap --ignore-not-found >/dev/null 2>&1 || true
  sync_app "$STEP_CA_BOOTSTRAP_APP"
  local tls_secret_timeout="${STEP_CA_TLS_SECRET_WAIT_TIMEOUT:-600s}"
  if ! wait_secret "$CERT_MANAGER_NAMESPACE" "$STEP_CA_TLS_SECRET_NAME" "$tls_secret_timeout"; then
    clear_stuck_hook_operation "$STEP_CA_BOOTSTRAP_APP" step-ca-root-secret-bootstrap "$STEP_CA_NAMESPACE" || true
    run_manual_step_ca_root_secret_bootstrap_job
    wait_secret "$CERT_MANAGER_NAMESPACE" "$STEP_CA_TLS_SECRET_NAME" "180s" || exit 1
  fi
  log "Step CA bootstrap TLS secret ${STEP_CA_TLS_SECRET_NAME} present"
}

main() {
  parse_args "$@"
  resolve_dsb_paths
  guard_preserve_mode
  require kubectl
  require yq
  require jq
  require sops
  require age-keygen
  require git
  require python3
  require openssl
  detect_root_of_trust
  validate_skip_matrix core "$SKIP_CORE" "$WIPE_CORE" "$REINIT_CORE"
  ensure_age_key
  sync_app "$ROOT_APP"
  ensure_core_bootstrap_app_materialized
  ensure_argocd_controller_running
  configure_nfs_scrub_backend
  trap cleanup EXIT
  if should_pause_root_app; then
    pause_root_app
  else
    log "bootstrap mode: leaving root Argo Application unpaused (set VAULT_INIT_PAUSE_ROOT_APP=true to force pausing)"
  fi

  init_kms_shim

  if [[ "$SKIP_CORE" != "true" ]]; then
    if [[ "$WIPE_CORE" == "true" ]]; then
      wipe_cluster "core" "$CORE_NAMESPACE" "$CORE_STATEFULSET" "$CORE_APP" "${CORE_EXTRA_PVCS[*]}" "${CORE_NFS_DIRS[@]}"
    fi
    init_core
    if [[ "$UPDATED_SECRETS" == "true" ]]; then
      publish_gitops_secrets
      UPDATED_SECRETS=false
      rerun_secrets_apps
    fi

    apply_sops_secret_file_to_cluster "${CORE_NAMESPACE}" "${CORE_SECRET_PATH}"

    wait_secret "$CORE_NAMESPACE" "$CORE_SECRET_NAME"
    record_bootstrap_status "core" "$CORE_NAMESPACE" "$CORE_SECRET_NAME" \
      "$CORE_NAMESPACE" "data-${CORE_STATEFULSET}-0"
    rerun_core_bootstrap
    rerun_tenant_eso_config
    seed_powerdns_vault_secrets || exit 1
    seed_forgejo_vault_secrets || exit 1
    rerun_step_ca_seed
    rerun_step_ca_secrets
    ensure_step_ca_release
    rerun_vault_safeguard
  fi

  log "vault initialization complete"
}

main "$@"
