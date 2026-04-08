#!/usr/bin/env bash
# =============================================================================
# DeployKube Proxmox Talos Bootstrap Orchestrator
# =============================================================================
#
# This script orchestrates the full bootstrap flow:
#   Stage 0: VM provisioning + Talos cluster initialization
#   Stage 1: GitOps bootstrap (Forgejo + Argo CD)
#   Vault initialization
#
# Usage:
#   ./bootstrap-proxmox-talos.sh [--config path/to/config.yaml]
#
# Environment Variables (bootstrap-relevant):
#   PROXMOX_VE_API_TOKEN  - Proxmox API token in bpg/proxmox format (recommended)
#   PROXMOX_VE_USERNAME / PROXMOX_VE_PASSWORD - Proxmox credentials (fallback)
#   DEPLOYKUBE_DEPLOYMENT_ID - Deployment ID for the Deployment Secrets Bundle (default: proxmox-talos)
#   SOPS_AGE_KEY_FILE     - Optional override for SOPS Age identities file. If unset, Stage 1 prefers:
#                           ~/.config/deploykube/deployments/<deploymentId>/sops/age.key
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap/proxmox-talos"

# Scripts
STAGE0_SCRIPT="${SCRIPT_DIR}/bootstrap-proxmox-talos-stage0.sh"
STAGE1_SCRIPT="${SCRIPT_DIR}/bootstrap-proxmox-talos-stage1.sh"
INIT_VAULT_SCRIPT="${SCRIPT_DIR}/init-vault-secrets.sh"
BREAKGLASS_CUSTODY_ACK_SCRIPT="${SCRIPT_DIR}/breakglass-kubeconfig-custody-ack.sh"

# Defaults
CONFIG_FILE="${CONFIG_FILE:-${BOOTSTRAP_DIR}/config.yaml}"
STAGE0_SENTINEL="${STAGE0_SENTINEL:-${REPO_ROOT}/tmp/proxmox-talos-stage0-complete}"
KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-prod}"
export KUBECONFIG
DEFAULT_AGE_KEY_PATH="${HOME}/.config/sops/age/keys.txt"

# Capture original args before parsing (the parsing loop mutates $@ via shift).
BOOTSTRAP_ORIGINAL_ARGS=("$@")

# Control flags (can be overridden by environment)
BOOTSTRAP_SKIP_STAGE0="${BOOTSTRAP_SKIP_STAGE0:-false}"
BOOTSTRAP_SKIP_VAULT_INIT="${BOOTSTRAP_SKIP_VAULT_INIT:-false}"
BOOTSTRAP_WIPE_VAULT_DATA="${BOOTSTRAP_WIPE_VAULT_DATA:-false}"
BOOTSTRAP_REINIT_VAULT="${BOOTSTRAP_REINIT_VAULT:-false}"
BOOTSTRAP_FORCE_VAULT="${BOOTSTRAP_FORCE_VAULT:-false}"

# Breakglass custody gating (prod)
# The proxmox/talos kubeconfig is treated as the offline Kubernetes breakglass credential.
# We require an operator custody acknowledgement before running Stage 1.
BREAKGLASS_CUSTODY_ACK_SKIP="${BREAKGLASS_CUSTODY_ACK_SKIP:-false}"
BREAKGLASS_DEPLOYMENT_ID="${BREAKGLASS_DEPLOYMENT_ID:-proxmox-talos}"
BREAKGLASS_CUSTODY_SENTINEL="${BREAKGLASS_CUSTODY_SENTINEL:-${REPO_ROOT}/tmp/bootstrap/breakglass-kubeconfig-acked-${BREAKGLASS_DEPLOYMENT_ID}}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
  printf "${BLUE}[bootstrap]${NC} %s\n" "$1"
}

log_success() {
  printf "${GREEN}[bootstrap]${NC} %s\n" "$1"
}

log_warn() {
  printf "${YELLOW}[bootstrap]${NC} %s\n" "$1"
}

log_error() {
  printf "${RED}[bootstrap]${NC} %s\n" "$1"
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
  log_error "Unable to compute SHA256 (need shasum or sha256sum)"
  exit 1
}

