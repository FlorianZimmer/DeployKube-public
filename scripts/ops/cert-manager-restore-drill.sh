#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_SCRIPT="${REPO_ROOT}/platform/gitops/components/certificates/step-ca/bootstrap/scripts/step-ca-root-secret-bootstrap.sh"

KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-prod}"
MODE="${MODE:-scratch}"
STEP_CA_NAMESPACE="${STEP_CA_NAMESPACE:-step-system}"
STEP_CA_FULLNAME="${STEP_CA_FULLNAME:-step-ca-step-certificates}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
STEP_CA_TLS_SECRET_NAME="${STEP_CA_TLS_SECRET_NAME:-step-ca-root-ca}"
SCRATCH_NAMESPACE="${SCRATCH_NAMESPACE:-cert-manager-restore-drill-$(date -u +%Y%m%d%H%M%S)}"
KEEP_SCRATCH_NAMESPACE="${KEEP_SCRATCH_NAMESPACE:-false}"
RUN_STEP_CA_SMOKE="${RUN_STEP_CA_SMOKE:-true}"
LIVE_SECRET_BACKUP_FILE="${LIVE_SECRET_BACKUP_FILE:-}"
CONFIRM_LIVE_SECRET_REPLACEMENT="${CONFIRM_LIVE_SECRET_REPLACEMENT:-no}"

WORK_DIR=""
STEP_CA_SMOKE_JOB=""
RESTORED_NAMESPACE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[cert-manager-restore-drill]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[cert-manager-restore-drill]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[cert-manager-restore-drill]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[cert-manager-restore-drill]${NC} %s\n" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: ./scripts/ops/cert-manager-restore-drill.sh [options]

Exercises the cert-manager Step CA root recovery path using the repo-shipped
bootstrap script and validates Step CA issuance with the in-cluster smoke CronJob.

Modes:
  scratch (default)  Reconstruct the derived TLS secret in a temporary namespace.
                     This is non-destructive and safe for routine drills.
  live               Delete and recreate cert-manager/step-ca-root-ca in place.
                     Requires --confirm-live-secret-replacement yes.

Options:
  --kubeconfig <path>                    Kubeconfig path (default: tmp/kubeconfig-prod)
  --mode <scratch|live>                  Drill mode (default: scratch)
  --step-ca-namespace <ns>               Step CA namespace (default: step-system)
  --step-ca-fullname <name>              Step CA chart fullname (default: step-ca-step-certificates)
  --cert-manager-namespace <ns>          cert-manager namespace (default: cert-manager)
  --secret-name <name>                   Derived TLS secret name (default: step-ca-root-ca)
  --scratch-namespace <ns>               Scratch namespace for scratch mode
  --keep-scratch-namespace <true|false>  Keep scratch namespace after success (default: false)
  --run-step-ca-smoke <true|false>       Run manual Step CA issuance smoke after restore (default: true)
  --live-secret-backup-file <path>       Where to write the pre-delete live Secret backup in live mode
  --confirm-live-secret-replacement yes  Required to use live mode
  -h, --help                             Show this help

Examples:
  ./scripts/ops/cert-manager-restore-drill.sh

  ./scripts/ops/cert-manager-restore-drill.sh \
    --mode scratch \
    --scratch-namespace cert-manager-restore-drill-test

  ./scripts/ops/cert-manager-restore-drill.sh \
    --mode live \
    --confirm-live-secret-replacement yes \
    --live-secret-backup-file tmp/step-ca-root-ca-before-drill.yaml
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
  local value="${1:-}"
  case "${value}" in
    true|false) printf '%s' "${value}" ;;
    *)
      log_error "expected boolean true|false, got: ${value}"
      exit 1
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) KUBECONFIG="$2"; shift 2 ;;
      --mode) MODE="$2"; shift 2 ;;
      --step-ca-namespace) STEP_CA_NAMESPACE="$2"; shift 2 ;;
      --step-ca-fullname) STEP_CA_FULLNAME="$2"; shift 2 ;;
      --cert-manager-namespace) CERT_MANAGER_NAMESPACE="$2"; shift 2 ;;
      --secret-name) STEP_CA_TLS_SECRET_NAME="$2"; shift 2 ;;
      --scratch-namespace) SCRATCH_NAMESPACE="$2"; shift 2 ;;
      --keep-scratch-namespace) KEEP_SCRATCH_NAMESPACE="$(parse_bool "$2")"; shift 2 ;;
      --run-step-ca-smoke) RUN_STEP_CA_SMOKE="$(parse_bool "$2")"; shift 2 ;;
      --live-secret-backup-file) LIVE_SECRET_BACKUP_FILE="$2"; shift 2 ;;
      --confirm-live-secret-replacement) CONFIRM_LIVE_SECRET_REPLACEMENT="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        log_error "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

