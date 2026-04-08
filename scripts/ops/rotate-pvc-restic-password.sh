#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-prod}"
DEPLOYMENT_ID="${DEPLOYMENT_ID:-proxmox-talos}"
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-backup-system}"
BACKUP_PVC="${BACKUP_PVC:-backup-target}"
BACKUP_CRONJOB="${BACKUP_CRONJOB:-storage-pvc-restic-backup}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault-system}"
VAULT_KV_PATH="${VAULT_KV_PATH:-secret/backup/pvc-restic}"
ROTATION_IMAGE="${ROTATION_IMAGE:-docker.io/restic/restic:0.18.1}"
SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-300}"

PHASE=""
DRY_RUN="false"
PREPARE_CANDIDATE_PASSWORD=""

VAULT_POD=""
VAULT_TOKEN=""
ROTATION_POD=""
CRON_RESUME_REQUIRED="false"

ACTIVE_PASSWORD=""
CANDIDATE_PASSWORD=""
PASSWORD_VERSION=""
PASSWORD_ROTATED_AT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[restic-rotation]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[restic-rotation]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[restic-rotation]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[restic-rotation]${NC} %s\n" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage:
  ./scripts/ops/rotate-pvc-restic-password.sh <prepare|promote> [options]

Two-phase restic password lifecycle for the platform PVC backup plane:
  1) prepare: add candidate key to all repos (`restic key add`) and stage it in Vault.
  2) promote: remove old key from all repos (`restic key remove`) and promote candidate in Vault.

Precondition:
  - Existing repos are non-root compatible (run once: ./scripts/ops/migrate-pvc-restic-repo-permissions.sh)

Options:
  --kubeconfig <path>           Kubeconfig path (default: tmp/kubeconfig-prod)
  --deployment-id <id>          Deployment id (default: proxmox-talos)
  --backup-namespace <ns>       Backup namespace (default: backup-system)
  --backup-pvc <name>           Backup target PVC (default: backup-target)
  --backup-cronjob <name>       PVC backup CronJob name (default: storage-pvc-restic-backup)
  --vault-namespace <ns>        Vault namespace (default: vault-system)
  --vault-kv-path <path>        Vault KV path (default: secret/backup/pvc-restic)
  --rotation-image <image>      Image used for in-cluster key rotation (default: restic:0.18.1)
  --sync-timeout-seconds <sec>  Wait timeout for ESO secret sync (default: 300)
  --candidate-password <value>  Candidate password (prepare only; random if omitted)
  --dry-run                     Print actions without mutating state
  -h, --help                    Show help

Examples:
  ./scripts/ops/rotate-pvc-restic-password.sh prepare
  ./scripts/ops/rotate-pvc-restic-password.sh promote
EOF
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    log_error "missing dependency: ${cmd}"
    exit 1
  }
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    prepare|promote)
      PHASE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "first argument must be prepare or promote"
      usage
      exit 1
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) KUBECONFIG="$2"; shift 2 ;;
      --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
      --backup-namespace) BACKUP_NAMESPACE="$2"; shift 2 ;;
      --backup-pvc) BACKUP_PVC="$2"; shift 2 ;;
      --backup-cronjob) BACKUP_CRONJOB="$2"; shift 2 ;;
      --vault-namespace) VAULT_NAMESPACE="$2"; shift 2 ;;
      --vault-kv-path) VAULT_KV_PATH="$2"; shift 2 ;;
      --rotation-image) ROTATION_IMAGE="$2"; shift 2 ;;
      --sync-timeout-seconds) SYNC_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --candidate-password) PREPARE_CANDIDATE_PASSWORD="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift 1 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ "${PHASE}" != "prepare" && -n "${PREPARE_CANDIDATE_PASSWORD}" ]]; then
    log_error "--candidate-password is only valid for prepare"
    exit 1
  fi
}

