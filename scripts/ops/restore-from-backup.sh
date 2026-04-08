#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-prod}"
DEPLOYMENT_ID="${DEPLOYMENT_ID:-proxmox-talos}"
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-backup-system}"
BACKUP_PVC="${BACKUP_PVC:-backup-target}"
SET_ID="${SET_ID:-latest}"
AGE_KEY_FILE="${AGE_KEY_FILE:-}"

RESTORE_VAULT="${RESTORE_VAULT:-true}"
RESTORE_POSTGRES="${RESTORE_POSTGRES:-true}"
POSTGRES_TARGETS="${POSTGRES_TARGETS:-keycloak,powerdns,forgejo}"
RESTORE_S3="${RESTORE_S3:-true}"
RESTORE_TENANT_S3="${RESTORE_TENANT_S3:-false}"
RUN_BACKUP_SMOKES="${RUN_BACKUP_SMOKES:-true}"
WRITE_FULL_RESTORE_MARKER="${WRITE_FULL_RESTORE_MARKER:-true}"
WRITE_FULL_RESTORE_EVIDENCE_NOTE="${WRITE_FULL_RESTORE_EVIDENCE_NOTE:-true}"
FULL_RESTORE_EVIDENCE_OUTPUT="${FULL_RESTORE_EVIDENCE_OUTPUT:-}"
PAUSE_AUTOSYNC="${PAUSE_AUTOSYNC:-true}"
RESUME_AUTOSYNC="${RESUME_AUTOSYNC:-true}"
WAIT_FOR_PLATFORM_APPS="${WAIT_FOR_PLATFORM_APPS:-true}"
DRY_RUN="${DRY_RUN:-false}"

BACKUP_ACCESS_POD=""
WORK_DIR=""
RESOLVED_SET_ID=""
SET_MANIFEST_SHA256=""
FULL_RESTORE_MARKER_RESTORED_AT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[restore]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[restore]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[restore]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[restore]${NC} %s\n" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: ./scripts/ops/restore-from-backup.sh [options]

Restores currently implemented backup tiers (Vault raft snapshot, Postgres tier-0 dumps, S3 mirror)
from a backup set and keeps GitOps safe by pausing platform-apps auto-sync during restore.

Options:
  --deployment-id <id>            Deployment id (default: proxmox-talos)
  --kubeconfig <path>             Kubeconfig path (default: tmp/kubeconfig-prod)
  --set-id <id|latest>            Backup set id or "latest" (default: latest)
  --age-key-file <path>           Age identity file for decrypting tier-0 artifacts
  --backup-namespace <ns>         Namespace with backup-target PVC (default: backup-system)
  --backup-pvc <name>             Backup target PVC name (default: backup-target)

  --restore-vault <true|false>    Restore Vault from set tier0/vault-core (default: true)
  --restore-postgres <true|false> Restore Postgres tier-0 dumps (default: true)
  --postgres-targets <csv>        Postgres targets: keycloak,powerdns,forgejo (default: all)
  --restore-s3 <true|false>       Restore S3 buckets based on DeploymentConfig backup.s3Mirror.mode:
                                   - mode=s3-replication: restore from DR S3 replica endpoint back into primary S3
                                   - mode=filesystem: restore from NFS-stored mirror payload (legacy)
                                 (default: true)
  --restore-tenant-s3 <true|false> Also restore tenant mirrored buckets (default: false)

  --pause-autosync <true|false>   Pause platform-apps auto-sync before restore (default: true)
  --resume-autosync <true|false>  Re-enable platform-apps auto-sync after restore (default: true)
  --wait-platform-apps <true|false> Wait for platform-apps Synced/Healthy after resume (default: true)

  --run-backup-smokes <true|false> Run backup-plane smokes after restore (default: true)
  --write-full-restore-marker <true|false> Write signals/FULL_RESTORE_OK.json (default: true)
  --write-full-restore-evidence-note <true|false> Write docs/evidence full-restore note (default: true)
  --full-restore-evidence-output <path> Output path for evidence note (default: docs/evidence/<date>-full-restore-drill-<deploymentId>-<setId>.md)

  --dry-run                       Print actions without executing mutating commands
  -h, --help                      Show this help

Examples:
  ./scripts/ops/restore-from-backup.sh \
    --set-id latest \
    --age-key-file ~/.config/deploykube/deployments/proxmox-talos/sops/age.key

  ./scripts/ops/restore-from-backup.sh \
    --set-id 20260215T111500Z-3bc56e270c02 \
    --restore-tenant-s3 true
EOF
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    log_error "missing dependency: ${cmd}"
    exit 1
  }
}

parse_bool() {
  local v="${1:-}"
  case "${v}" in
    true|false) printf '%s' "${v}" ;;
    *)
      log_error "expected boolean true|false, got: ${v}"
      exit 1
      ;;
  esac
}

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

