#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-prod}"
DEPLOYMENT_ID="${DEPLOYMENT_ID:-proxmox-talos}"
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-backup-system}"
BACKUP_PVC="${BACKUP_PVC:-backup-target}"
BACKUP_CRONJOB="${BACKUP_CRONJOB:-storage-pvc-restic-backup}"
SMOKE_CRONJOB="${SMOKE_CRONJOB:-storage-smoke-pvc-restic-credentials}"
MIGRATION_IMAGE="${MIGRATION_IMAGE:-}"
OWNER_UID="${OWNER_UID:-65532}"
OWNER_GID="${OWNER_GID:-65532}"
DRY_RUN="false"

MIGRATION_POD=""
BACKUP_CRON_RESUME_REQUIRED="false"
SMOKE_CRON_RESUME_REQUIRED="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[restic-perms]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[restic-perms]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[restic-perms]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[restic-perms]${NC} %s\n" "$1" >&2; }

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/ops/migrate-pvc-restic-repo-permissions.sh [options]

Migrate platform PVC restic repo ownership/modes so backup and smoke jobs can run with runAsNonRoot.

Options:
  --kubeconfig <path>        Kubeconfig path (default: tmp/kubeconfig-prod)
  --deployment-id <id>       Deployment id (default: proxmox-talos)
  --backup-namespace <ns>    Backup namespace (default: backup-system)
  --backup-pvc <name>        Backup target PVC name (default: backup-target)
  --backup-cronjob <name>    Backup CronJob name (default: storage-pvc-restic-backup)
  --smoke-cronjob <name>     Credential smoke CronJob name (default: storage-smoke-pvc-restic-credentials)
  --migration-image <image>  Image used for migration pod (default: image from backup CronJob)
  --owner-uid <uid>          Target UID owner for pvc-restic tree (default: 65532)
  --owner-gid <gid>          Target GID owner for pvc-restic tree (default: 65532)
  --dry-run                  Print actions without mutating state
  -h, --help                 Show help

Example:
  KUBECONFIG=tmp/kubeconfig-prod \
  ./scripts/ops/migrate-pvc-restic-repo-permissions.sh
USAGE
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    log_error "missing dependency: ${cmd}"
    exit 1
  }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) KUBECONFIG="$2"; shift 2 ;;
      --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
      --backup-namespace) BACKUP_NAMESPACE="$2"; shift 2 ;;
      --backup-pvc) BACKUP_PVC="$2"; shift 2 ;;
      --backup-cronjob) BACKUP_CRONJOB="$2"; shift 2 ;;
      --smoke-cronjob) SMOKE_CRONJOB="$2"; shift 2 ;;
      --migration-image) MIGRATION_IMAGE="$2"; shift 2 ;;
      --owner-uid) OWNER_UID="$2"; shift 2 ;;
      --owner-gid) OWNER_GID="$2"; shift 2 ;;
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
}

ensure_prereqs() {
  require_cmd kubectl

  if [[ ! -f "${KUBECONFIG}" ]]; then
    log_error "kubeconfig not found: ${KUBECONFIG}"
    exit 1
  fi

  if ! [[ "${OWNER_UID}" =~ ^[0-9]+$ ]] || ! [[ "${OWNER_GID}" =~ ^[0-9]+$ ]]; then
    log_error "--owner-uid and --owner-gid must be numeric"
    exit 1
  fi
}

resolve_migration_image() {
  if [[ -n "${MIGRATION_IMAGE}" ]]; then
    return 0
  fi

  MIGRATION_IMAGE="$(
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" \
      get cronjob "${BACKUP_CRONJOB}" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true
  )"

  if [[ -z "${MIGRATION_IMAGE}" ]]; then
    MIGRATION_IMAGE="registry.example.internal/deploykube/bootstrap-tools:1.4"
    log_warn "could not resolve backup CronJob image; falling back to ${MIGRATION_IMAGE}"
  fi
}