cleanup() {
  local rc=$?

  if [[ -n "${STEP_CA_SMOKE_JOB}" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" delete job "${STEP_CA_SMOKE_JOB}" --ignore-not-found >/dev/null 2>&1 || true
  fi

  if [[ "${MODE}" == "scratch" && "${KEEP_SCRATCH_NAMESPACE}" == "false" && -n "${RESTORED_NAMESPACE}" ]]; then
    kubectl --kubeconfig "${KUBECONFIG}" delete namespace "${RESTORED_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  fi

  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi

  exit "${rc}"
}
trap cleanup EXIT

ensure_prereqs() {
  require_cmd kubectl
  require_cmd openssl
  require_cmd base64
  require_cmd mktemp
  require_cmd date

  if [[ ! -f "${KUBECONFIG}" ]]; then
    log_error "kubeconfig not found: ${KUBECONFIG}"
    exit 1
  fi
  if [[ ! -f "${BOOTSTRAP_SCRIPT}" ]]; then
    log_error "bootstrap script not found: ${BOOTSTRAP_SCRIPT}"
    exit 1
  fi
  case "${MODE}" in
    scratch|live) ;;
    *)
      log_error "unsupported mode: ${MODE}"
      exit 1
      ;;
  esac

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploykube-cert-manager-restore-drill-XXXXXX")"
}

kubectl_jsonpath() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local jsonpath="$4"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${namespace}" get "${kind}" "${name}" -o "jsonpath=${jsonpath}"
}

assert_source_secrets() {
  local certs_secret="${STEP_CA_FULLNAME}-certs"
  local private_keys_secret="${STEP_CA_FULLNAME}-secrets"
  local password_secret="${STEP_CA_FULLNAME}-ca-password"

  log "checking Step CA source secrets in ${STEP_CA_NAMESPACE}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${STEP_CA_NAMESPACE}" get secret "${certs_secret}" >/dev/null
  kubectl --kubeconfig "${KUBECONFIG}" -n "${STEP_CA_NAMESPACE}" get secret "${private_keys_secret}" >/dev/null
  kubectl --kubeconfig "${KUBECONFIG}" -n "${STEP_CA_NAMESPACE}" get secret "${password_secret}" >/dev/null

  [[ -n "$(kubectl_jsonpath "${STEP_CA_NAMESPACE}" secret "${certs_secret}" '{.data.root_ca\.crt}')" ]] || {
    log_error "missing root_ca.crt in Secret/${STEP_CA_NAMESPACE}/${certs_secret}"
    exit 1
  }
  [[ -n "$(kubectl_jsonpath "${STEP_CA_NAMESPACE}" secret "${private_keys_secret}" '{.data.root_ca_key}')" ]] || {
    log_error "missing root_ca_key in Secret/${STEP_CA_NAMESPACE}/${private_keys_secret}"
    exit 1
  }
  [[ -n "$(kubectl_jsonpath "${STEP_CA_NAMESPACE}" secret "${password_secret}" '{.data.password}')" ]] || {
    log_error "missing password in Secret/${STEP_CA_NAMESPACE}/${password_secret}"
    exit 1
  }
}

secret_fingerprint() {
  local namespace="$1"
  local secret_name="$2"
  local crt_path="${WORK_DIR}/${namespace}-${secret_name}.crt"

  kubectl --kubeconfig "${KUBECONFIG}" -n "${namespace}" get secret "${secret_name}" -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "${crt_path}"
  openssl x509 -in "${crt_path}" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//'
}

run_bootstrap_script() {
  local target_namespace="$1"

  CERT_MANAGER_NAMESPACE="${target_namespace}" \
  STEP_CA_NAMESPACE="${STEP_CA_NAMESPACE}" \
  STEP_CA_FULLNAME="${STEP_CA_FULLNAME}" \
  STEP_CA_TLS_SECRET_NAME="${STEP_CA_TLS_SECRET_NAME}" \
  KUBECONFIG="${KUBECONFIG}" \
    bash "${BOOTSTRAP_SCRIPT}"
}