cleanup() {
  local rc=$?
  if [[ -n "${BACKUP_ACCESS_POD}" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" delete pod "${BACKUP_ACCESS_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

backup_exec() {
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" exec "${BACKUP_ACCESS_POD}" -- "$@"
}

backup_cp_from() {
  local src="$1"
  local dst="$2"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" cp "${BACKUP_ACCESS_POD}:${src}" "${dst}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
      --kubeconfig) KUBECONFIG="$2"; shift 2 ;;
      --set-id) SET_ID="$2"; shift 2 ;;
      --age-key-file) AGE_KEY_FILE="$2"; shift 2 ;;
      --backup-namespace) BACKUP_NAMESPACE="$2"; shift 2 ;;
      --backup-pvc) BACKUP_PVC="$2"; shift 2 ;;
      --restore-vault) RESTORE_VAULT="$(parse_bool "$2")"; shift 2 ;;
      --restore-postgres) RESTORE_POSTGRES="$(parse_bool "$2")"; shift 2 ;;
      --postgres-targets) POSTGRES_TARGETS="$2"; shift 2 ;;
      --restore-s3) RESTORE_S3="$(parse_bool "$2")"; shift 2 ;;
      --restore-tenant-s3) RESTORE_TENANT_S3="$(parse_bool "$2")"; shift 2 ;;
      --pause-autosync) PAUSE_AUTOSYNC="$(parse_bool "$2")"; shift 2 ;;
      --resume-autosync) RESUME_AUTOSYNC="$(parse_bool "$2")"; shift 2 ;;
      --wait-platform-apps) WAIT_FOR_PLATFORM_APPS="$(parse_bool "$2")"; shift 2 ;;
      --run-backup-smokes) RUN_BACKUP_SMOKES="$(parse_bool "$2")"; shift 2 ;;
      --write-full-restore-marker) WRITE_FULL_RESTORE_MARKER="$(parse_bool "$2")"; shift 2 ;;
      --write-full-restore-evidence-note) WRITE_FULL_RESTORE_EVIDENCE_NOTE="$(parse_bool "$2")"; shift 2 ;;
      --full-restore-evidence-output) FULL_RESTORE_EVIDENCE_OUTPUT="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift 1 ;;
      -h|--help) usage; exit 0 ;;
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
  require_cmd jq
  require_cmd age
  require_cmd gunzip
  require_cmd gzip
  require_cmd mktemp
  require_cmd date

  if [[ ! -f "${KUBECONFIG}" ]]; then
    log_error "kubeconfig not found: ${KUBECONFIG}"
    exit 1
  fi
  if [[ "${RESTORE_VAULT}" == "true" || "${RESTORE_POSTGRES}" == "true" ]]; then
    if [[ -z "${AGE_KEY_FILE}" ]]; then
      log_error "--age-key-file is required when Vault or Postgres restore is enabled"
      exit 1
    fi
    if [[ ! -f "${AGE_KEY_FILE}" ]]; then
      log_error "Age key file not found: ${AGE_KEY_FILE}"
      exit 1
    fi
  fi

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploykube-restore-XXXXXX")"
  log "working directory: ${WORK_DIR}"
}

create_backup_access_pod() {
  BACKUP_ACCESS_POD="restore-backup-access-$(date -u +%Y%m%d%H%M%S)"
  log "creating backup access pod ${BACKUP_NAMESPACE}/${BACKUP_ACCESS_POD}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping backup access pod creation"
    return 0
  fi
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${BACKUP_ACCESS_POD}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
    - name: access
      image: registry.example.internal/deploykube/bootstrap-tools:1.4
      imagePullPolicy: IfNotPresent
      command: ["sh","-lc","sleep infinity"]
      volumeMounts:
        - name: backup
          mountPath: /backup
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: ${BACKUP_PVC}
EOF
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" wait --for=condition=Ready "pod/${BACKUP_ACCESS_POD}" --timeout=180s
}

resolve_set_id() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    RESOLVED_SET_ID="${SET_ID}"
    [[ "${RESOLVED_SET_ID}" == "latest" ]] && RESOLVED_SET_ID="<latest-set-id>"
    SET_MANIFEST_SHA256="<manifest-sha256>"
    log "dry-run: resolved set id ${RESOLVED_SET_ID}"
    return 0
  fi

  if [[ "${SET_ID}" == "latest" ]]; then
    local latest_json
    latest_json="$(backup_exec sh -lc "cat /backup/${DEPLOYMENT_ID}/LATEST.json")"
    RESOLVED_SET_ID="$(printf '%s' "${latest_json}" | jq -r '.backupSetId // empty')"
    if [[ -z "${RESOLVED_SET_ID}" ]]; then
      log_error "failed to resolve backup set id from /backup/${DEPLOYMENT_ID}/LATEST.json"
      exit 1
    fi
  else
    RESOLVED_SET_ID="${SET_ID}"
  fi

  local manifest="/backup/${DEPLOYMENT_ID}/sets/${RESOLVED_SET_ID}/manifest.json"
  backup_exec test -f "${manifest}"
  SET_MANIFEST_SHA256="$(backup_exec sh -lc "sha256sum '${manifest}' | awk '{print \$1}'")"
  if [[ -z "${SET_MANIFEST_SHA256}" ]]; then
    log_error "failed to compute manifest sha for set ${RESOLVED_SET_ID}"
    exit 1
  fi
  log_success "resolved set id: ${RESOLVED_SET_ID} (manifest sha: ${SET_MANIFEST_SHA256})"
}