cleanup() {
  local rc=$?

  if [[ -n "${MIGRATION_POD}" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" delete pod "${MIGRATION_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  if [[ "${BACKUP_CRON_RESUME_REQUIRED}" == "true" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${BACKUP_CRONJOB}" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  fi

  if [[ "${SMOKE_CRON_RESUME_REQUIRED}" == "true" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${SMOKE_CRONJOB}" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  fi

  exit "${rc}"
}
trap cleanup EXIT

suspend_cronjob() {
  local cronjob="$1"
  local resume_flag="$2"
  local current_suspend

  current_suspend="$(kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" get cronjob "${cronjob}" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  current_suspend="${current_suspend:-false}"

  if [[ "${current_suspend}" != "true" ]]; then
    log "suspending ${BACKUP_NAMESPACE}/cronjob/${cronjob}"
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${cronjob}" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
    if [[ "${resume_flag}" == "backup" ]]; then
      BACKUP_CRON_RESUME_REQUIRED="true"
    else
      SMOKE_CRON_RESUME_REQUIRED="true"
    fi
  fi

  local active attempt
  attempt=0
  while true; do
    active="$(kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" get cronjob "${cronjob}" -o jsonpath='{range .status.active[*]}{.name}{" "}{end}' 2>/dev/null || true)"
    if [[ -z "${active}" ]]; then
      break
    fi
    attempt=$((attempt + 1))
    if [[ "${attempt}" -ge 120 ]]; then
      log_error "timed out waiting for active Jobs of ${cronjob} to finish"
      exit 1
    fi
    sleep 5
  done
}

create_migration_pod() {
  MIGRATION_POD="restic-repo-perm-migrate-$(date -u +%Y%m%d%H%M%S)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping creation of ${BACKUP_NAMESPACE}/pod/${MIGRATION_POD}"
    return 0
  fi

  log "creating migration pod ${BACKUP_NAMESPACE}/${MIGRATION_POD}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" apply -f - <<__POD__
apiVersion: v1
kind: Pod
metadata:
  name: ${MIGRATION_POD}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
    - name: migrate
      image: ${MIGRATION_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c", "sleep infinity"]
      volumeMounts:
        - name: backup
          mountPath: /backup
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: ${BACKUP_PVC}
__POD__

  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" wait --for=condition=Ready "pod/${MIGRATION_POD}" --timeout=180s >/dev/null
}

run_migration() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: would migrate /backup/${DEPLOYMENT_ID}/pvc-restic ownership to ${OWNER_UID}:${OWNER_GID}"
    return 0
  fi

  log "migrating /backup/${DEPLOYMENT_ID}/pvc-restic to ${OWNER_UID}:${OWNER_GID}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" exec -i "${MIGRATION_POD}" -- env \
    DEPLOYMENT_ID="${DEPLOYMENT_ID}" \
    OWNER_UID="${OWNER_UID}" \
    OWNER_GID="${OWNER_GID}" \
    sh -s <<'__MIGRATE__'
set -eu

base="/backup/${DEPLOYMENT_ID}/pvc-restic"
mkdir -p "${base}/namespaces"

repo_count="$(find "${base}" -type f -path '*/persistentvolumeclaims/*/repo/config' | wc -l | tr -d '[:space:]')"
echo "[restic-perms] discovered repos=${repo_count} base=${base}"

chown -R "${OWNER_UID}:${OWNER_GID}" "${base}"
find "${base}" -type d -exec chmod u+rwx,go-rwx {} +
find "${base}" -type f -exec chmod u+rw,go-rwx {} +

mismatch="$(find "${base}" \( ! -user "${OWNER_UID}" -o ! -group "${OWNER_GID}" \) | head -n 1 || true)"
if [ -n "${mismatch}" ]; then
  echo "[restic-perms] migration failed: ownership mismatch remains at ${mismatch}" >&2
  exit 1
fi

bad_dir="$(find "${base}" -type d ! -perm -700 | head -n 1 || true)"
if [ -n "${bad_dir}" ]; then
  echo "[restic-perms] migration failed: directory without owner rwx at ${bad_dir}" >&2
  exit 1
fi

bad_file="$(find "${base}" -type f ! -perm -600 | head -n 1 || true)"
if [ -n "${bad_file}" ]; then
  echo "[restic-perms] migration failed: file without owner rw at ${bad_file}" >&2
  exit 1
fi

echo "[restic-perms] sample mode/ownership after migration:"
find "${base}" -maxdepth 5 \( -type d -o -type f \) | sort | head -n 20 | while IFS= read -r p; do
  stat -c '%u:%g %a %n' "${p}"
done

echo "[restic-perms] migration completed"
__MIGRATE__
}

resume_cronjobs() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi

  if [[ "${SMOKE_CRON_RESUME_REQUIRED}" == "true" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${SMOKE_CRONJOB}" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
    SMOKE_CRON_RESUME_REQUIRED="false"
    log "resumed ${BACKUP_NAMESPACE}/cronjob/${SMOKE_CRONJOB}"
  fi

  if [[ "${BACKUP_CRON_RESUME_REQUIRED}" == "true" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" patch cronjob "${BACKUP_CRONJOB}" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
    BACKUP_CRON_RESUME_REQUIRED="false"
    log "resumed ${BACKUP_NAMESPACE}/cronjob/${BACKUP_CRONJOB}"
  fi
}

main() {
  parse_args "$@"
  ensure_prereqs
  resolve_migration_image

  log "starting PVC restic repo permission migration"
  log "target: /backup/${DEPLOYMENT_ID}/pvc-restic owner=${OWNER_UID}:${OWNER_GID}"
  log "migration image: ${MIGRATION_IMAGE}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    suspend_cronjob "${BACKUP_CRONJOB}" "backup"
    suspend_cronjob "${SMOKE_CRONJOB}" "smoke"
  else
    log_warn "dry-run: skipping CronJob suspend/resume"
  fi

  create_migration_pod
  run_migration
  resume_cronjobs

  log_success "PVC restic repo permission migration finished"
}

main "$@"