detect_kube_context() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    return 0
  fi

  local ctx=""
  ctx=$(kubectl config current-context 2>/dev/null || true)
  if [[ -z "${ctx}" ]]; then
    ctx=$(kubectl config get-contexts -o name 2>/dev/null | head -n 1 || true)
  fi
  if [[ -z "${ctx}" ]]; then
    log_error "Unable to determine kubectl context from KUBECONFIG=${KUBECONFIG}"
    log_error "Ensure ${KUBECONFIG} exists and contains a valid context"
    exit 1
  fi
  export KUBE_CONTEXT="${ctx}"
}

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --skip-stage0)
      BOOTSTRAP_SKIP_STAGE0=true
      shift
      ;;
    --skip-vault)
      BOOTSTRAP_SKIP_VAULT_INIT=true
      shift
      ;;
    --wipe-vault)
      BOOTSTRAP_WIPE_VAULT_DATA=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --config PATH      Path to config.yaml (default: bootstrap/proxmox-talos/config.yaml)"
      echo "  --skip-stage0      Skip VM provisioning (use existing cluster)"
      echo "  --skip-vault       Skip Vault initialization"
      echo "  --wipe-vault       Wipe and reinitialize Vault data"
      echo ""
      echo "Environment:"
      echo "  BREAKGLASS_CUSTODY_ACK_SKIP=true   Skip breakglass custody gating (NOT recommended)"
      echo "  BREAKGLASS_DEPLOYMENT_ID=<id>      Custody ack ID (default: proxmox-talos)"
      echo "  --help             Show this help message"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# =============================================================================
# Prerequisites Check
# =============================================================================

check_prerequisites() {
  log "Checking prerequisites..."
  
  local missing=()
  
  # Required tools
  for cmd in tofu talosctl kubectl helm yq jq curl nc ssh scp; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install with: brew install ${missing[*]}"
    exit 1
  fi
  
  # Proxmox credentials
  if [[ -z "${PROXMOX_VE_API_TOKEN:-}" ]] && [[ -z "${PROXMOX_VE_USERNAME:-}" ]]; then
    log_error "Proxmox API credentials not set"
    log_error "Set PROXMOX_VE_API_TOKEN='user@realm!tokenid=secret'"
    log_error "Or set PROXMOX_VE_USERNAME and PROXMOX_VE_PASSWORD"
    exit 1
  fi
  
  # Config file
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "Config file not found: ${CONFIG_FILE}"
    log_error "Copy config.example.yaml to config.yaml and customize"
    exit 1
  fi
  
  log_success "Prerequisites check passed"
}

# =============================================================================
# Stage 0: VM Provisioning + Talos Bootstrap
# =============================================================================

run_stage0() {
  if [[ "${BOOTSTRAP_SKIP_STAGE0}" == "true" ]]; then
    log_warn "Skipping Stage 0 (BOOTSTRAP_SKIP_STAGE0=true)"
    return
  fi
  
  log "Running Stage 0: VM Provisioning + Talos Bootstrap"
  
  if [[ ! -x "${STAGE0_SCRIPT}" ]]; then
    log_error "Stage 0 script not found or not executable: ${STAGE0_SCRIPT}"
    exit 1
  fi
  
  CONFIG_FILE="${CONFIG_FILE}" \
  STAGE0_SENTINEL="${STAGE0_SENTINEL}" \
    "${STAGE0_SCRIPT}"
  
  log_success "Stage 0 complete"
}

require_stage0_sentinel() {
  if [[ ! -f "${STAGE0_SENTINEL}" ]]; then
    log_error "Stage 0 sentinel not found: ${STAGE0_SENTINEL}"
    log_error "Run Stage 0 first or use --skip-stage0 with existing cluster"
    exit 1
  fi
  log "Stage 0 sentinel present ($(cat "${STAGE0_SENTINEL}" 2>/dev/null || echo 'unknown'))"

  if [[ ! -s "${KUBECONFIG}" ]]; then
    log_error "Kubeconfig not found (or empty): ${KUBECONFIG}"
    log_error "Re-run Stage 0 to regenerate it, or set KUBECONFIG to an existing proxmox-talos kubeconfig"
    exit 1
  fi
}

require_breakglass_custody_ack() {
  if [[ "${BREAKGLASS_CUSTODY_ACK_SKIP}" == "true" ]]; then
    log_warn "Skipping breakglass kubeconfig custody ack gating (BREAKGLASS_CUSTODY_ACK_SKIP=true)"
    return 0
  fi

  if [[ ! -s "${KUBECONFIG}" ]]; then
    log_error "Kubeconfig not found (or empty): ${KUBECONFIG}"
    exit 1
  fi

  if [[ ! -s "${BREAKGLASS_CUSTODY_SENTINEL}" ]]; then
    log_error "Missing breakglass kubeconfig custody acknowledgement: ${BREAKGLASS_CUSTODY_SENTINEL#${REPO_ROOT}/}"
    log_error "This bootstrap treats ${KUBECONFIG#${REPO_ROOT}/} as the offline Kubernetes breakglass credential."
    log_error "You must store it out-of-band and record an operator attestation before continuing."
    echo ""
    echo "Run:"
    echo "  ${BREAKGLASS_CUSTODY_ACK_SCRIPT#${REPO_ROOT}/} \\"
    echo "    --deployment-id '${BREAKGLASS_DEPLOYMENT_ID}' \\"
    echo "    --kubeconfig '${KUBECONFIG#${REPO_ROOT}/}' \\"
    echo "    --storage-location '<where you stored it out-of-band>'"
    echo ""
    echo "Then continue by re-running the bootstrap (skip Stage 0; include any env vars you used, e.g. FORGEJO_FORCE_SEED=true):"
    printf "  %q " "./scripts/bootstrap-proxmox-talos.sh" "--skip-stage0" "${BOOTSTRAP_ORIGINAL_ARGS[@]}"
    echo ""
    echo ""
    exit 1
  fi

  local expected_sha actual_sha
  expected_sha="$(awk -F= '/^kubeconfig_sha256=/{print $2}' "${BREAKGLASS_CUSTODY_SENTINEL}" | tail -n 1)"
  if [[ -z "${expected_sha}" ]]; then
    log_error "Invalid custody sentinel (missing kubeconfig_sha256): ${BREAKGLASS_CUSTODY_SENTINEL#${REPO_ROOT}/}"
    exit 1
  fi

  actual_sha="$(sha256_file "${KUBECONFIG}")"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    log_error "Breakglass custody ack does not match current kubeconfig SHA256"
    log_error "  kubeconfig:  ${KUBECONFIG#${REPO_ROOT}/}"
    log_error "  expected:    ${expected_sha}"
    log_error "  actual:      ${actual_sha}"
    log_error "Re-run the custody acknowledgement after storing the current kubeconfig out-of-band."
    exit 1
  fi

  log_success "Breakglass kubeconfig custody acknowledgement present and matches current kubeconfig"
}