pause_platform_autosync() {
  [[ "${PAUSE_AUTOSYNC}" == "true" ]] || return 0
  log "pausing Argo CD auto-sync for argocd/platform-apps"
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n argocd patch application platform-apps --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite
}

resume_platform_autosync() {
  [[ "${RESUME_AUTOSYNC}" == "true" ]] || return 0
  log "re-enabling Argo CD auto-sync for argocd/platform-apps"
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n argocd patch application platform-apps --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite

  if [[ "${WAIT_FOR_PLATFORM_APPS}" != "true" ]]; then
    return 0
  fi

  log "waiting for argocd/platform-apps Synced/Healthy"
  local attempts=0
  while [[ "${attempts}" -lt 120 ]]; do
    local sync health
    sync="$(kubectl --kubeconfig "${KUBECONFIG}" -n argocd get application platform-apps -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl --kubeconfig "${KUBECONFIG}" -n argocd get application platform-apps -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
      log_success "argocd/platform-apps is Synced/Healthy"
      return 0
    fi
    sleep 10
    attempts=$((attempts + 1))
  done
  log_error "timed out waiting for argocd/platform-apps to become Synced/Healthy"
  exit 1
}

copy_set_artifact_to_local() {
  local rel_dir="$1"
  local out_prefix="$2"
  local marker="/backup/${DEPLOYMENT_ID}/sets/${RESOLVED_SET_ID}/${rel_dir}/LATEST.json"
  local marker_local="${WORK_DIR}/${out_prefix}-LATEST.json"
  local artifact_name artifact_path enc_local dec_local

  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s\n' "${WORK_DIR}/${out_prefix}.age|${WORK_DIR}/${out_prefix}"
    return 0
  fi

  backup_cp_from "${marker}" "${marker_local}"
  artifact_name="$(jq -r '.artifacts[0] // empty' "${marker_local}")"
  if [[ -z "${artifact_name}" ]]; then
    log_error "marker has no artifacts[0]: ${marker}"
    exit 1
  fi
  artifact_path="/backup/${DEPLOYMENT_ID}/sets/${RESOLVED_SET_ID}/${rel_dir}/${artifact_name}"
  enc_local="${WORK_DIR}/${out_prefix}.age"
  dec_local="${WORK_DIR}/${out_prefix}"
  backup_cp_from "${artifact_path}" "${enc_local}"
  printf '%s\n' "${enc_local}|${dec_local}"
}

restore_vault() {
  [[ "${RESTORE_VAULT}" == "true" ]] || return 0
  log "restoring Vault from set ${RESOLVED_SET_ID}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping Vault restore execution"
    return 0
  fi

  local paths enc_path dec_path
  paths="$(copy_set_artifact_to_local "tier0/vault-core" "vault-core")"
  enc_path="${paths%%|*}"
  dec_path="${paths##*|}"

  age -d -i "${AGE_KEY_FILE}" -o "${dec_path}" "${enc_path}"

  local replicas
  replicas="$(kubectl --kubeconfig "${KUBECONFIG}" -n vault-system get statefulset vault -o jsonpath='{.spec.replicas}')"
  [[ -n "${replicas}" ]] || replicas="3"
  log "vault replicas before restore: ${replicas}"

  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system scale statefulset vault --replicas=0
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system scale statefulset vault --replicas=1
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system wait --for=condition=Ready pod/vault-0 --timeout=300s

  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system cp "${dec_path}" vault-0:/tmp/vault-core.snap
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system exec vault-0 -- sh -lc "vault operator raft snapshot restore -force /tmp/vault-core.snap"

  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system scale statefulset vault --replicas="${replicas}"
  run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n vault-system rollout status statefulset/vault --timeout=600s
  log_success "Vault restore complete"
}

postgres_target_conf() {
  local target="$1"
  case "${target}" in
    keycloak)
      cat <<'EOF'
ns=keycloak
tier=keycloak
pghost=keycloak-postgres-rw.keycloak.svc.cluster.local
app_secret=keycloak-db
super_secret=keycloak-postgres-superuser
sslmode=require
ssl_root_cert=
ssl_root_secret=
EOF
      ;;
    powerdns)
      cat <<'EOF'
ns=dns-system
tier=powerdns
pghost=postgres-rw.dns-system.svc.cluster.local
app_secret=powerdns-postgres-app
super_secret=powerdns-postgres-superuser
sslmode=verify-full
ssl_root_cert=/etc/postgres/ca/ca.crt
ssl_root_secret=postgres-ca
EOF
      ;;
    forgejo)
      cat <<'EOF'
ns=forgejo
tier=forgejo
pghost=postgres-rw.forgejo.svc.cluster.local
app_secret=forgejo-postgres-app
super_secret=forgejo-postgres-superuser
sslmode=require
ssl_root_cert=
ssl_root_secret=
EOF
      ;;
    *)
      log_error "unknown postgres target: ${target}"
      exit 1
      ;;
  esac
}