verify_restored_secret() {
  local namespace="$1"
  local expected_fingerprint="$2"
  local restored_fingerprint=""

  kubectl --kubeconfig "${KUBECONFIG}" -n "${namespace}" get secret "${STEP_CA_TLS_SECRET_NAME}" >/dev/null
  restored_fingerprint="$(secret_fingerprint "${namespace}" "${STEP_CA_TLS_SECRET_NAME}")"
  if [[ "${restored_fingerprint}" != "${expected_fingerprint}" ]]; then
    log_error "restored fingerprint mismatch in ${namespace}/${STEP_CA_TLS_SECRET_NAME}"
    log_error "expected: ${expected_fingerprint}"
    log_error "actual:   ${restored_fingerprint}"
    exit 1
  fi
  log_success "verified restored secret fingerprint in ${namespace}/${STEP_CA_TLS_SECRET_NAME}: ${restored_fingerprint}"
}

run_scratch_restore() {
  local live_fingerprint="$1"

  RESTORED_NAMESPACE="${SCRATCH_NAMESPACE}"
  log "creating scratch namespace ${RESTORED_NAMESPACE}"
  kubectl --kubeconfig "${KUBECONFIG}" create namespace "${RESTORED_NAMESPACE}" >/dev/null 2>&1 || true

  log "reconstructing ${STEP_CA_TLS_SECRET_NAME} into scratch namespace ${RESTORED_NAMESPACE}"
  run_bootstrap_script "${RESTORED_NAMESPACE}"
  verify_restored_secret "${RESTORED_NAMESPACE}" "${live_fingerprint}"
}

run_live_restore() {
  local live_fingerprint="$1"

  if [[ "${CONFIRM_LIVE_SECRET_REPLACEMENT}" != "yes" ]]; then
    log_error "live mode requires --confirm-live-secret-replacement yes"
    exit 1
  fi

  RESTORED_NAMESPACE="${CERT_MANAGER_NAMESPACE}"
  if [[ -z "${LIVE_SECRET_BACKUP_FILE}" ]]; then
    LIVE_SECRET_BACKUP_FILE="${WORK_DIR}/step-ca-root-ca-before-drill.yaml"
  fi

  log_warn "live mode will replace Secret/${CERT_MANAGER_NAMESPACE}/${STEP_CA_TLS_SECRET_NAME}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" get secret "${STEP_CA_TLS_SECRET_NAME}" -o yaml > "${LIVE_SECRET_BACKUP_FILE}"
  log "backed up live secret to ${LIVE_SECRET_BACKUP_FILE}"

  kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" delete secret "${STEP_CA_TLS_SECRET_NAME}" --wait=true
  run_bootstrap_script "${CERT_MANAGER_NAMESPACE}"
  verify_restored_secret "${CERT_MANAGER_NAMESPACE}" "${live_fingerprint}"
}

run_step_ca_smoke() {
  if [[ "${RUN_STEP_CA_SMOKE}" != "true" ]]; then
    log "skipping manual Step CA smoke by request"
    return 0
  fi

  STEP_CA_SMOKE_JOB="cert-smoke-step-ca-issuance-manual-$(date -u +%Y%m%d%H%M%S)"
  log "creating manual Step CA issuance smoke job ${CERT_MANAGER_NAMESPACE}/${STEP_CA_SMOKE_JOB}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" create job \
    --from=cronjob/cert-smoke-step-ca-issuance "${STEP_CA_SMOKE_JOB}" >/dev/null

  kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" wait \
    --for=condition=complete "job/${STEP_CA_SMOKE_JOB}" --timeout=15m >/dev/null

  log "manual Step CA smoke logs:"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" logs "job/${STEP_CA_SMOKE_JOB}"
}

main() {
  local live_fingerprint=""

  parse_args "$@"
  ensure_prereqs
  assert_source_secrets

  log "checking live secret ${CERT_MANAGER_NAMESPACE}/${STEP_CA_TLS_SECRET_NAME}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" get secret "${STEP_CA_TLS_SECRET_NAME}" >/dev/null
  live_fingerprint="$(secret_fingerprint "${CERT_MANAGER_NAMESPACE}" "${STEP_CA_TLS_SECRET_NAME}")"
  log "live secret fingerprint: ${live_fingerprint}"

  case "${MODE}" in
    scratch) run_scratch_restore "${live_fingerprint}" ;;
    live) run_live_restore "${live_fingerprint}" ;;
  esac

  run_step_ca_smoke
  log_success "cert-manager restore drill completed in ${MODE} mode"
}

main "$@"