# =============================================================================
# Stage 1: GitOps Bootstrap
# =============================================================================

run_stage1() {
  log "Running Stage 1: GitOps Bootstrap (Forgejo + Argo CD)"
  
  if [[ ! -x "${STAGE1_SCRIPT}" ]]; then
    log_error "Stage 1 script not found or not executable: ${STAGE1_SCRIPT}"
    exit 1
  fi
  
  CONFIG_FILE="${CONFIG_FILE}" \
    "${STAGE1_SCRIPT}"
  
  log_success "Stage 1 complete"
}

# =============================================================================
# Vault Initialization
# =============================================================================

run_vault_init() {
  if [[ "${BOOTSTRAP_SKIP_VAULT_INIT}" == "true" ]]; then
    log_warn "Skipping Vault init (BOOTSTRAP_SKIP_VAULT_INIT=true)"
    return
  fi
  
  log "Running Vault initialization"
  
  if [[ ! -x "${INIT_VAULT_SCRIPT}" ]]; then
    log_error "Vault init script not found: ${INIT_VAULT_SCRIPT}"
    exit 1
	  fi
	  
	  local args=()
	  local dep_id="${DEPLOYKUBE_DEPLOYMENT_ID:-proxmox-talos}"
	  if [[ "${BOOTSTRAP_WIPE_VAULT_DATA}" == "true" ]]; then
	    args+=("--wipe-core-data")
	  fi
	  if [[ "${BOOTSTRAP_REINIT_VAULT}" == "true" ]]; then
	    args+=("--reinit-core")
	  fi
	  if [[ "${BOOTSTRAP_FORCE_VAULT}" == "true" ]]; then
	    args+=("--force")
	  fi
  
  # init-vault-secrets.sh uses kubectl --context; ensure it targets the proxmox/talos kubeconfig.
  detect_kube_context
  if ! kubectl --context "${KUBE_CONTEXT}" -n argocd get application platform-apps >/dev/null 2>&1; then
    log_error "application platform-apps not found in argocd namespace for context ${KUBE_CONTEXT}"
    log_error "Stage 1 may not have completed successfully, or kubectl is pointing at the wrong cluster."
    log_error "Try: FORGEJO_FORCE_SEED=true BOOTSTRAP_SKIP_STAGE0=true ./scripts/bootstrap-proxmox-talos.sh"
    exit 1
  fi

  DEPLOYKUBE_DEPLOYMENT_ID="${dep_id}" KUBE_CONTEXT="${KUBE_CONTEXT}" "${INIT_VAULT_SCRIPT}" "${args[@]}"
  
  log_success "Vault initialization complete"
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║         DeployKube Proxmox Talos Bootstrap                        ║"
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo ""
  
  check_prerequisites
  
  run_stage0
  require_stage0_sentinel
  require_breakglass_custody_ack
  
  run_stage1
  run_vault_init
  
  local cluster_domain
  cluster_domain=$(yq -r '.cluster.domain' "${CONFIG_FILE}" 2>/dev/null || true)
  if [[ -z "${cluster_domain}" || "${cluster_domain}" == "null" ]]; then
    cluster_domain="prod.internal.example.com"
  fi

  echo ""
  log_success "Bootstrap sequence complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Configure Pi-hole conditional forwarding (see README.md)"
  echo "  2. Verify Argo CD: argocd app get platform-apps -n argocd"
  echo "  3. Access Argo CD: https://argocd.${cluster_domain}"
  echo ""
}

main "$@"