restore_one_postgres_target() {
  local target="$1"
  local conf
  conf="$(postgres_target_conf "${target}")"
  eval "${conf}"

  log "restoring Postgres target ${target} (namespace=${ns})"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping Postgres restore for ${target}"
    return 0
  fi

  local paths enc_path dec_path sql_path
  paths="$(copy_set_artifact_to_local "tier0/postgres/${tier}" "postgres-${target}")"
  enc_path="${paths%%|*}"
  dec_path="${paths##*|}"
  sql_path="${dec_path}.sql"

  age -d -i "${AGE_KEY_FILE}" "${enc_path}" | gunzip > "${sql_path}"

  local pod="postgres-restore-runner-${target}-$(date -u +%Y%m%d%H%M%S)"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
    - name: runner
      image: registry.example.internal/deploykube/bootstrap-tools:1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      env:
        - name: PGHOST
          value: ${pghost}
        - name: PGPORT
          value: "5432"
        - name: PGDATABASE
          valueFrom:
            secretKeyRef:
              name: ${app_secret}
              key: database
        - name: PGSSLMODE
          value: ${sslmode}
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: ${super_secret}
              key: username
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: ${super_secret}
              key: password
$(if [[ -n "${ssl_root_cert}" ]]; then
cat <<EOF2
        - name: PGSSLROOTCERT
          value: ${ssl_root_cert}
EOF2
fi)
      volumeMounts:
$(if [[ -n "${ssl_root_secret}" ]]; then
cat <<'EOF2'
        - name: postgres-ca
          mountPath: /etc/postgres/ca
          readOnly: true
EOF2
fi)
  volumes:
$(if [[ -n "${ssl_root_secret}" ]]; then
cat <<EOF2
    - name: postgres-ca
      secret:
        secretName: ${ssl_root_secret}
        defaultMode: 0444
EOF2
fi)
EOF
  kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" wait --for=condition=Ready "pod/${pod}" --timeout=180s
  cat "${sql_path}" | kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" exec -i "pod/${pod}" -- psql -v ON_ERROR_STOP=1
  kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" delete pod "${pod}" --wait=true
  rm -f "${sql_path}"
  log_success "Postgres restore complete for ${target}"
}

restore_postgres() {
  [[ "${RESTORE_POSTGRES}" == "true" ]] || return 0
  IFS=',' read -r -a targets <<<"${POSTGRES_TARGETS}"
  for t in "${targets[@]}"; do
    local target
    target="$(printf '%s' "${t}" | xargs)"
    [[ -n "${target}" ]] || continue
    restore_one_postgres_target "${target}"
  done
}