cleanup() {
  local rc=$?
  if [[ -n "${ROTATION_POD}" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" delete pod "${ROTATION_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if [[ "${CRON_RESUME_REQUIRED}" == "true" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${BACKUP_CRONJOB}" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

ensure_prereqs() {
  require_cmd kubectl
  require_cmd jq
  require_cmd openssl
  require_cmd base64
  require_cmd date

  if [[ ! -f "${KUBECONFIG}" ]]; then
    log_error "kubeconfig not found: ${KUBECONFIG}"
    exit 1
  fi

  if ! [[ "${SYNC_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || [[ "${SYNC_TIMEOUT_SECONDS}" -le 0 ]]; then
    log_error "--sync-timeout-seconds must be a positive integer"
    exit 1
  fi
}

ensure_vault_access() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi

  VAULT_POD="$(kubectl --kubeconfig "${KUBECONFIG}" -n "${VAULT_NAMESPACE}" get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${VAULT_POD}" ]]; then
    log_error "vault pod not found in namespace ${VAULT_NAMESPACE}"
    exit 1
  fi

  VAULT_TOKEN="$(kubectl --kubeconfig "${KUBECONFIG}" -n "${VAULT_NAMESPACE}" get secret vault-init -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "${VAULT_TOKEN}" ]]; then
    log_error "could not load root-token from ${VAULT_NAMESPACE}/secret/vault-init"
    exit 1
  fi

  if ! vault_exec vault status >/dev/null 2>&1; then
    log_error "vault is not ready for CLI access"
    exit 1
  fi
}

vault_exec() {
  kubectl --kubeconfig "${KUBECONFIG}" -n "${VAULT_NAMESPACE}" exec "${VAULT_POD}" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="${VAULT_TOKEN}" \
    VAULT_TOKEN="${VAULT_TOKEN}" \
    "$@"
}

vault_get_field() {
  local field="$1"
  vault_exec env DK_VAULT_PATH="${VAULT_KV_PATH}" DK_VAULT_FIELD="${field}" sh -c 'set -eu; vault kv get -field="${DK_VAULT_FIELD}" "${DK_VAULT_PATH}" 2>/dev/null || true'
}

read_vault_state() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    ACTIVE_PASSWORD="<active-password>"
    CANDIDATE_PASSWORD=""
    PASSWORD_VERSION="1"
    PASSWORD_ROTATED_AT="<rfc3339>"
    return 0
  fi

  if ! vault_exec env DK_VAULT_PATH="${VAULT_KV_PATH}" sh -c 'set -eu; vault kv get "${DK_VAULT_PATH}" >/dev/null'; then
    log_error "vault key not found: ${VAULT_KV_PATH}"
    exit 1
  fi

  ACTIVE_PASSWORD="$(vault_get_field RESTIC_PASSWORD)"
  CANDIDATE_PASSWORD="$(vault_get_field RESTIC_PASSWORD_CANDIDATE)"
  PASSWORD_VERSION="$(vault_get_field PASSWORD_VERSION)"
  PASSWORD_ROTATED_AT="$(vault_get_field PASSWORD_ROTATED_AT)"

  if [[ -z "${ACTIVE_PASSWORD}" ]]; then
    log_error "RESTIC_PASSWORD is empty in ${VAULT_KV_PATH}"
    exit 1
  fi
  if [[ -z "${PASSWORD_VERSION}" ]]; then
    PASSWORD_VERSION="1"
  fi
  if ! [[ "${PASSWORD_VERSION}" =~ ^[0-9]+$ ]]; then
    log_error "PASSWORD_VERSION must be numeric in ${VAULT_KV_PATH} (got ${PASSWORD_VERSION})"
    exit 1
  fi
  if [[ -z "${PASSWORD_ROTATED_AT}" ]]; then
    PASSWORD_ROTATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
}

suspend_backup_cronjob() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping CronJob suspend"
    return 0
  fi

  local current_suspend
  current_suspend="$(kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" get cronjob "${BACKUP_CRONJOB}" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  current_suspend="${current_suspend:-false}"

  if [[ "${current_suspend}" != "true" ]]; then
    log "suspending ${BACKUP_NAMESPACE}/cronjob/${BACKUP_CRONJOB}"
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${BACKUP_CRONJOB}" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
    CRON_RESUME_REQUIRED="true"
  fi

  local active attempt
  attempt=0
  while true; do
    active="$(kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" get cronjob "${BACKUP_CRONJOB}" -o jsonpath='{range .status.active[*]}{.name}{" "}{end}' 2>/dev/null || true)"
    if [[ -z "${active}" ]]; then
      break
    fi
    attempt=$((attempt + 1))
    if [[ "${attempt}" -ge 120 ]]; then
      log_error "timed out waiting for active Jobs of ${BACKUP_CRONJOB} to finish"
      exit 1
    fi
    sleep 5
  done
}

create_rotation_pod() {
  ROTATION_POD="restic-key-rotate-${PHASE}-$(date -u +%Y%m%d%H%M%S)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping creation of rotation pod ${ROTATION_POD}"
    return 0
  fi

  log "creating rotation pod ${BACKUP_NAMESPACE}/${ROTATION_POD}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${ROTATION_POD}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 65532
    runAsGroup: 65532
    runAsNonRoot: true
    fsGroup: 65532
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: rotate
      image: ${ROTATION_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sh","-c","sleep infinity"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        readOnlyRootFilesystem: true
      volumeMounts:
        - name: backup
          mountPath: /backup
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: ${BACKUP_PVC}
EOF
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" wait --for=condition=Ready "pod/${ROTATION_POD}" --timeout=180s >/dev/null
}

run_repo_rotation() {
  local phase="$1"
  local old_password="$2"
  local new_password="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping ${phase} restic key operations"
    return 0
  fi

  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" exec -i "${ROTATION_POD}" -- env \
    PHASE="${phase}" \
    DEPLOYMENT_ID="${DEPLOYMENT_ID}" \
    OLD_PASSWORD="${old_password}" \
    NEW_PASSWORD="${new_password}" \
    sh -s <<'EOF'
set -eu

base="/backup/${DEPLOYMENT_ID}/pvc-restic/namespaces"
if [ ! -d "${base}" ]; then
  echo "[restic-rotate] no pvc-restic repository tree found at ${base}; nothing to rotate"
  exit 0
fi

repo_list="/tmp/restic-repos.txt"
find "${base}" -type f -path "*/persistentvolumeclaims/*/repo/config" | sort > "${repo_list}"
count="$(wc -l < "${repo_list}" | tr -d '[:space:]')"
if [ "${count}" = "0" ]; then
  echo "[restic-rotate] no initialized repositories found under ${base}"
  exit 0
fi

echo "[restic-rotate] phase=${PHASE} repositories=${count}"

while IFS= read -r cfg; do
  [ -n "${cfg}" ] || continue
  repo="$(dirname "${cfg}")"
  export RESTIC_REPOSITORY="${repo}"

  case "${PHASE}" in
    prepare)
      export RESTIC_PASSWORD="${OLD_PASSWORD}"
      restic unlock --remove-all >/dev/null 2>&1 || true
      restic cat config >/dev/null

      if RESTIC_PASSWORD="${NEW_PASSWORD}" restic cat config >/dev/null 2>&1; then
        echo "[restic-rotate] prepare repo=${repo} candidate already valid; skipping add"
        continue
      fi

      old_key_id="$(restic key list | awk '$1 ~ /^\*/ { print substr($1,2); exit }')"
      if [ -z "${old_key_id}" ]; then
        echo "[restic-rotate] prepare repo=${repo} failed: unable to resolve current key id" >&2
        exit 1
      fi

      pw_file="/tmp/new-password.$$"
      printf '%s' "${NEW_PASSWORD}" > "${pw_file}"
      restic key add --new-password-file "${pw_file}" >/dev/null
      rm -f "${pw_file}"

      RESTIC_PASSWORD="${NEW_PASSWORD}" restic cat config >/dev/null
      echo "[restic-rotate] prepare repo=${repo} added candidate key"
      ;;

    promote)
      if ! RESTIC_PASSWORD="${NEW_PASSWORD}" restic cat config >/dev/null 2>&1; then
        echo "[restic-rotate] promote repo=${repo} failed: candidate password cannot unlock repo" >&2
        exit 1
      fi

      if ! RESTIC_PASSWORD="${OLD_PASSWORD}" restic cat config >/dev/null 2>&1; then
        echo "[restic-rotate] promote repo=${repo} old password already invalid; skipping remove"
        continue
      fi

      export RESTIC_PASSWORD="${OLD_PASSWORD}"
      old_key_id="$(restic key list | awk '$1 ~ /^\*/ { print substr($1,2); exit }')"
      if [ -z "${old_key_id}" ]; then
        echo "[restic-rotate] promote repo=${repo} failed: unable to resolve old key id" >&2
        exit 1
      fi

      RESTIC_PASSWORD="${NEW_PASSWORD}" restic key remove "${old_key_id}" >/dev/null
      if RESTIC_PASSWORD="${OLD_PASSWORD}" restic cat config >/dev/null 2>&1; then
        echo "[restic-rotate] promote repo=${repo} failed: old password still unlocks repo after key removal" >&2
        exit 1
      fi
      RESTIC_PASSWORD="${NEW_PASSWORD}" restic cat config >/dev/null
      echo "[restic-rotate] promote repo=${repo} removed old key=${old_key_id}"
      ;;

    *)
      echo "[restic-rotate] unsupported phase: ${PHASE}" >&2
      exit 1
      ;;
  esac
done < "${repo_list}"
EOF
}