restore_s3() {
  [[ "${RESTORE_S3}" == "true" ]] || return 0

  local mirror_mode
  mirror_mode="$(kubectl --kubeconfig "${KUBECONFIG}" get deploymentconfig "${DEPLOYMENT_ID}" -o json | jq -r '.spec.backup.s3Mirror.mode // "filesystem"')"
  if [[ "${mirror_mode}" == "s3-replication" ]]; then
    log "restoring S3 buckets from DR replica endpoint (mode=s3-replication)"

    local dep_json replica_endpoint replica_region replica_bucket replica_prefix replica_bucket_prefix
    dep_json="$(kubectl --kubeconfig "${KUBECONFIG}" get deploymentconfig "${DEPLOYMENT_ID}" -o json)"
    replica_endpoint="$(printf '%s' "${dep_json}" | jq -r '.spec.backup.s3Mirror.replication.destination.endpoint // ""')"
    replica_region="$(printf '%s' "${dep_json}" | jq -r '.spec.backup.s3Mirror.replication.destination.region // ""')"
    replica_bucket="$(printf '%s' "${dep_json}" | jq -r '.spec.backup.s3Mirror.replication.destination.bucket // ""')"
    replica_prefix="$(printf '%s' "${dep_json}" | jq -r '.spec.backup.s3Mirror.replication.destination.prefix // ""')"
    replica_bucket_prefix="$(printf '%s' "${dep_json}" | jq -r '.spec.backup.s3Mirror.replication.destination.bucketPrefix // ""')"

    if [[ -z "${replica_endpoint}" || -z "${replica_region}" ]]; then
      log_error "missing required destination config for s3-replication (endpoint/region)"
      exit 1
    fi
    if [[ -z "${replica_bucket}" && -z "${replica_bucket_prefix}" ]]; then
      log_error "missing destination.bucket (preferred) or destination.bucketPrefix (legacy) for s3-replication"
      exit 1
    fi

    local job="storage-s3-restore-from-dr-$(date -u +%Y%m%d%H%M%S)"
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_warn "dry-run: skipping S3 replication restore job creation"
      return 0
    fi

    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 18000
  ttlSecondsAfterFinished: 21600
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: registry.example.internal/deploykube/bootstrap-tools:1.4
          imagePullPolicy: IfNotPresent
          env:
            - name: DEPLOYMENT_ID
              value: ${DEPLOYMENT_ID}
            - name: RESTORE_TENANT_S3
              value: "${RESTORE_TENANT_S3}"
            - name: REPLICA_ENDPOINT
              value: ${replica_endpoint}
            - name: REPLICA_REGION
              value: ${replica_region}
            - name: REPLICA_BUCKET
              value: ${replica_bucket}
            - name: REPLICA_PREFIX
              value: ${replica_prefix}
            - name: REPLICA_BUCKET_PREFIX
              value: ${replica_bucket_prefix}
            - name: RCLONE_CONFIG_REMOTE_TYPE
              value: s3
            - name: RCLONE_CONFIG_REMOTE_PROVIDER
              value: Other
            - name: RCLONE_CONFIG_REMOTE_ENV_AUTH
              value: "false"
            - name: RCLONE_CONFIG_REMOTE_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_ACCESS_KEY
            - name: RCLONE_CONFIG_REMOTE_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_SECRET_KEY
            - name: RCLONE_CONFIG_REMOTE_REGION
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_REGION
            - name: RCLONE_CONFIG_REMOTE_ENDPOINT
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_ENDPOINT
            - name: BUCKET_BACKUPS
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: BUCKET_BACKUPS
                  optional: true
            - name: REPLICA_S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: backup-system-s3-replication-target
                  key: S3_ACCESS_KEY
            - name: REPLICA_S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: backup-system-s3-replication-target
                  key: S3_SECRET_KEY
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              command -v rclone >/dev/null 2>&1 || { echo "missing dependency: rclone" >&2; exit 1; }
              command -v sha256sum >/dev/null 2>&1 || { echo "missing dependency: sha256sum" >&2; exit 1; }
              command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }

              export RCLONE_CONFIG_REPLICA_TYPE=s3
              export RCLONE_CONFIG_REPLICA_PROVIDER=Other
              export RCLONE_CONFIG_REPLICA_ENV_AUTH=false
              export RCLONE_CONFIG_REPLICA_ACCESS_KEY_ID="${REPLICA_S3_ACCESS_KEY}"
              export RCLONE_CONFIG_REPLICA_SECRET_ACCESS_KEY="${REPLICA_S3_SECRET_KEY}"
              export RCLONE_CONFIG_REPLICA_REGION="${REPLICA_REGION}"
              export RCLONE_CONFIG_REPLICA_ENDPOINT="${REPLICA_ENDPOINT}"

              replica_prefix="${REPLICA_PREFIX:-}"
              replica_prefix="${replica_prefix#/}"
              case "${replica_prefix}" in
                ""|*/) ;;
                *) replica_prefix="${replica_prefix}/" ;;
              esac

              rclone_flags=(--checksum --stats-one-line --stats 30s)

              bucket_backups="${BUCKET_BACKUPS:-garage-backups}"
              required_buckets=("${bucket_backups}")

              src_for_bucket() {
                local bucket="$1"
                if [ -n "${REPLICA_BUCKET:-}" ]; then
                  printf '%s' "replica:${REPLICA_BUCKET}/${replica_prefix}${bucket}"
                  return 0
                fi
                printf '%s' "replica:${REPLICA_BUCKET_PREFIX}${bucket}"
              }

              restore_bucket() {
                local bucket="$1" required="$2"
                if [ -z "${bucket}" ]; then
                  [ "${required}" = "true" ] && return 1
                  return 0
                fi

                src="$(src_for_bucket "${bucket}")"
                echo "[restore-s3] syncing ${src} -> remote:${bucket} (required=${required})"
                timeout 30s rclone mkdir "remote:${bucket}" >/dev/null 2>&1 || true
                if timeout 2h rclone sync "${rclone_flags[@]}" "${src}" "remote:${bucket}"; then
                  return 0
                fi
                if [ "${required}" = "true" ]; then
                  echo "[restore-s3] ERROR: required bucket restore failed (bucket=${bucket})" >&2
                  return 1
                fi
                echo "[restore-s3] WARN: optional bucket restore failed (bucket=${bucket})" >&2
                return 0
              }

              for b in "${required_buckets[@]}"; do
                restore_bucket "${b}" "true"
              done

              if [ "${RESTORE_TENANT_S3}" = "true" ]; then
                registry="/tenant-registry/tenant-registry.yaml"
                if [ -f "${registry}" ]; then
                  bucket_for_org() {
                    local org_id="$1"
                    local prefix="tenant-"
                    local suffix="-backups"
                    local base="${prefix}${org_id}${suffix}"
                    if [ "${#base}" -le 63 ]; then
                      printf '%s' "${base}"
                      return 0
                    fi
                    local h
                    h="$(printf '%s' "${org_id}" | sha256sum | awk '{print $1}' | cut -c1-8)"
                    local max_org=$((63 - ${#prefix} - ${#suffix} - 1 - 8))
                    local org_trunc="${org_id:0:${max_org}}"
                    org_trunc="${org_trunc%-}"
                    if [ -z "${org_trunc}" ]; then
                      org_trunc="t"
                    fi
                    printf '%s' "${prefix}${org_trunc}-${h}${suffix}"
                  }

                  yq -r '.tenants[].orgId // ""' "${registry}" | while IFS= read -r org_id; do
                    [ -n "${org_id}" ] || continue
                    tenant_bucket="$(bucket_for_org "${org_id}")"
                    restore_bucket "${tenant_bucket}" "false"
                  done
                else
                  echo "[restore-s3] tenant registry not present; skipping tenant restore (${registry})"
                fi
              fi
          volumeMounts:
            - name: tenant-registry
              mountPath: /tenant-registry
              readOnly: true
      volumes:
        - name: tenant-registry
          configMap:
            name: deploykube-tenant-registry
            optional: true
            items:
              - key: tenant-registry.yaml
                path: tenant-registry.yaml
EOF

    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" wait --for=condition=complete "job/${job}" --timeout=18000s
    kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" logs "job/${job}" --tail=400
    log_success "S3 restore complete (mode=s3-replication)"
    return 0
  fi

  log "restoring S3 buckets from set ${RESOLVED_SET_ID}"

  local job="storage-s3-restore-from-set-$(date -u +%Y%m%d%H%M%S)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping S3 restore job creation"
    return 0
  fi

  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 18000
  ttlSecondsAfterFinished: 21600
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: registry.example.internal/deploykube/bootstrap-tools:1.4
          imagePullPolicy: IfNotPresent
          env:
            - name: DEPLOYMENT_ID
              value: ${DEPLOYMENT_ID}
            - name: SET_ID
              value: ${RESOLVED_SET_ID}
            - name: RESTORE_TENANT_S3
              value: "${RESTORE_TENANT_S3}"
            - name: RCLONE_CONFIG_REMOTE_TYPE
              value: s3
            - name: RCLONE_CONFIG_REMOTE_PROVIDER
              value: Other
            - name: RCLONE_CONFIG_REMOTE_ENV_AUTH
              value: "false"
            - name: RCLONE_CONFIG_REMOTE_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_ACCESS_KEY
            - name: RCLONE_CONFIG_REMOTE_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_SECRET_KEY
            - name: RCLONE_CONFIG_REMOTE_REGION
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_REGION
            - name: RCLONE_CONFIG_REMOTE_ENDPOINT
              valueFrom:
                secretKeyRef:
                  name: backup-system-garage-s3
                  key: S3_ENDPOINT
            - name: RCLONE_CRYPT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: backup-system-s3-mirror-crypt
                  key: RCLONE_CRYPT_PASSWORD
            - name: RCLONE_CRYPT_PASSWORD2
              valueFrom:
                secretKeyRef:
                  name: backup-system-s3-mirror-crypt
                  key: RCLONE_CRYPT_PASSWORD2
                  optional: true
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              command -v rclone >/dev/null 2>&1 || { echo "missing dependency: rclone" >&2; exit 1; }
              shopt -s nullglob

              set_root="/backup/${DEPLOYMENT_ID}/sets/${SET_ID}"
              mirror_root=""
              tenants_root=""
              if [ -d "${set_root}/s3-mirror/crypt" ] || [ -d "${set_root}/s3-mirror/buckets" ]; then
                mirror_root="${set_root}/s3-mirror"
                tenants_root="${set_root}/tenants"
              else
                mirror_root="/backup/${DEPLOYMENT_ID}/s3-mirror"
                tenants_root="/backup/${DEPLOYMENT_ID}/tenants"
              fi

              crypt_root="${mirror_root}/crypt"
              plain_buckets_root="${mirror_root}/buckets"

              restored=0
              if [ -d "${crypt_root}" ]; then
                [ -n "${RCLONE_CRYPT_PASSWORD:-}" ] || { echo "missing RCLONE_CRYPT_PASSWORD for encrypted S3 mirror restore" >&2; exit 1; }

                export RCLONE_CONFIG_SETCRYPT_TYPE=crypt
                export RCLONE_CONFIG_SETCRYPT_REMOTE="${crypt_root}"
                export RCLONE_CONFIG_SETCRYPT_PASSWORD
                RCLONE_CONFIG_SETCRYPT_PASSWORD="$(rclone obscure "${RCLONE_CRYPT_PASSWORD}")"
                if [ -n "${RCLONE_CRYPT_PASSWORD2:-}" ]; then
                  export RCLONE_CONFIG_SETCRYPT_PASSWORD2
                  RCLONE_CONFIG_SETCRYPT_PASSWORD2="$(rclone obscure "${RCLONE_CRYPT_PASSWORD2}")"
                else
                  unset RCLONE_CONFIG_SETCRYPT_PASSWORD2 || true
                fi

                while IFS= read -r bucket_dir; do
                  bucket="${bucket_dir%/}"
                  [ -n "${bucket}" ] || continue
                  src="setcrypt:buckets/${bucket}"
                  echo "[restore-s3] syncing ${src} -> remote:${bucket}"
                  rclone sync --checksum --stats-one-line --stats 30s "${src}" "remote:${bucket}"
                  restored=$((restored + 1))
                done < <(rclone lsf setcrypt:buckets --dirs-only 2>/dev/null || true)
              else
                if [ ! -d "${plain_buckets_root}" ]; then
                  echo "missing s3 mirror payload in set (checked: ${crypt_root}, ${plain_buckets_root})" >&2
                  exit 1
                fi
                for src in "${plain_buckets_root}"/*; do
                  [ -d "${src}" ] || continue
                  bucket="$(basename "${src}")"
                  echo "[restore-s3] syncing ${src} -> remote:${bucket}"
                  rclone sync --checksum --stats-one-line --stats 30s "${src}" "remote:${bucket}"
                  restored=$((restored + 1))
                done
              fi

              if [ "${restored}" -eq 0 ]; then
                echo "no platform buckets found under set payload" >&2
                exit 1
              fi

              if [ "${RESTORE_TENANT_S3}" = "true" ]; then
                for tenant_root in "${tenants_root}"/*/s3-mirror; do
                  [ -d "${tenant_root}" ] || continue

                  tenant_crypt_root="${tenant_root}/crypt"
                  tenant_plain_root="${tenant_root}/buckets"

                  if [ -d "${tenant_crypt_root}" ]; then
                    [ -n "${RCLONE_CRYPT_PASSWORD:-}" ] || { echo "missing RCLONE_CRYPT_PASSWORD for tenant encrypted S3 mirror restore" >&2; exit 1; }

                    export RCLONE_CONFIG_TENANTSETCRYPT_TYPE=crypt
                    export RCLONE_CONFIG_TENANTSETCRYPT_REMOTE="${tenant_crypt_root}"
                    export RCLONE_CONFIG_TENANTSETCRYPT_PASSWORD
                    RCLONE_CONFIG_TENANTSETCRYPT_PASSWORD="$(rclone obscure "${RCLONE_CRYPT_PASSWORD}")"
                    if [ -n "${RCLONE_CRYPT_PASSWORD2:-}" ]; then
                      export RCLONE_CONFIG_TENANTSETCRYPT_PASSWORD2
                      RCLONE_CONFIG_TENANTSETCRYPT_PASSWORD2="$(rclone obscure "${RCLONE_CRYPT_PASSWORD2}")"
                    else
                      unset RCLONE_CONFIG_TENANTSETCRYPT_PASSWORD2 || true
                    fi

                    while IFS= read -r bucket_dir; do
                      bucket="${bucket_dir%/}"
                      [ -n "${bucket}" ] || continue
                      src="tenantsetcrypt:buckets/${bucket}"
                      echo "[restore-s3] syncing tenant bucket ${src} -> remote:${bucket}"
                      rclone sync --checksum --stats-one-line --stats 30s "${src}" "remote:${bucket}"
                    done < <(rclone lsf tenantsetcrypt:buckets --dirs-only 2>/dev/null || true)
                    continue
                  fi

                  if [ -d "${tenant_plain_root}" ]; then
                    for src in "${tenant_plain_root}"/*; do
                      [ -d "${src}" ] || continue
                      bucket="$(basename "${src}")"
                      echo "[restore-s3] syncing tenant bucket ${src} -> remote:${bucket}"
                      rclone sync --checksum --stats-one-line --stats 30s "${src}" "remote:${bucket}"
                    done
                  fi
                done
              fi
          volumeMounts:
            - name: backup
              mountPath: /backup
      volumes:
        - name: backup
          persistentVolumeClaim:
            claimName: ${BACKUP_PVC}
EOF

  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" wait --for=condition=complete "job/${job}" --timeout=18000s
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" logs "job/${job}" --tail=400
  log_success "S3 restore complete"
}

run_backup_smokes() {
  [[ "${RUN_BACKUP_SMOKES}" == "true" ]] || return 0
  local jobs=(
    "storage-smoke-backup-target-write:600s"
    "storage-smoke-backups-freshness:600s"
    "storage-smoke-full-restore-staleness:600s"
  )

  for entry in "${jobs[@]}"; do
    local cron timeout job
    cron="${entry%%:*}"
    timeout="${entry##*:}"
    job="${cron}-manual-$(date -u +%Y%m%d%H%M%S)"
    log "running smoke: ${cron}"
    run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" create job --from="cronjob/${cron}" "${job}"
    run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" wait --for=condition=complete "job/${job}" --timeout="${timeout}"
    run_cmd kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" logs "job/${job}" --tail=200
  done
  log_success "backup-plane smokes completed"
}

write_full_restore_marker() {
  [[ "${WRITE_FULL_RESTORE_MARKER}" == "true" ]] || return 0
  log "writing FULL_RESTORE_OK marker"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping FULL_RESTORE_OK marker write"
    return 0
  fi

  local marker_local="${WORK_DIR}/FULL_RESTORE_OK.json"
  local restored_at
  restored_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  FULL_RESTORE_MARKER_RESTORED_AT="${restored_at}"
  jq -n \
    --arg deploymentId "${DEPLOYMENT_ID}" \
    --arg backupSetId "${RESOLVED_SET_ID}" \
    --arg restoredAt "${restored_at}" \
    --arg backupSetManifestSha256 "${SET_MANIFEST_SHA256}" \
    --arg result "ok" \
    '{deploymentId:$deploymentId,backupSetId:$backupSetId,restoredAt:$restoredAt,backupSetManifestSha256:$backupSetManifestSha256,result:$result}' > "${marker_local}"

  backup_cp_from "/backup/${DEPLOYMENT_ID}/sets/${RESOLVED_SET_ID}/manifest.json" "${WORK_DIR}/manifest.json" >/dev/null 2>&1 || true
  kubectl --kubeconfig "${KUBECONFIG}" -n "${BACKUP_NAMESPACE}" cp "${marker_local}" "${BACKUP_ACCESS_POD}:/tmp/FULL_RESTORE_OK.json"
  backup_exec sh -lc "mkdir -p '/backup/${DEPLOYMENT_ID}/signals' && mv /tmp/FULL_RESTORE_OK.json '/backup/${DEPLOYMENT_ID}/signals/FULL_RESTORE_OK.json'"
  log_success "FULL_RESTORE_OK marker written"
}

write_full_restore_evidence_note() {
  [[ "${WRITE_FULL_RESTORE_EVIDENCE_NOTE}" == "true" ]] || return 0

  if [[ "${WRITE_FULL_RESTORE_MARKER}" != "true" ]]; then
    log_error "full-restore evidence note requires --write-full-restore-marker true (or disable with --write-full-restore-evidence-note false)"
    exit 1
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "dry-run: skipping full-restore evidence note write"
    return 0
  fi

  if [[ -z "${FULL_RESTORE_MARKER_RESTORED_AT}" || -z "${SET_MANIFEST_SHA256}" || -z "${RESOLVED_SET_ID}" ]]; then
    log_error "missing marker metadata for evidence note generation"
    exit 1
  fi

  local day_utc safe_set output_path
  day_utc="$(printf '%s' "${FULL_RESTORE_MARKER_RESTORED_AT}" | cut -d'T' -f1)"
  safe_set="$(printf '%s' "${RESOLVED_SET_ID}" | tr '/ ' '__')"
  output_path="${FULL_RESTORE_EVIDENCE_OUTPUT:-docs/evidence/${day_utc}-full-restore-drill-${DEPLOYMENT_ID}-${safe_set}.md}"
  if [[ "${output_path}" != /* ]]; then
    output_path="${REPO_ROOT}/${output_path}"
  fi
  mkdir -p "$(dirname "${output_path}")"

  if [[ -e "${output_path}" ]]; then
    output_path="${output_path%.md}-$(date -u +%H%M%S).md"
  fi

  local git_commit argo_sync_health argo_revision
  git_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "${git_commit}" ]] || git_commit="N/A"

  argo_sync_health="$(kubectl --kubeconfig "${KUBECONFIG}" -n argocd get application platform-apps -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true)"
  [[ -n "${argo_sync_health}" ]] || argo_sync_health="N/A"
  argo_revision="$(kubectl --kubeconfig "${KUBECONFIG}" -n argocd get application platform-apps -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  [[ -n "${argo_revision}" ]] || argo_revision="N/A"

  cat > "${output_path}" <<EOF
# Evidence: Full restore drill (${DEPLOYMENT_ID}, ${RESOLVED_SET_ID})

EvidenceFormat: v1
EvidenceType: full-restore-drill-v1

Date: ${day_utc}
Environment: ${DEPLOYMENT_ID}
FullRestoreDeploymentId: ${DEPLOYMENT_ID}
FullRestoreBackupSetId: ${RESOLVED_SET_ID}
FullRestoreRestoredAt: ${FULL_RESTORE_MARKER_RESTORED_AT}
FullRestoreBackupSetManifestSha256: ${SET_MANIFEST_SHA256}

Scope / ground truth:
- ${DEPLOYMENT_ID} full-restore drill result and marker-binding evidence from scripts/ops/restore-from-backup.sh

Git:
- Commit: ${git_commit}

Argo:
- Root app: platform-apps
- Sync/Health: ${argo_sync_health}
- Revision: ${argo_revision}

## What changed

- Restored backup set \`${RESOLVED_SET_ID}\` for deployment \`${DEPLOYMENT_ID}\` using the restore entrypoint.
- Wrote \`signals/FULL_RESTORE_OK.json\` bound to \`manifest.json\` SHA \`${SET_MANIFEST_SHA256}\`.
- Captured this evidence note via the restore script’s built-in evidence writer.

## Commands / outputs

\`\`\`bash
./scripts/ops/restore-from-backup.sh --set-id ${RESOLVED_SET_ID}
./tests/scripts/validate-full-restore-evidence-policy.sh
\`\`\`

Output:

\`\`\`text
FULL_RESTORE_OK marker written for deployment=${DEPLOYMENT_ID}
backupSetId=${RESOLVED_SET_ID}
restoredAt=${FULL_RESTORE_MARKER_RESTORED_AT}
backupSetManifestSha256=${SET_MANIFEST_SHA256}
\`\`\`
EOF

  log_success "full-restore evidence note written: ${output_path#${REPO_ROOT}/}"
}

main() {
  parse_args "$@"
  ensure_prereqs
  log "using kubeconfig: ${KUBECONFIG}"
  log "deployment id: ${DEPLOYMENT_ID}"
  create_backup_access_pod
  resolve_set_id

  pause_platform_autosync
  restore_vault
  restore_postgres
  restore_s3
  run_backup_smokes
  write_full_restore_marker
  resume_platform_autosync
  write_full_restore_evidence_note

  log_success "restore flow complete for set ${RESOLVED_SET_ID}"
}

main "$@"