read_secret_key() {
  local secret_name="$1"
  local key="$2"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" get secret "${secret_name}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

wait_for_secret_sync() {
  local expected_active="$1"
  local expected_candidate="$2"
  local expected_version="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping ESO sync wait"
    return 0
  fi

  local start now elapsed
  start="$(date +%s)"

  while true; do
    local active_json recovery_json
    active_json="$(read_secret_key backup-system-pvc-restic RESTIC_PASSWORD)"
    recovery_json="$(read_secret_key backup-recovery-material RESTIC_PASSWORDS_JSON)"

    if [[ "${active_json}" == "${expected_active}" ]] && [[ -n "${recovery_json}" ]]; then
      if printf '%s' "${recovery_json}" | jq -e \
        --arg active "${expected_active}" \
        --arg candidate "${expected_candidate}" \
        --arg version "${expected_version}" \
        '.backupSystemPvcRestic.active == $active and .backupSystemPvcRestic.candidate == $candidate and .backupSystemPvcRestic.passwordVersion == $version' >/dev/null 2>&1; then
        return 0
      fi
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${SYNC_TIMEOUT_SECONDS}" ]]; then
      log_error "timed out waiting for ESO sync (secrets backup-system-pvc-restic / backup-recovery-material)"
      exit 1
    fi
    sleep 5
  done
}

patch_vault_prepare() {
  local candidate="$1"
  local prepared_at="$2"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping Vault patch for prepare"
    return 0
  fi

  vault_exec env \
    DK_VAULT_PATH="${VAULT_KV_PATH}" \
    DK_CANDIDATE="${candidate}" \
    DK_VERSION="${PASSWORD_VERSION}" \
    DK_ROTATED_AT="${PASSWORD_ROTATED_AT}" \
    DK_PREPARED_AT="${prepared_at}" \
    sh -c '
set -eu
vault kv patch "${DK_VAULT_PATH}" \
  RESTIC_PASSWORD_CANDIDATE="${DK_CANDIDATE}" \
  PASSWORD_VERSION="${DK_VERSION}" \
  PASSWORD_ROTATED_AT="${DK_ROTATED_AT}" \
  PASSWORD_PREPARED_AT="${DK_PREPARED_AT}" >/dev/null
'
}

patch_vault_promote() {
  local active="$1"
  local version="$2"
  local rotated_at="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping Vault patch for promote"
    return 0
  fi

  vault_exec env \
    DK_VAULT_PATH="${VAULT_KV_PATH}" \
    DK_ACTIVE="${active}" \
    DK_VERSION="${version}" \
    DK_ROTATED_AT="${rotated_at}" \
    sh -c '
set -eu
vault kv patch "${DK_VAULT_PATH}" \
  RESTIC_PASSWORD="${DK_ACTIVE}" \
  RESTIC_PASSWORD_CANDIDATE="" \
  PASSWORD_VERSION="${DK_VERSION}" \
  PASSWORD_ROTATED_AT="${DK_ROTATED_AT}" >/dev/null
'
}

run_prepare() {
  local candidate prepared_at

  read_vault_state
  candidate="${PREPARE_CANDIDATE_PASSWORD}"
  if [[ -z "${candidate}" ]]; then
    candidate="${CANDIDATE_PASSWORD}"
  fi
  if [[ -z "${candidate}" ]]; then
    candidate="$(openssl rand -base64 32 | tr -d '\n')"
  fi

  if [[ "${candidate}" == "${ACTIVE_PASSWORD}" ]]; then
    log_error "candidate password must differ from active RESTIC_PASSWORD"
    exit 1
  fi

  suspend_backup_cronjob
  create_rotation_pod
  run_repo_rotation "prepare" "${ACTIVE_PASSWORD}" "${candidate}"

  prepared_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  patch_vault_prepare "${candidate}" "${prepared_at}"
  wait_for_secret_sync "${ACTIVE_PASSWORD}" "${candidate}" "${PASSWORD_VERSION}"

  log_success "prepare phase completed"
  log "candidate key staged in Vault: ${VAULT_KV_PATH} (RESTIC_PASSWORD_CANDIDATE)"
  log "next step: run restore validation, then execute:"
  printf '  %s\n' "./scripts/ops/rotate-pvc-restic-password.sh promote --kubeconfig ${KUBECONFIG}"
}

run_promote() {
  local next_version rotated_at

  read_vault_state
  if [[ -z "${CANDIDATE_PASSWORD}" ]]; then
    log_error "RESTIC_PASSWORD_CANDIDATE is empty in ${VAULT_KV_PATH}; run prepare first"
    exit 1
  fi

  next_version="$((PASSWORD_VERSION + 1))"
  rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  suspend_backup_cronjob
  create_rotation_pod
  run_repo_rotation "promote" "${ACTIVE_PASSWORD}" "${CANDIDATE_PASSWORD}"

  patch_vault_promote "${CANDIDATE_PASSWORD}" "${next_version}" "${rotated_at}"
  wait_for_secret_sync "${CANDIDATE_PASSWORD}" "" "${next_version}"

  log_success "promote phase completed"
  log "active RESTIC_PASSWORD updated in Vault path ${VAULT_KV_PATH} (version=${next_version})"
}

main() {
  parse_args "$@"
  ensure_prereqs
  ensure_vault_access

  log "phase: ${PHASE}"
  log "deployment id: ${DEPLOYMENT_ID}"
  log "vault path: ${VAULT_KV_PATH}"

  case "${PHASE}" in
    prepare) run_prepare ;;
    promote) run_promote ;;
    *)
      log_error "unsupported phase: ${PHASE}"
      exit 1
      ;;
  esac
}

main "$@"
