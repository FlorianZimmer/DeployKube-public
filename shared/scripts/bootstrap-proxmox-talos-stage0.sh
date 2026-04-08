#!/usr/bin/env bash
# =============================================================================
# DeployKube Proxmox Talos - Stage 0: VM Provisioning + Talos Bootstrap
# =============================================================================
#
# This script:
#   1. Downloads Talos ISO (with QEMU guest agent) from Image Factory
#   2. Uploads ISO to Proxmox
#   3. Runs OpenTofu to provision VMs
#   4. Applies Talos machine configurations
#   5. Bootstraps the Kubernetes cluster
#   6. Installs core networking (Cilium, MetalLB, Gateway API)
#   7. Configures NFS storage provisioner
#
# Prerequisites:
#   - Proxmox API token set via PM_API_TOKEN_ID / PM_API_TOKEN_SECRET
#   - config.yaml in bootstrap/proxmox-talos/
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap/proxmox-talos"
TOFU_DIR="${BOOTSTRAP_DIR}/tofu"
TALOS_DIR="${BOOTSTRAP_DIR}/talos"

# Config
CONFIG_FILE="${CONFIG_FILE:-${BOOTSTRAP_DIR}/config.yaml}"
STAGE0_SENTINEL="${STAGE0_SENTINEL:-${REPO_ROOT}/tmp/proxmox-talos-stage0-complete}"
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-proxmox-talos}"
DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE="${DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE:-${REPO_ROOT}/platform/gitops/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/config.yaml}"
NTP_UPSTREAM_SERVERS=()

# Offline bundle (Phase 0): when set, Stage 0 must not fetch artefacts from the internet.
# The bundle is expected to contain charts/, talos/, and optional OCI images (pre-load via offline-bundle-load-registry.sh).
OFFLINE_BUNDLE_DIR="${OFFLINE_BUNDLE_DIR:-}"
OFFLINE_BUNDLE_AUTO_LOAD_REGISTRY="${OFFLINE_BUNDLE_AUTO_LOAD_REGISTRY:-0}"

GATEWAY_API_MANIFEST_PATH="${GATEWAY_API_MANIFEST_PATH:-${REPO_ROOT}/platform/gitops/components/networking/gateway-api/standard-install.yaml}"
REGISTRY_SYNC_SCRIPT="${REGISTRY_SYNC_SCRIPT:-${REPO_ROOT}/shared/scripts/registry-sync.sh}"
REGISTRY_PREFLIGHT_DARKSITE_IMAGES="${REGISTRY_PREFLIGHT_DARKSITE_IMAGES:-true}"
REGISTRY_PREFLIGHT_DARKSITE_OS="${REGISTRY_PREFLIGHT_DARKSITE_OS:-linux}"
REGISTRY_PREFLIGHT_DARKSITE_ARCH="${REGISTRY_PREFLIGHT_DARKSITE_ARCH:-amd64}"
REGISTRY_PREFLIGHT_SAMPLE_NODE_PULL="${REGISTRY_PREFLIGHT_SAMPLE_NODE_PULL:-true}"

# Timeouts (seconds) - override via environment if your Proxmox/storage is slow
TALOS_DHCP_BOOT_WAIT_SECONDS="${TALOS_DHCP_BOOT_WAIT_SECONDS:-45}"
TALOS_TALOSAPI_WAIT_TIMEOUT_SECONDS="${TALOS_TALOSAPI_WAIT_TIMEOUT_SECONDS:-600}"
TALOS_REBOOT_WAIT_TIMEOUT_SECONDS="${TALOS_REBOOT_WAIT_TIMEOUT_SECONDS:-900}"
TALOS_BOOTSTRAP_TIMEOUT_SECONDS="${TALOS_BOOTSTRAP_TIMEOUT_SECONDS:-900}"
TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS="${TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS:-600}"
TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS="${TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS:-120}"
KUBECONFIG_WAIT_TIMEOUT_SECONDS="${KUBECONFIG_WAIT_TIMEOUT_SECONDS:-900}"
KUBERNETES_API_WAIT_TIMEOUT_SECONDS="${KUBERNETES_API_WAIT_TIMEOUT_SECONDS:-900}"

# OpenTofu execution controls (Proxmox provider often behaves better with low parallelism)
TOFU_PARALLELISM="${TOFU_PARALLELISM:-1}"
TOFU_LOCK_TIMEOUT="${TOFU_LOCK_TIMEOUT:-10m}"
TOFU_INIT_UPGRADE="${TOFU_INIT_UPGRADE:-false}"

PROXMOX_TALOS_REUSE_EXISTING_VMS="${PROXMOX_TALOS_REUSE_EXISTING_VMS:-true}"
PROXMOX_TALOS_FORCE_TOFU="${PROXMOX_TALOS_FORCE_TOFU:-false}"
REUSED_EXISTING_VMS=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[stage0]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[stage0]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[stage0]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[stage0]${NC} %s\n" "$1"; }

is_ipv4() {
  local ip="$1"
  local -a octets

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${ip}"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for o in "${octets[@]}"; do
    [[ "${o}" =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
}

PROXMOX_SSH_USER="${PROXMOX_SSH_USER:-root}"
PROXMOX_SSH_HOST=""
PROXMOX_SSH_CONTROL_DIR=""
PROXMOX_SSH_CONTROL_PATH=""

HELM_NO_USER_PLUGINS="${HELM_NO_USER_PLUGINS:-true}"

# Bootstrap tools image must be pullable by Talos nodes (Proxmox has no image side-loading like kind).
BOOTSTRAP_TOOLS_IMAGE="${BOOTSTRAP_TOOLS_IMAGE:-registry.example.internal/deploykube/bootstrap-tools:1.4}"
# Narrow validation image for low-surface smoke jobs.
VALIDATION_TOOLS_CORE_IMAGE="${VALIDATION_TOOLS_CORE_IMAGE:-registry.example.internal/deploykube/validation-tools-core:0.1.0}"
# Tenant provisioner image must be pullable by Talos nodes (used by GitOps controllers).
TENANT_PROVISIONER_IMAGE="${TENANT_PROVISIONER_IMAGE:-registry.example.internal/deploykube/tenant-provisioner:0.2.24}"
# Rebuild even when the tag already exists so local-registry content stays aligned with current repo source.
# Set to false to keep legacy "skip when present" behavior.
TENANT_PROVISIONER_REBUILD_IF_PRESENT="${TENANT_PROVISIONER_REBUILD_IF_PRESENT:-true}"
HELM_PLUGINS_EMPTY_DIR=""

FORCE_CILIUM_UPGRADE="${FORCE_CILIUM_UPGRADE:-false}"
CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.18.5}"
METALLB_CHART_VERSION="${METALLB_CHART_VERSION:-0.15.2}"
METALLB_CONFIGURE_POD_SECURITY="${METALLB_CONFIGURE_POD_SECURITY:-true}"
METALLB_POD_SECURITY_LEVEL="${METALLB_POD_SECURITY_LEVEL:-privileged}"
NFS_CONFIGURE_POD_SECURITY="${NFS_CONFIGURE_POD_SECURITY:-true}"
NFS_POD_SECURITY_LEVEL="${NFS_POD_SECURITY_LEVEL:-privileged}"
NFS_RWO_SUBDIR="${NFS_RWO_SUBDIR:-rwo}"
NFS_PROVISIONER_CHART_VERSION="${NFS_PROVISIONER_CHART_VERSION:-4.0.18}"

indent_lines() {
  sed 's/^/[stage0]   /'
}

RUN_OUTPUT=""
run_with_timeout_capture() {
  local timeout_seconds="$1"
  shift

  local tmp
  tmp="$(mktemp "/tmp/deploykube-cmd.XXXXXX")"

  "$@" >"${tmp}" 2>&1 &
  local pid=$!

  local deadline=$((SECONDS + timeout_seconds))
  local timed_out=false

  while kill -0 "${pid}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      timed_out=true
      break
    fi
    sleep 1
  done

  local status=0
  if [[ "${timed_out}" == "true" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    sleep 2
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
    status=124
  else
    wait "${pid}" || status=$?
  fi

  RUN_OUTPUT="$(cat "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}" || true
  return "${status}"
}

duration_to_seconds() {
  local input="$1"
  local rest="${input}"
  local total=0
  local matched=0

  # Support Go-style short durations like "20m", "900s", "1h", "20m0s".
  while [[ "${rest}" =~ ^([0-9]+)([smhd])(.*)$ ]]; do
    local n="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    matched=1

    case "${unit}" in
      s) total=$((total + n)) ;;
      m) total=$((total + n * 60)) ;;
      h) total=$((total + n * 3600)) ;;
      d) total=$((total + n * 86400)) ;;
      *) ;;
    esac
  done

  if [[ "${matched}" -eq 1 && -z "${rest}" ]]; then
    echo "${total}"
    return 0
  fi

  if [[ "${input}" =~ ^[0-9]+$ ]]; then
    echo "${input}"
    return 0
  fi

  # Fallback: 20 minutes.
  echo 1200
}

cleanup_stage0() {
  cleanup_proxmox_ssh
  if [[ -n "${HELM_PLUGINS_EMPTY_DIR}" && -d "${HELM_PLUGINS_EMPTY_DIR}" ]]; then
    rm -rf "${HELM_PLUGINS_EMPTY_DIR}" || true
  fi
}

cleanup_proxmox_ssh() {
  if [[ -n "${PROXMOX_SSH_CONTROL_DIR}" && -d "${PROXMOX_SSH_CONTROL_DIR}" ]]; then
    ssh -O exit -o ControlPath="${PROXMOX_SSH_CONTROL_PATH}" "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" >/dev/null 2>&1 || true
    rm -rf "${PROXMOX_SSH_CONTROL_DIR}" || true
  fi
}

setup_helm_env() {
  if [[ "${HELM_NO_USER_PLUGINS}" != "true" ]]; then
    return 0
  fi

  # Some environments have a broken Helm plugin installation (e.g. helm-secrets),
  # which prevents *all* Helm commands from running. For bootstrap we don't need
  # user plugins, so point Helm at an empty plugins dir.
  HELM_PLUGINS_EMPTY_DIR="$(mktemp -d "/tmp/deploykube-helm-plugins.XXXXXX")"
  chmod 700 "${HELM_PLUGINS_EMPTY_DIR}"
}

helm_cmd() {
  if [[ "${HELM_NO_USER_PLUGINS}" == "true" ]]; then
    HELM_PLUGINS="${HELM_PLUGINS_EMPTY_DIR}" helm "$@"
  else
    helm "$@"
  fi
}

ensure_namespace_pod_security() {
  local namespace="$1"
  local level="$2"

  kubectl get namespace "${namespace}" >/dev/null 2>&1 || kubectl create namespace "${namespace}" >/dev/null
  kubectl label namespace "${namespace}" \
    "pod-security.kubernetes.io/enforce=${level}" \
    "pod-security.kubernetes.io/audit=${level}" \
    "pod-security.kubernetes.io/warn=${level}" \
    --overwrite >/dev/null
}

ensure_nfs_path_exists_on_server() {
  local server="$1"
  local path="$2"

  if [[ "${server}" == "${PROXMOX_HOST}" ]]; then
    log "Ensuring NFS path exists on Proxmox host: ${path}"
    proxmox_ssh "mkdir -p '${path}'" || true
    return 0
  fi

  log_warn "NFS_SERVER (${server}) is not PROXMOX_HOST (${PROXMOX_HOST}); ensure NFS path exists: ${server}:${path}"
  return 0
}

cilium_is_healthy() {
  # Rollout status exits non-zero if resource is missing or not ready.
  kubectl -n kube-system rollout status ds/cilium --timeout=5s >/dev/null 2>&1 || return 1
  kubectl -n kube-system rollout status deploy/hubble-relay --timeout=5s >/dev/null 2>&1 || return 1
  kubectl -n kube-system rollout status deploy/hubble-ui --timeout=5s >/dev/null 2>&1 || return 1
  return 0
}

argocd_is_installed() {
  # Detect Argo CD (Stage 1) to avoid fighting GitOps-managed resources with Helm/kubectl.
  # We intentionally keep this permissive: any deployment containing "argocd-application-controller"
  # indicates the app controller is running.
  kubectl -n argocd get ns argocd >/dev/null 2>&1 || return 1

  # Argo CD "application-controller" is a StatefulSet in many installs (including ours).
  if kubectl -n argocd get sts -o name >/dev/null 2>&1; then
    if kubectl -n argocd get sts -o name 2>/dev/null | grep -q "application-controller"; then
      return 0
    fi
  fi

  # Fallback: any of the common Argo CD deployments imply Stage 1 is present.
  if kubectl -n argocd get deploy -o name >/dev/null 2>&1; then
    kubectl -n argocd get deploy -o name 2>/dev/null | grep -q "argocd-server"
    return $?
  fi

  return 1
}

metallb_is_healthy() {
  kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=5s >/dev/null 2>&1 || return 1
  kubectl -n metallb-system rollout status ds/metallb-speaker --timeout=5s >/dev/null 2>&1 || return 1
  return 0
}

storage_nfs_provisioner_is_healthy() {
  kubectl -n storage-system rollout status deploy/nfs-provisioner-nfs-subdir-external-provisioner --timeout=5s >/dev/null 2>&1 || return 1
  return 0
}

adopt_resource_into_helm_release() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local release_name="$4"
  local release_namespace="$5"

  if [[ -n "${namespace}" ]]; then
    kubectl -n "${namespace}" get "${kind}" "${name}" >/dev/null 2>&1 || return 0
    kubectl -n "${namespace}" label "${kind}" "${name}" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
    kubectl -n "${namespace}" annotate "${kind}" "${name}" \
      "meta.helm.sh/release-name=${release_name}" \
      "meta.helm.sh/release-namespace=${release_namespace}" \
      --overwrite >/dev/null 2>&1 || true
    return 0
  fi

  kubectl get "${kind}" "${name}" >/dev/null 2>&1 || return 0
  kubectl label "${kind}" "${name}" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
  kubectl annotate "${kind}" "${name}" \
    "meta.helm.sh/release-name=${release_name}" \
    "meta.helm.sh/release-namespace=${release_namespace}" \
    --overwrite >/dev/null 2>&1 || true
}

run_helm_with_progress() {
  local timeout_duration="$1"
  shift

  local timeout_seconds
  timeout_seconds="$(duration_to_seconds "${timeout_duration}")"
  local deadline=$((SECONDS + timeout_seconds + 60))

  local tmp
  tmp="$(mktemp "/tmp/deploykube-helm.XXXXXX")"

  (
    if [[ "${HELM_NO_USER_PLUGINS}" == "true" ]]; then
      HELM_PLUGINS="${HELM_PLUGINS_EMPTY_DIR}" helm "$@"
    else
      helm "$@"
    fi
  ) >"${tmp}" 2>&1 &
  local pid=$!

  local last_report=0
  while kill -0 "${pid}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      log_error "Helm command exceeded ${timeout_duration}; aborting"
      kill -TERM "${pid}" >/dev/null 2>&1 || true
      sleep 2
      kill -KILL "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
      RUN_OUTPUT="$(cat "${tmp}" 2>/dev/null || true)"
      rm -f "${tmp}" || true
      return 124
    fi

    if (( SECONDS - last_report >= 30 )); then
      last_report="${SECONDS}"
      log "Still waiting on Helm (${timeout_duration})..."
      (kubectl -n kube-system get pods -o wide 2>&1 | indent_lines >&2) || true
    fi
    sleep 2
  done

  local status=0
  wait "${pid}" || status=$?
  RUN_OUTPUT="$(cat "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}" || true
  return "${status}"
}

setup_proxmox_ssh_multiplexing() {
  PROXMOX_SSH_HOST="${PROXMOX_HOST}"
  # Keep the ControlPath short: Unix domain sockets have tight path length limits
  # (notably on macOS). Use /tmp rather than the repo path.
  PROXMOX_SSH_CONTROL_DIR="$(mktemp -d "/tmp/deploykube-proxmox-ssh.XXXXXX")"
  chmod 700 "${PROXMOX_SSH_CONTROL_DIR}"
  PROXMOX_SSH_CONTROL_PATH="${PROXMOX_SSH_CONTROL_DIR}/cm-%C"

  trap cleanup_stage0 EXIT INT TERM

  log "Establishing SSH master connection to ${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST} (password will be prompted once if needed)..."
  ssh \
    -o ControlMaster=yes \
    -o ControlPersist=15m \
    -o ControlPath="${PROXMOX_SSH_CONTROL_PATH}" \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    -N -f \
    "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}"
  log_success "SSH master connection established (subsequent ssh/scp calls will reuse it)"
}

proxmox_ssh() {
  ssh \
    -o ControlMaster=auto \
    -o ControlPersist=15m \
    -o ControlPath="${PROXMOX_SSH_CONTROL_PATH}" \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" \
    "$@"
}

proxmox_scp() {
  scp \
    -o ControlMaster=auto \
    -o ControlPersist=15m \
    -o ControlPath="${PROXMOX_SSH_CONTROL_PATH}" \
    "$@"
}

proxmox_vm_exists() {
  local vmid="$1"
  proxmox_ssh "qm status ${vmid} >/dev/null 2>&1"
}

proxmox_vm_running() {
  local vmid="$1"
  proxmox_ssh "qm status ${vmid} 2>/dev/null | grep -qi 'running'"
}

ensure_proxmox_vms_running() {
  local -a vmids=("$@")
  local started_any=false

  for vmid in "${vmids[@]}"; do
    if ! proxmox_vm_running "${vmid}"; then
      log_warn "VM ${vmid} is not running; starting it..."
      proxmox_ssh "qm start ${vmid} >/dev/null 2>&1" || true
      started_any=true
    fi
  done

  if [[ "${started_any}" == "true" ]]; then
    # Best-effort wait for them to report "running".
    for vmid in "${vmids[@]}"; do
      local deadline=$((SECONDS + 300))
      while (( SECONDS < deadline )); do
        if proxmox_vm_running "${vmid}"; then
          break
        fi
        sleep 2
      done
    done
  fi
}

compute_expected_ips() {
  local start_ip="$1"
  local count="$2"
  local -a out=()

  local prefix="${start_ip%.*}"
  local suffix="${start_ip##*.}"
  for ((i=0; i<count; i++)); do
    out+=("${prefix}.$((suffix + i))")
  done

  printf "%s\n" "${out[@]}"
}

talos_configs_present() {
  local missing=0
  for i in $(seq 1 "${CP_COUNT}"); do
    [[ -f "${TALOS_DIR}/${CLUSTER_NAME}-cp-${i}.yaml" ]] || missing=1
  done
  for name in "${WORKER_NAMES[@]}"; do
    [[ -f "${TALOS_DIR}/${CLUSTER_NAME}-${name}.yaml" ]] || missing=1
  done
  [[ -f "${TALOS_DIR}/talosconfig" ]] || missing=1

  [[ "${missing}" -eq 0 ]]
}

talos_configs_reusable() {
  # Avoid reusing Talos configs that contain keys rejected by the Talos ISO version.
  # (e.g. configs rendered by a newer Talos provider than the on-disk Talos ISO.)
  if grep -Rqs "grubUseUKICmdline" "${TALOS_DIR}" 2>/dev/null; then
    log_warn "Detected unsupported Talos key 'grubUseUKICmdline' in ${TALOS_DIR}; forcing OpenTofu re-render"
    return 1
  fi

  if grep -Rqs "kind: HostnameConfig" "${TALOS_DIR}" 2>/dev/null; then
    log_warn "Detected unsupported Talos document kind 'HostnameConfig' in ${TALOS_DIR}; forcing OpenTofu re-render"
    return 1
  fi

  # Talos treats /etc as immutable; writing files outside /var can keep nodes stuck in "booting"
  # (kubelet PKI writes will fail), which breaks bootstrap.
  if grep -Rqs "/etc/ssl/certs/deploykube-root-ca.crt" "${TALOS_DIR}" 2>/dev/null; then
    log_warn "Detected legacy Talos config writing DeployKube CA under /etc (immutable); forcing OpenTofu re-render"
    return 1
  fi

  return 0
}

talos_configs_match_deployment_ntp() {
  local expected
  expected="$(printf '%s\n' "${NTP_UPSTREAM_SERVERS[@]}")"

  local -a files=()
  local i
  for i in $(seq 1 "${CP_COUNT}"); do
    files+=("${TALOS_DIR}/${CLUSTER_NAME}-cp-${i}.yaml")
  done
  for i in "${WORKER_NAMES[@]}"; do
    files+=("${TALOS_DIR}/${CLUSTER_NAME}-${i}.yaml")
  done

  local file
  for file in "${files[@]}"; do
    local actual
    actual="$(yq -r '.machine.time.servers[]?' "${file}" 2>/dev/null || true)"
    if [[ "${actual}" != "${expected}" ]]; then
      log_warn "Talos config NTP servers drift from DeploymentConfig in ${file}; forcing OpenTofu reconcile"
      return 1
    fi
  done

  return 0
}

talos_node_mode() {
  # Echoes "secure" if normal mode API works, "maintenance" if only insecure works, "down" otherwise.
  local ip="$1"

  # 1. Try secure version (authenticated)
  if run_with_timeout_capture 10 talosctl --endpoints "${ip}" --nodes "${ip}" version >/dev/null 2>&1; then
    echo "secure"
    return 0
  fi

  # 2. Try insecure machinestatus (maintenance)
  # Even if 'version' is unimplemented, 'get machinestatus' usually works in maintenance.
  if run_with_timeout_capture 10 talosctl --endpoints "${ip}" --nodes "${ip}" get machinestatus --insecure >/dev/null 2>&1; then
    echo "maintenance"
    return 0
  fi

  echo "down"
  return 1
}

wait_for_tcp_port() {
  local ip="$1"
  local port="$2"
  local timeout_seconds="$3"
  local label="${4:-tcp}"

  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if nc -z -w 2 "${ip}" "${port}" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done

  log_error "Timeout waiting for ${label} (${ip}:${port}) after ${timeout_seconds}s"
  return 1
}

wait_for_k8s_nodes() {
  local expected_min="${1:-1}"
  local timeout_seconds="${2:-600}"

  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local count=""
    count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "")
    if [[ -n "${count}" ]] && [[ "${count}" -ge "${expected_min}" ]]; then
      return 0
    fi
    sleep 5
  done

  log_error "Timeout waiting for at least ${expected_min} Kubernetes node(s) to register after ${timeout_seconds}s"
  (kubectl get nodes -o wide 2>&1 | indent_lines >&2) || true
  return 1
}

wait_for_k8s_nodes_ready() {
  local expected_min="${1:-1}"
  local timeout_seconds="${2:-900}"

  if ! wait_for_k8s_nodes "${expected_min}" "${timeout_seconds}"; then
    return 1
  fi

  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    # `kubectl wait ... nodes --all` errors with "no matching resources found" when the list is empty.
    # Guard against that race even after registration checks.
    if kubectl wait --for=condition=Ready nodes --all --timeout=30s >/dev/null 2>&1; then
      return 0
    fi

    local msg=""
    msg="$(kubectl wait --for=condition=Ready nodes --all --timeout=1s 2>&1 || true)"
    if printf '%s' "${msg}" | grep -qi 'no matching resources found'; then
      sleep 5
      continue
    fi

    sleep 10
  done

  log_error "Timeout waiting for all nodes to be Ready after ${timeout_seconds}s"
  (kubectl get nodes -o wide 2>&1 | indent_lines >&2) || true
  return 1
}

wait_for_talos_api() {
  local ip="$1"
  local timeout_seconds="$2"

  # First: socket open
  wait_for_tcp_port "${ip}" 50000 "${timeout_seconds}" "Talos API" || return 1

  # Second: Talos API actually answers with our talosconfig (TLS/certs ready)
  local deadline=$((SECONDS + timeout_seconds))
  local out=""
  while (( SECONDS < deadline )); do
    if run_with_timeout_capture 15 talosctl --endpoints "${ip}" --nodes "${ip}" version; then
      out="${RUN_OUTPUT}"
      return 0
    fi
    # If the node is still in maintenance mode (e.g., install failed), the secure API won't answer.
    if run_with_timeout_capture 10 talosctl --endpoints "${ip}" --nodes "${ip}" version --insecure; then
      log_error "Talos API on ${ip} appears to be in maintenance mode (install may have failed)"
      return 1
    fi
    sleep 5
  done

  log_error "Talos API port is open but 'talosctl version' never succeeded on ${ip} after ${timeout_seconds}s"
  if [[ -n "${out}" ]]; then
    printf "%s\n" "${out}" | indent_lines >&2
  fi
  return 1
}

wait_for_kubelet_api() {
  local ip="$1"
  local timeout_seconds="$2"

  # Kubelet typically comes up early even when the node cannot yet register (API server not ready).
  # This is a useful liveness signal for workers before Talos bootstrap completes.
  wait_for_tcp_port "${ip}" 10250 "${timeout_seconds}" "Kubelet API" || return 1
  return 0
}

diagnose_talos_node() {
  local ip="$1"
  log_error "Diagnostics for ${ip}:"

  if ping -c 1 "${ip}" >/dev/null 2>&1; then
    log_error "ICMP ping: reachable"
  else
    log_error "ICMP ping: no reply (may still be OK if filtered)"
  fi

  if nc -z -w 2 "${ip}" 50000 >/dev/null 2>&1; then
    log_error "Talos API port 50000: open"
  else
    log_error "Talos API port 50000: closed/unreachable"
  fi

  if ! (talosctl --endpoints "${ip}" --nodes "${ip}" version 2>&1 | indent_lines >&2); then
    log_error "Secure Talos API failed; trying maintenance mode (--insecure) for additional hints:"
    (talosctl --endpoints "${ip}" --nodes "${ip}" version --insecure 2>&1 | indent_lines >&2) || true
    (talosctl --endpoints "${ip}" --nodes "${ip}" get machinestatus --insecure 2>&1 | indent_lines >&2) || true
    return 0
  fi

  (talosctl --endpoints "${ip}" --nodes "${ip}" service 2>&1 | indent_lines >&2) || true
  (talosctl --endpoints "${ip}" --nodes "${ip}" logs installer --tail 80 2>&1 | indent_lines >&2) || true
  (talosctl --endpoints "${ip}" --nodes "${ip}" logs etcd --tail 80 2>&1 | indent_lines >&2) || true
  (talosctl --endpoints "${ip}" --nodes "${ip}" logs kubelet --tail 80 2>&1 | indent_lines >&2) || true
}

build_and_push_bootstrap_tools() {
  # Build and push bootstrap-tools image to local registry.
  # This is needed because Talos cannot build/load local images.
  #
  # Prerequisites:
  #   - Local registry must be running (deploy via homelab ansible role)
  #   - Docker must be configured to allow insecure registries (OrbStack: ~/.orbstack/config/docker.json)
  #
  # Note: We explicitly build for linux/amd64 because Talos VMs run on Proxmox (x86_64),
  # even when building from an Apple Silicon Mac (arm64).
  
  if [[ -z "${REGISTRY_HOST}" ]]; then
    log_warn "No registry.host configured; skipping local build/push of bootstrap-tools"
    return 0
  fi
  
  local local_registry="${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}"
  local image_tag="deploykube/bootstrap-tools:1.4"
  local full_image="${local_registry}/${image_tag}"
  local dockerfile="${REPO_ROOT}/shared/images/bootstrap-tools/Dockerfile"

  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    log "Offline mode: skipping bootstrap-tools build; validating tag exists in local registry (${local_registry})"
    if curl -sf "http://${local_registry}/v2/deploykube/bootstrap-tools/tags/list" 2>/dev/null | grep -q '"1.4"'; then
      log_success "bootstrap-tools:1.4 present in local registry"
      return 0
    fi
    log_error "bootstrap-tools:1.4 missing in local registry (${local_registry})"
    log_error "Load images from an offline bundle first, for example:"
    log_error "  ./shared/scripts/offline-bundle-load-registry.sh --bundle <bundleDir> --bootstrap-config ${CONFIG_FILE}"
    return 1
  fi
  
  log "Building bootstrap-tools image for local registry (linux/amd64)..."
  
  if [[ ! -f "${dockerfile}" ]]; then
    log_error "Dockerfile not found: ${dockerfile}"
    return 1
  fi
  
  # Check if registry is reachable
  if ! curl -sf "http://${local_registry}/v2/" >/dev/null 2>&1; then
    log_error "Local registry not reachable at ${local_registry}"
    log_error "Deploy the registry first using:"
    log_error "  cd ~/playbooks/homelab && ansible-playbook roles/registry/tasks/deploy.yaml -i inventory.yaml"
    return 1
  fi

  # Fast path: if the expected tag is already present, don't depend on a local Docker daemon.
  # We'll still validate pullability via `talosctl image pull` later.
  if curl -sf "http://${local_registry}/v2/deploykube/bootstrap-tools/tags/list" 2>/dev/null | grep -q '"1.4"'; then
    log "bootstrap-tools:1.4 already exists in local registry; skipping build"
    return 0
  fi

  # Check if amd64 image already exists in registry
  local manifest_arch=""
  manifest_arch=$(curl -sf "http://${local_registry}/v2/deploykube/bootstrap-tools/manifests/1.4" 2>/dev/null | grep -oE '"architecture"\\s*:\\s*"[^"]*"' | head -1 || true)
  if [[ "${manifest_arch}" == *"amd64"* ]]; then
    log "bootstrap-tools:1.4 (amd64) already exists in local registry; skipping build"
    return 0
  fi
  
  # Use buildx to cross-compile for amd64 and push directly
  log "Building ${full_image} for linux/amd64..."
  if ! docker buildx build \
    --platform linux/amd64 \
    -t "${full_image}" \
    -f "${dockerfile}" \
    "${REPO_ROOT}/shared/images/bootstrap-tools" \
    --push; then
    log_error "Failed to build/push bootstrap-tools image"
    log_error "If using HTTP (insecure) registry, configure OrbStack:"
    log_error '  echo '\''{"insecure-registries": ["'"${local_registry}"'"]}'\'' > ~/.orbstack/config/docker.json'
    log_error "  orb start"
    return 1
  fi
  
  log_success "bootstrap-tools image (amd64) pushed to ${full_image}"
}

build_and_push_validation_tools_core() {
  if [[ -z "${REGISTRY_HOST}" ]]; then
    log_warn "No registry.host configured; skipping local build/push of validation-tools-core"
    return 0
  fi

  local local_registry="${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}"
  local image_tag="deploykube/validation-tools-core:0.1.0"
  local full_image="${local_registry}/${image_tag}"
  local dockerfile="${REPO_ROOT}/shared/images/validation-tools-core/Dockerfile"

  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    log "Offline mode: skipping validation-tools-core build; validating tag exists in local registry (${local_registry})"
    if curl -sf "http://${local_registry}/v2/deploykube/validation-tools-core/tags/list" 2>/dev/null | grep -q '"0.1.0"'; then
      log_success "validation-tools-core:0.1.0 present in local registry"
      return 0
    fi
    log_error "validation-tools-core:0.1.0 missing in local registry (${local_registry})"
    log_error "Load images from an offline bundle first, for example:"
    log_error "  ./shared/scripts/offline-bundle-load-registry.sh --bundle <bundleDir> --bootstrap-config ${CONFIG_FILE}"
    return 1
  fi

  log "Building validation-tools-core image for local registry (linux/amd64)..."

  if [[ ! -f "${dockerfile}" ]]; then
    log_error "Dockerfile not found: ${dockerfile}"
    return 1
  fi

  if ! curl -sf "http://${local_registry}/v2/" >/dev/null 2>&1; then
    log_error "Local registry not reachable at ${local_registry}"
    return 1
  fi

  if curl -sf "http://${local_registry}/v2/deploykube/validation-tools-core/tags/list" 2>/dev/null | grep -q '"0.1.0"'; then
    log "validation-tools-core:0.1.0 already exists in local registry; skipping build"
    return 0
  fi

  if ! docker buildx inspect deploykube-validation-tools-core >/dev/null 2>&1; then
    docker buildx create --name deploykube-validation-tools-core --driver docker-container --use >/dev/null
  fi

  log "Building ${full_image} for linux/amd64..."
  if ! docker buildx build \
    --builder deploykube-validation-tools-core \
    --platform linux/amd64 \
    -f "${dockerfile}" \
    "${REPO_ROOT}/shared/images/validation-tools-core" \
    --output "type=registry,name=${full_image},push=true,registry.insecure=true"; then
    log_error "Failed to build/push validation-tools-core image"
    return 1
  fi

  log_success "validation-tools-core image (amd64) pushed to ${full_image}"
}

build_and_push_tenant_provisioner() {
  # Build and push tenant-provisioner image to local registry.
  #
  # This is needed because Talos cannot build/load local images. We wire Argo to pull the image
  # from the local registry via the proxmox-talos env bundle kustomize image overrides.
  if [[ -z "${REGISTRY_HOST}" ]]; then
    log_warn "No registry.host configured; skipping local build/push of tenant-provisioner"
    return 0
  fi

  local local_registry="${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}"
  local full_image="${TENANT_PROVISIONER_IMAGE}"
  local dockerfile="${REPO_ROOT}/shared/images/tenant-provisioner/Dockerfile"

  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    local repo_with_tag="${full_image#${local_registry}/}"
    local repo="${repo_with_tag%:*}"
    local tag="${repo_with_tag##*:}"
    log "Offline mode: skipping tenant-provisioner build; validating tag exists in local registry (${local_registry})"
    if curl -sf "http://${local_registry}/v2/${repo}/tags/list" 2>/dev/null | grep -q "\"${tag}\""; then
      log_success "tenant-provisioner:${tag} present in local registry"
      return 0
    fi
    log_error "tenant-provisioner:${tag} missing in local registry (${local_registry})"
    log_error "Load images from an offline bundle first, for example:"
    log_error "  ./shared/scripts/offline-bundle-load-registry.sh --bundle <bundleDir> --bootstrap-config ${CONFIG_FILE}"
    return 1
  fi

  log "Building tenant-provisioner image for local registry (linux/amd64)..."

  if [[ ! -f "${dockerfile}" ]]; then
    log_error "Dockerfile not found: ${dockerfile}"
    return 1
  fi

  if ! curl -sf "http://${local_registry}/v2/" >/dev/null 2>&1; then
    log_error "Local registry not reachable at ${local_registry}"
    log_error "Deploy the registry first using:"
    log_error "  cd ~/playbooks/homelab && ansible-playbook roles/registry/tasks/deploy.yaml -i inventory.yaml"
    return 1
  fi

  local repo_with_tag="${full_image#${local_registry}/}"
  local repo="${repo_with_tag%:*}"
  local tag="${repo_with_tag##*:}"
  if curl -sf "http://${local_registry}/v2/${repo}/tags/list" 2>/dev/null | grep -q "\"${tag}\""; then
    if [[ "${TENANT_PROVISIONER_REBUILD_IF_PRESENT}" == "true" ]]; then
      log_warn "tenant-provisioner:${tag} already exists in local registry; rebuilding/pushing to refresh tag content from current repo source"
    else
      log "tenant-provisioner:${tag} already exists in local registry; skipping build (TENANT_PROVISIONER_REBUILD_IF_PRESENT=false)"
      return 0
    fi
  fi

  log "Building ${full_image} for linux/amd64..."
  if ! docker buildx build \
    --platform linux/amd64 \
    -t "${full_image}" \
    -f "${dockerfile}" \
    "${REPO_ROOT}" \
    --push; then
    log_error "Failed to build/push tenant-provisioner image"
    log_error "If using HTTP (insecure) registry, configure OrbStack:"
    log_error '  echo '\''{"insecure-registries": ["'"${local_registry}"'"]}'\'' > ~/.orbstack/config/docker.json'
    log_error "  orb start"
    return 1
  fi

  log_success "tenant-provisioner image (amd64) pushed to ${full_image}"
}

prepull_bootstrap_tools_image() {
  # Many GitOps hook Jobs rely on the bootstrap-tools image (kubectl/curl/jq/sops/...).
  # On Talos we cannot "kind load" images, so ensure the image is pullable early.
  log "Pre-pulling bootstrap tools image on all nodes: ${BOOTSTRAP_TOOLS_IMAGE}"

  export TALOSCONFIG="${TALOS_DIR}/talosconfig"

  local -a nodes=()
  nodes+=("${CONTROL_PLANE_IPS[@]}")

  # Some environments don't expose the Talos API on workers reliably during early bootstrap.
  # Pre-pull on control planes (to validate registry reachability), and only include workers
  # when their Talos API port is reachable.
  for worker in "${WORKER_IPS[@]}"; do
    if nc -z -w 1 "${worker}" 50000 >/dev/null 2>&1; then
      nodes+=("${worker}")
    else
      log_warn "Skipping bootstrap-tools pre-pull on worker ${worker}: Talos API not reachable on 50000"
    fi
  done

  # `talosctl --nodes` is a string-slice flag: it must be repeated (or comma-separated),
  # passing an array as separate args makes Talos interpret them as extra positional args
  # for `image pull` (which accepts exactly 1 image) and will never succeed.
  local -a node_args=()
  for node in "${nodes[@]}"; do
    node_args+=(--nodes "${node}")
  done

  local deadline=$((SECONDS + TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS))
  local last_output=""
  while (( SECONDS < deadline )); do
    if run_with_timeout_capture "${TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS}" talosctl image pull --namespace cri "${node_args[@]}" "${BOOTSTRAP_TOOLS_IMAGE}"; then
      log_success "bootstrap-tools image is pullable and pre-pulled"
      return 0
    fi
    last_output="${RUN_OUTPUT}"
    sleep 10
  done

  log_error "Failed to pre-pull ${BOOTSTRAP_TOOLS_IMAGE} on Talos nodes."
  if [[ -n "${last_output}" ]]; then
    log_error "Last talosctl output:"
    (printf "%s" "${last_output}" | indent_lines >&2) || true
  fi
  if [[ -n "${REGISTRY_HOST}" ]]; then
    log_error "Ensure the local registry is running and the image was pushed:"
    log_error "  curl http://${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}/v2/_catalog"
  else
    log_error "Ensure the image exists and is pullable from the canonical registry domain, then publish it:"
    log_error "  ./shared/scripts/publish-bootstrap-tools-image.sh"
  fi
  log_error "If you use a different image ref, export BOOTSTRAP_TOOLS_IMAGE=<ref> and rerun."
  return 1
}

prepull_validation_tools_core_image() {
  log "Pre-pulling validation tools core image on all nodes: ${VALIDATION_TOOLS_CORE_IMAGE}"

  export TALOSCONFIG="${TALOS_DIR}/talosconfig"

  local -a nodes=()
  nodes+=("${CONTROL_PLANE_IPS[@]}")

  for worker in "${WORKER_IPS[@]}"; do
    if nc -z -w 1 "${worker}" 50000 >/dev/null 2>&1; then
      nodes+=("${worker}")
    else
      log_warn "Skipping validation-tools-core pre-pull on worker ${worker}: Talos API not reachable on 50000"
    fi
  done

  local -a node_args=()
  for node in "${nodes[@]}"; do
    node_args+=(--nodes "${node}")
  done

  local deadline=$((SECONDS + TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS))
  local last_output=""
  while (( SECONDS < deadline )); do
    if run_with_timeout_capture "${TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS}" talosctl image pull --namespace cri "${node_args[@]}" "${VALIDATION_TOOLS_CORE_IMAGE}"; then
      log_success "validation-tools-core image is pullable and pre-pulled"
      return 0
    fi
    last_output="${RUN_OUTPUT}"
    sleep 10
  done

  log_error "Failed to pre-pull ${VALIDATION_TOOLS_CORE_IMAGE} on Talos nodes."
  if [[ -n "${last_output}" ]]; then
    log_error "Last talosctl output:"
    (printf "%s" "${last_output}" | indent_lines >&2) || true
  fi
  if [[ -n "${REGISTRY_HOST}" ]]; then
    log_error "Ensure the local registry is running and the image was pushed:"
    log_error "  curl http://${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}/v2/_catalog"
  fi
  log_error "If you use a different image ref, export VALIDATION_TOOLS_CORE_IMAGE=<ref> and rerun."
  return 1
}

prepull_tenant_provisioner_image() {
  log "Pre-pulling tenant provisioner image on all nodes: ${TENANT_PROVISIONER_IMAGE}"

  export TALOSCONFIG="${TALOS_DIR}/talosconfig"

  local -a nodes=()
  nodes+=("${CONTROL_PLANE_IPS[@]}")

  for worker in "${WORKER_IPS[@]}"; do
    if nc -z -w 1 "${worker}" 50000 >/dev/null 2>&1; then
      nodes+=("${worker}")
    else
      log_warn "Skipping tenant-provisioner pre-pull on worker ${worker}: Talos API not reachable on 50000"
    fi
  done

  local -a node_args=()
  for node in "${nodes[@]}"; do
    node_args+=(--nodes "${node}")
  done

  local deadline=$((SECONDS + TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS))
  local last_output=""
  while (( SECONDS < deadline )); do
    if run_with_timeout_capture "${TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS}" talosctl image pull --namespace cri "${node_args[@]}" "${TENANT_PROVISIONER_IMAGE}"; then
      log_success "tenant-provisioner image is pullable and pre-pulled"
      return 0
    fi
    last_output="${RUN_OUTPUT}"
    sleep 10
  done

  log_error "Failed to pre-pull ${TENANT_PROVISIONER_IMAGE} on Talos nodes."
  if [[ -n "${last_output}" ]]; then
    log_error "Last talosctl output:"
    (printf "%s" "${last_output}" | indent_lines >&2) || true
  fi
  if [[ -n "${REGISTRY_HOST}" ]]; then
    log_error "Ensure the local registry is running and the image was pushed:"
    log_error "  curl http://${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}/v2/_catalog"
  fi
  return 1
}

preflight_darksite_runtime_image_mirror() {
  if [[ "${REGISTRY_PREFLIGHT_DARKSITE_IMAGES}" != "true" ]]; then
    log "Skipping darksite mirror preflight (REGISTRY_PREFLIGHT_DARKSITE_IMAGES=false)"
    return 0
  fi

  if [[ -z "${REGISTRY_HOST}" ]]; then
    log "Skipping darksite mirror preflight (registry.host not configured)"
    return 0
  fi

  if [[ ! -x "${REGISTRY_SYNC_SCRIPT}" ]]; then
    log_error "registry sync helper missing at ${REGISTRY_SYNC_SCRIPT}"
    return 1
  fi

  if ! command -v skopeo >/dev/null 2>&1; then
    log_error "skopeo is required for darksite mirror preflight"
    return 1
  fi

  local darksite_mirror_port=""
  darksite_mirror_port="$(yq -r '.registry.mirrors."registry.example.internal" // ""' "${CONFIG_FILE}" 2>/dev/null || true)"
  if [[ -z "${darksite_mirror_port}" || "${darksite_mirror_port}" == "null" ]]; then
    log_error "Missing required config .registry.mirrors.\"registry.example.internal\" in ${CONFIG_FILE}"
    return 1
  fi

  log "Discovering registry.example.internal runtime images from repo contracts"
  local -a darksite_images=()
  mapfile -t darksite_images < <(
    REGISTRY_SYNC_DISCOVER_ONLY=1 \
      REGISTRY_SYNC_HELM_RENDER=1 \
      "${REGISTRY_SYNC_SCRIPT}" \
      | grep '^registry\.example\.internal/' \
      | grep -Ev '^registry\.example\.internal/deploykube/(bootstrap-tools|tenant-provisioner):' \
      | sort -u
  )

  if [[ ${#darksite_images[@]} -eq 0 ]]; then
    log_warn "No non-DeployKube registry.example.internal image references discovered; skipping mirror preflight"
    return 0
  fi

  log "Validating ${#darksite_images[@]} darksite image reference(s) in mirror ${REGISTRY_HOST}:${darksite_mirror_port} (${REGISTRY_PREFLIGHT_DARKSITE_OS}/${REGISTRY_PREFLIGHT_DARKSITE_ARCH})"
  local failures=0
  local image=""
  for image in "${darksite_images[@]}"; do
    local rest="${image#registry.example.internal/}"
    local mirror_ref="docker://${REGISTRY_HOST}:${darksite_mirror_port}/${rest}"
    if ! skopeo inspect \
      --retry-times 3 \
      --tls-verify=false \
      --override-os "${REGISTRY_PREFLIGHT_DARKSITE_OS}" \
      --override-arch "${REGISTRY_PREFLIGHT_DARKSITE_ARCH}" \
      "${mirror_ref}" >/dev/null 2>&1; then
      log_error "Mirror missing image or platform variant: ${image} (expected at ${REGISTRY_HOST}:${darksite_mirror_port}/${rest})"
      failures=$((failures + 1))
    fi
  done

  if [[ "${failures}" -ne 0 ]]; then
    log_error "darksite mirror preflight failed (${failures} missing/unpullable image refs)"
    log_error "Fix by mirroring required images into ${REGISTRY_HOST}:${darksite_mirror_port} before Stage 1/Argo runs."
    return 1
  fi

  if [[ "${REGISTRY_PREFLIGHT_SAMPLE_NODE_PULL}" == "true" ]]; then
    export TALOSCONFIG="${TALOS_DIR}/talosconfig"
    local sample_image="${darksite_images[0]}"
    local sample_node="${CONTROL_PLANE_IPS[0]}"
    log "Validating Talos node pull path for mirror mapping (${sample_node} -> ${sample_image})"
    if ! run_with_timeout_capture "${TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS}" talosctl image pull --namespace cri --nodes "${sample_node}" "${sample_image}"; then
      log_error "Talos node image pull failed for ${sample_image} on ${sample_node}"
      if [[ -n "${RUN_OUTPUT}" ]]; then
        log_error "talosctl output:"
        printf "%s\n" "${RUN_OUTPUT}" | indent_lines >&2 || true
      fi
      return 1
    fi
  fi

  log_success "darksite mirror preflight passed"
}

cilium_dump_failure_logs() {
  local pod=""
  pod="$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    pod="$(kubectl -n kube-system get pods -o name 2>/dev/null | sed -n 's|^pod/||p' | grep -E '^cilium-' | head -n 1 || true)"
  fi
  if [[ -z "${pod}" ]]; then
    return 0
  fi

  log_error "Cilium pod log excerpts (${pod}):"
  (kubectl -n kube-system logs "${pod}" -c clean-cilium-state --tail=120 2>&1 | indent_lines >&2) || true
  (kubectl -n kube-system logs "${pod}" -c mount-cgroup --tail=120 2>&1 | indent_lines >&2) || true
  (kubectl -n kube-system logs "${pod}" -c cilium-agent --tail=160 2>&1 | indent_lines >&2) || true
}

# =============================================================================
# Parse Configuration
# =============================================================================

parse_deployment_time_config() {
  if [[ ! -f "${DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE}" ]]; then
    log_error "DeploymentConfig file not found: ${DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE}"
    log_error "Set DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE or DEPLOYKUBE_DEPLOYMENT_ID to a valid platform/gitops/deployments/<deploymentId>/config.yaml"
    return 1
  fi

  local parsed_deployment_id=""
  parsed_deployment_id="$(yq -r '.spec.deploymentId // ""' "${DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)"
  if [[ -n "${parsed_deployment_id}" && "${parsed_deployment_id}" != "${DEPLOYKUBE_DEPLOYMENT_ID}" ]]; then
    log_warn "DEPLOYKUBE_DEPLOYMENT_ID (${DEPLOYKUBE_DEPLOYMENT_ID}) differs from DeploymentConfig spec.deploymentId (${parsed_deployment_id})"
  fi

  mapfile -t NTP_UPSTREAM_SERVERS < <(yq -r '.spec.time.ntp.upstreamServers[]?' "${DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE}")
  if [[ ${#NTP_UPSTREAM_SERVERS[@]} -eq 0 ]]; then
    log_error "Missing required NTP upstreams in ${DEPLOYKUBE_DEPLOYMENT_CONFIG_FILE}: spec.time.ntp.upstreamServers[]"
    return 1
  fi

  local ntp_servers_csv
  ntp_servers_csv="$(printf "%s," "${NTP_UPSTREAM_SERVERS[@]}")"
  ntp_servers_csv="${ntp_servers_csv%,}"
  log "DeploymentConfig NTP upstreams (${DEPLOYKUBE_DEPLOYMENT_ID}): ${ntp_servers_csv}"
}

parse_config() {
  log "Parsing configuration from ${CONFIG_FILE}"
  
  CLUSTER_NAME=$(yq -r '.cluster.name' "${CONFIG_FILE}")
  CLUSTER_DOMAIN=$(yq -r '.cluster.domain' "${CONFIG_FILE}")
  TALOS_VERSION=$(yq -r '.cluster.talos_version' "${CONFIG_FILE}")
  KUBERNETES_VERSION=$(yq -r '.cluster.kubernetes_version' "${CONFIG_FILE}")
  
  PROXMOX_HOST=$(yq -r '.proxmox.host' "${CONFIG_FILE}")
  PROXMOX_API_URL=$(yq -r '.proxmox.api_url' "${CONFIG_FILE}")
  PROXMOX_NODE=$(yq -r '.proxmox.node' "${CONFIG_FILE}")
  PROXMOX_STORAGE=$(yq -r '.proxmox.storage' "${CONFIG_FILE}")
  PROXMOX_ISO_STORAGE=$(yq -r '.proxmox.iso_storage' "${CONFIG_FILE}")
  NETWORK_BRIDGE=$(yq -r '.proxmox.bridge' "${CONFIG_FILE}")
  VLAN_ID=$(yq -r '.proxmox.vlan_id // ""' "${CONFIG_FILE}")
  
  NETWORK_GATEWAY=$(yq -r '.network.gateway' "${CONFIG_FILE}")
  mapfile -t NETWORK_DNS_SERVERS < <(yq -r '.network.dns[]?' "${CONFIG_FILE}")
  if [[ ${#NETWORK_DNS_SERVERS[@]} -eq 0 ]]; then
    log_error "Missing required config: .network.dns[]"
    log_error "Stage 0 will not guess DNS servers; set them explicitly in: ${CONFIG_FILE}"
    log_error "Tip: the first DNS server should be an internal resolver that can resolve ${CLUSTER_DOMAIN} (OIDC issuer hostnames depend on it)."
    return 1
  fi
  NETWORK_DNS_PREFLIGHT_ENABLED="$(yq -r '.network.preflight.enabled // true' "${CONFIG_FILE}")"
  NETWORK_DNS_PREFLIGHT_PROBE_NAME="$(yq -r '.network.preflight.probe_name // "example.com"' "${CONFIG_FILE}")"
  NETWORK_DNS_PREFLIGHT_TIMEOUT_SECONDS="$(yq -r '.network.preflight.timeout_seconds // 2' "${CONFIG_FILE}")"
  mapfile -t NETWORK_DNS_PREFLIGHT_REQUIRED_HOSTNAMES < <(yq -r '.network.preflight.required_hostnames[]?' "${CONFIG_FILE}")
  CONTROL_PLANE_VIP=$(yq -r '.network.control_plane_vip' "${CONFIG_FILE}")
  METALLB_RANGE=$(yq -r '.network.metallb_range' "${CONFIG_FILE}")
  NETWORK_BROADCAST="${NETWORK_BROADCAST:-${NETWORK_GATEWAY%.*}.255}"
  
  CP_COUNT=$(yq -r '.nodes.control_plane.count' "${CONFIG_FILE}")
  CP_START_IP=$(yq -r '.nodes.control_plane.start_ip' "${CONFIG_FILE}")
  CP_CORES=$(yq -r '.nodes.control_plane.cores' "${CONFIG_FILE}")
  CP_MEMORY=$(yq -r '.nodes.control_plane.memory_mb' "${CONFIG_FILE}")
  CP_DISK=$(yq -r '.nodes.control_plane.disk_gb' "${CONFIG_FILE}")
  
  # Parse explicit workers array (supports heterogeneous node specs)
  WORKER_COUNT=$(yq -r '.nodes.workers | length' "${CONFIG_FILE}")
  mapfile -t WORKER_NAMES < <(yq -r '.nodes.workers[].name' "${CONFIG_FILE}")
  mapfile -t WORKER_IPS < <(yq -r '.nodes.workers[].ip' "${CONFIG_FILE}")
  mapfile -t WORKER_CORES_ARR < <(yq -r '.nodes.workers[].cores' "${CONFIG_FILE}")
  mapfile -t WORKER_MEMORY_ARR < <(yq -r '.nodes.workers[].memory_mb' "${CONFIG_FILE}")
  mapfile -t WORKER_DISK_ARR < <(yq -r '.nodes.workers[].disk_gb' "${CONFIG_FILE}")
  
  NFS_SERVER=$(yq -r '.storage.nfs.server' "${CONFIG_FILE}")
  NFS_PATH=$(yq -r '.storage.nfs.path' "${CONFIG_FILE}")
  
  # Extract IP suffix for OpenTofu (control plane only)
  CP_START_IP_SUFFIX="${CP_START_IP##*.}"
  
  # Registry configuration
  REGISTRY_HOST=$(yq -r '.registry.host // ""' "${CONFIG_FILE}")
  REGISTRY_LOCAL_PORT=$(yq -r '.registry.local_port // "5000"' "${CONFIG_FILE}")

  parse_deployment_time_config
  
  # Update BOOTSTRAP_TOOLS_IMAGE to use local registry if configured
  if [[ -n "${REGISTRY_HOST}" ]]; then
    BOOTSTRAP_TOOLS_IMAGE="${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}/deploykube/bootstrap-tools:1.4"
    log "Using local registry for bootstrap-tools: ${BOOTSTRAP_TOOLS_IMAGE}"
    VALIDATION_TOOLS_CORE_IMAGE="${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}/deploykube/validation-tools-core:0.1.0"
    log "Using local registry for validation-tools-core: ${VALIDATION_TOOLS_CORE_IMAGE}"
    TENANT_PROVISIONER_IMAGE="${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}/deploykube/tenant-provisioner:0.2.24"
    log "Using local registry for tenant-provisioner: ${TENANT_PROVISIONER_IMAGE}"
  fi
  
  log_success "Configuration parsed: ${CLUSTER_NAME} with ${CP_COUNT} CPs + ${WORKER_COUNT} workers"
}

# =============================================================================
# Preflight
# =============================================================================

preflight_network_dns() {
  local enabled="${NETWORK_DNS_PREFLIGHT_ENABLED}"
  local probe_name="${NETWORK_DNS_PREFLIGHT_PROBE_NAME}"
  local timeout_seconds="${NETWORK_DNS_PREFLIGHT_TIMEOUT_SECONDS}"

  if [[ "${STAGE0_SKIP_DNS_PREFLIGHT:-false}" == "true" ]]; then
    log_warn "Skipping DNS preflight (STAGE0_SKIP_DNS_PREFLIGHT=true)"
    return 0
  fi

  if [[ "${enabled}" != "true" ]]; then
    log "DNS preflight disabled via .network.preflight.enabled=false"
    return 0
  fi

  if ! command -v dig >/dev/null 2>&1; then
    log_error "DNS preflight requires 'dig' (install e.g. 'bind' / 'dnsutils')."
    log_error "Alternatively: set .network.preflight.enabled=false (not recommended)."
    return 1
  fi

  log "DNS preflight: validating .network.dns servers (probe: ${probe_name})"

  local dns=""
  local failures=0
  for dns in "${NETWORK_DNS_SERVERS[@]}"; do
    if ! is_ipv4 "${dns}"; then
      log_error "Invalid DNS server (expected IPv4): ${dns}"
      failures=$((failures + 1))
      continue
    fi

    local answer=""
    answer="$(dig +time="${timeout_seconds}" +tries=1 +short @"${dns}" "${probe_name}" A 2>/dev/null | head -n 1 || true)"
    if [[ -z "${answer}" ]]; then
      log_error "DNS server did not answer probe query: ${dns} (name: ${probe_name})"
      failures=$((failures + 1))
      continue
    fi

    log_success "DNS OK: ${dns} -> ${probe_name} = ${answer}"
  done

  if ((failures > 0)); then
    log_error "DNS preflight failed (${failures} issue(s)). Fix .network.dns in ${CONFIG_FILE} and rerun."
    return 1
  fi

  if [[ ${#NETWORK_DNS_PREFLIGHT_REQUIRED_HOSTNAMES[@]} -eq 0 ]]; then
    log "DNS preflight: no .network.preflight.required_hostnames configured; skipping internal hostname checks"
    return 0
  fi

  local primary_dns="${NETWORK_DNS_SERVERS[0]}"
  log "DNS preflight: validating required hostnames via primary DNS (${primary_dns})"

  local raw_host=""
  for raw_host in "${NETWORK_DNS_PREFLIGHT_REQUIRED_HOSTNAMES[@]}"; do
    local host="${raw_host}"
    host="${host//\$\{CLUSTER_DOMAIN\}/${CLUSTER_DOMAIN}}"
    host="${host//\{\{CLUSTER_DOMAIN\}\}/${CLUSTER_DOMAIN}}"

    local resolved=""
    resolved="$(dig +time="${timeout_seconds}" +tries=1 +short @"${primary_dns}" "${host}" 2>/dev/null | head -n 1 || true)"
    if [[ -z "${resolved}" ]]; then
      log_error "Required hostname did not resolve via primary DNS: ${host} (dns: ${primary_dns})"
      log_error "Fix by: (1) ensuring your internal resolver can resolve it, and (2) placing that resolver first in .network.dns."
      return 1
    fi
    log_success "Required hostname OK: ${host} = ${resolved}"
  done
}

# =============================================================================
# Download and Upload Talos ISO
# =============================================================================

setup_talos_iso() {
  local iso_filename="talos-${TALOS_VERSION}-metal-amd64.iso"
  local iso_local_path="${REPO_ROOT}/tmp/${iso_filename}"
  local iso_proxmox_path="${PROXMOX_ISO_STORAGE}:iso/${iso_filename}"

  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    local bundle_iso="${OFFLINE_BUNDLE_DIR}/talos/${iso_filename}"
    if [[ ! -f "${iso_local_path}" ]]; then
      if [[ ! -f "${bundle_iso}" ]]; then
        log_error "Offline mode enabled (OFFLINE_BUNDLE_DIR set) but Talos ISO is missing:"
        log_error "  expected: ${bundle_iso}"
        log_error "Build a bundle that includes Talos ISO, or set SKIP_TALOS_ISO=1 when building only a bootstrap bundle for an already-provisioned Proxmox ISO store."
        exit 1
      fi
      log "Offline mode: copying Talos ISO from bundle -> ${iso_local_path}"
      mkdir -p "$(dirname "${iso_local_path}")"
      cp "${bundle_iso}" "${iso_local_path}"
    fi
  fi
  
  # Download ISO if not cached
  if [[ ! -f "${iso_local_path}" ]]; then
    if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
      log_error "Offline mode enabled but Talos ISO is not present at ${iso_local_path}"
      exit 1
    fi
    log "Downloading Talos ISO ${TALOS_VERSION}..."
    mkdir -p "$(dirname "${iso_local_path}")"
    
    # Try Image Factory first (includes QEMU guest agent)
    # Generate schematic for QEMU guest agent extension
    local schematic_request='{"customization":{"systemExtensions":{"officialExtensions":["siderolabs/qemu-guest-agent"]}}}'
    local schematic_id
    
    log "Requesting schematic from Image Factory..."
    schematic_id=$(curl -sfSL -X POST -H "Content-Type: application/json" \
      -d "${schematic_request}" \
      "https://factory.talos.dev/schematics" 2>/dev/null | jq -r '.id' 2>/dev/null || echo "")
    
    if [[ -n "${schematic_id}" && "${schematic_id}" != "null" ]]; then
      log "Using schematic: ${schematic_id}"
      local factory_url="https://factory.talos.dev/image/${schematic_id}/${TALOS_VERSION}/metal-amd64.iso"
      
      if curl -fsSL -o "${iso_local_path}" "${factory_url}" 2>/dev/null; then
        log_success "Downloaded Talos ISO from Image Factory (with QEMU guest agent)"
      else
        log_warn "Image Factory download failed, falling back to GitHub releases"
        rm -f "${iso_local_path}"
      fi
    else
      log_warn "Could not get schematic from Image Factory, using GitHub releases"
    fi
    
    # Fallback to GitHub releases (no QEMU guest agent, but works)
    if [[ ! -f "${iso_local_path}" ]]; then
      local github_url="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.iso"
      log "Downloading from GitHub releases: ${github_url}"
      
      if curl -fsSL -o "${iso_local_path}" "${github_url}"; then
        log_success "Downloaded Talos ISO from GitHub releases"
        log_warn "Note: This ISO does not include QEMU guest agent extension"
      else
        log_error "Failed to download Talos ISO from both sources"
        log_error "Please download manually and place at: ${iso_local_path}"
        exit 1
      fi
    fi
  else
    log "Using cached Talos ISO: ${iso_local_path}"
  fi
  
  # Check if ISO exists on Proxmox and upload if needed
  log "Checking if ISO exists on Proxmox storage '${PROXMOX_ISO_STORAGE}'..."
  
  # Check if ISO already exists using pvesm list
  if proxmox_ssh "pvesm list ${PROXMOX_ISO_STORAGE} --content iso 2>/dev/null | grep -q '${iso_filename}'"; then
    log "ISO already present on Proxmox storage"
  else
    log "Uploading ISO to Proxmox storage '${PROXMOX_ISO_STORAGE}'..."
    
    # Get the actual path for this storage
    local storage_path
    storage_path=$(proxmox_ssh "pvesm status --content iso --storage ${PROXMOX_ISO_STORAGE} --output=json 2>/dev/null" | jq -r '.[0].path // empty' 2>/dev/null || echo "")
    
    if [[ -z "${storage_path}" ]]; then
      # Fallback: try to get path from pvesm path command
      storage_path=$(proxmox_ssh "pvesm path ${PROXMOX_ISO_STORAGE}:iso/dummy.iso 2>/dev/null" | sed 's|/dummy.iso$||' || echo "")
    fi
    
    if [[ -z "${storage_path}" ]]; then
      # Last resort: common paths
      if [[ "${PROXMOX_ISO_STORAGE}" == "local" ]]; then
        storage_path="/var/lib/vz/template/iso"
      else
        storage_path="/mnt/pve/${PROXMOX_ISO_STORAGE}/template/iso"
      fi
      log_warn "Could not detect storage path, using: ${storage_path}"
    fi
    
    log "Detected storage path: ${storage_path}"
    proxmox_ssh "mkdir -p '${storage_path}'"
    proxmox_scp "${iso_local_path}" "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}:${storage_path}/${iso_filename}"
    log_success "Uploaded ISO to Proxmox"
  fi
  
  TALOS_ISO_PATH="${iso_proxmox_path}"
}

# =============================================================================
# Run OpenTofu to Provision VMs
# =============================================================================

write_talos_config_patches() {
  local patches_dir="${TOFU_DIR}/config-patches"
  mkdir -p "${patches_dir}"

  local -a mirror_entries=()
  if [[ -n "${REGISTRY_HOST}" ]]; then
    mapfile -t mirror_entries < <(yq -r '.registry.mirrors // {} | to_entries[] | "\(.key) \(.value)"' "${CONFIG_FILE}")
  fi

  # Talos <= 1.10 does not have /var/etc by default; write to an existing directory.
  local oidc_ca_path="/var/lib/kubelet/oidc-ca.crt"
  local oidc_issuer_url="https://keycloak.${CLUSTER_DOMAIN}/realms/deploykube-admin"
  local oidc_ca_bundle="${REPO_ROOT}/shared/certs/deploykube-root-ca.crt"
  [[ -f "${oidc_ca_bundle}" ]] || { log_error "missing OIDC CA bundle at ${oidc_ca_bundle}"; return 1; }

  # Pin etcd peer advertisement to the LAN subnet. Without this, etcd can drift
  # to advertising Cilium-managed 10.0.0.0/8 addresses, which can wedge
  # control-plane recovery after reboot (CNI isn't up yet when etcd must form quorum).
  local lan_cidr=""
  lan_cidr="$(yq -r '.network.lan_cidr // ""' "${CONFIG_FILE}")"
  if [[ -z "${lan_cidr}" ]]; then
    # Backward-compatible fallback for older configs: assume /24 based on gateway.
    # Prefer adding `.network.lan_cidr` explicitly to avoid incorrect assumptions.
    lan_cidr="${NETWORK_GATEWAY%.*}.0/24"
    log_warn "config missing .network.lan_cidr; using derived LAN CIDR: ${lan_cidr}"
  fi

  # NOTE: These patches are written as files because the Talos OpenTofu provider
  # currently fails validation when config_patches are rendered via expressions.
  log "Writing Talos config patch files..."

  {
    cat <<EOF
machine:
  install:
    disk: /dev/sda
    image: registry.example.internal/siderolabs/installer:${TALOS_VERSION}
  time:
    servers:
EOF
    for ntp_server in "${NTP_UPSTREAM_SERVERS[@]}"; do
      printf '      - %s\n' "${ntp_server}"
    done
    cat <<EOF
  features:
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:reader
      allowedKubernetesNamespaces:
        - kube-system
EOF
    if [[ -n "${REGISTRY_HOST}" ]]; then
      cat <<EOF
  registries:
    mirrors:
EOF
      for entry in "${mirror_entries[@]}"; do
        local registry="${entry%% *}"
        local port="${entry##* }"
        cat <<EOF
      ${registry}:
        endpoints:
          - http://${REGISTRY_HOST}:${port}
EOF
      done
      cat <<EOF
      "${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}":
        endpoints:
          - http://${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}
EOF
    fi
    cat <<EOF
  files:
    - path: ${oidc_ca_path}
      permissions: 0644
      op: create
      content: |
EOF
    sed 's/^/        /' "${oidc_ca_bundle}"
    cat <<EOF
cluster:
  etcd:
    advertisedSubnets:
      - ${lan_cidr}
  apiServer:
    extraArgs:
      enable-admission-plugins: ValidatingAdmissionPolicy
      oidc-issuer-url: ${oidc_issuer_url}
      oidc-client-id: kubernetes-api
      oidc-username-claim: preferred_username
      oidc-groups-claim: groups
      oidc-ca-file: ${oidc_ca_path}
    extraVolumes:
      - hostPath: ${oidc_ca_path}
        mountPath: ${oidc_ca_path}
  network:
    cni:
      name: none
  proxy:
    disabled: true
  allowSchedulingOnControlPlanes: false
EOF
  } >"${patches_dir}/controlplane.yaml"

  {
    cat <<EOF
machine:
  install:
    disk: /dev/sda
    image: registry.example.internal/siderolabs/installer:${TALOS_VERSION}
  time:
    servers:
EOF
    for ntp_server in "${NTP_UPSTREAM_SERVERS[@]}"; do
      printf '      - %s\n' "${ntp_server}"
    done
    if [[ -n "${REGISTRY_HOST}" ]]; then
      cat <<EOF
  registries:
    mirrors:
EOF
      for entry in "${mirror_entries[@]}"; do
        local registry="${entry%% *}"
        local port="${entry##* }"
        cat <<EOF
      ${registry}:
        endpoints:
          - http://${REGISTRY_HOST}:${port}
EOF
      done
      cat <<EOF
      "${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}":
        endpoints:
          - http://${REGISTRY_HOST}:${REGISTRY_LOCAL_PORT}
EOF
    fi
    cat <<EOF
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF
  } >"${patches_dir}/worker.yaml"

  log_success "Wrote Talos patch files under ${patches_dir}"
}

provision_vms() {
  # Fast path for reruns: if VMs already exist and Talos configs are present, skip
  # OpenTofu to avoid provider refresh/apply hangs.
  #
  # Use PROXMOX_TALOS_FORCE_TOFU=true to force an OpenTofu plan/apply.
  if [[ "${PROXMOX_TALOS_FORCE_TOFU}" != "true" && "${PROXMOX_TALOS_REUSE_EXISTING_VMS}" == "true" ]]; then
    local all_present=1
    for i in $(seq 1 "${CP_COUNT}"); do
      proxmox_vm_exists "$((1000 + i))" || all_present=0
    done
    for i in $(seq 0 $((WORKER_COUNT - 1))); do
      proxmox_vm_exists "$((2001 + i))" || all_present=0
    done

    if [[ "${all_present}" -eq 1 ]] && talos_configs_present && talos_configs_reusable && talos_configs_match_deployment_ntp; then
      log_warn "Detected existing Proxmox VMs and Talos configs; skipping OpenTofu apply (set PROXMOX_TALOS_FORCE_TOFU=true to force reprovision)"
      REUSED_EXISTING_VMS=true

      local -a vmids=()
      for i in $(seq 1 "${CP_COUNT}"); do vmids+=($((1000 + i))); done
      for i in $(seq 0 $((WORKER_COUNT - 1))); do vmids+=($((2001 + i))); done
      ensure_proxmox_vms_running "${vmids[@]}"

      mapfile -t CONTROL_PLANE_IPS < <(compute_expected_ips "${CP_START_IP}" "${CP_COUNT}")
      # WORKER_IPS is already populated from parse_config
      FIRST_CP_IP="${CONTROL_PLANE_IPS[0]}"
      return 0
    fi
  fi

  log "Provisioning VMs with OpenTofu..."
  
  mkdir -p "${TOFU_DIR}"
  cd "${TOFU_DIR}"
  
  # Create tfvars file from config
  # Build workers array for explicit heterogeneous node specs
  local workers_json=""
  workers_json="workers = ["
  for i in $(seq 0 $((WORKER_COUNT - 1))); do
    local sep=""
    [[ $i -gt 0 ]] && sep=","
    workers_json="${workers_json}${sep}
  {
    name      = \"${WORKER_NAMES[$i]}\"
    ip        = \"${WORKER_IPS[$i]}\"
    cores     = ${WORKER_CORES_ARR[$i]}
    memory_mb = ${WORKER_MEMORY_ARR[$i]}
    disk_gb   = ${WORKER_DISK_ARR[$i]}
  }"
  done
  workers_json="${workers_json}
]"

  local network_dns_hcl="network_dns = ["
  for i in "${!NETWORK_DNS_SERVERS[@]}"; do
    local sep=""
    [[ $i -gt 0 ]] && sep=", "
    network_dns_hcl="${network_dns_hcl}${sep}\"${NETWORK_DNS_SERVERS[$i]}\""
  done
  network_dns_hcl="${network_dns_hcl}]"

  cat > terraform.tfvars <<EOF
cluster_name              = "${CLUSTER_NAME}"
cluster_domain            = "${CLUSTER_DOMAIN}"
kubernetes_version        = "${KUBERNETES_VERSION}"
talos_version             = "${TALOS_VERSION}"

proxmox_api_url           = "${PROXMOX_API_URL}"
proxmox_node              = "${PROXMOX_NODE}"
proxmox_storage           = "${PROXMOX_STORAGE}"
proxmox_iso_storage       = "${PROXMOX_ISO_STORAGE}"
network_bridge            = "${NETWORK_BRIDGE}"
vlan_id                   = ${VLAN_ID:-null}

network_gateway           = "${NETWORK_GATEWAY}"
${network_dns_hcl}
control_plane_vip         = "${CONTROL_PLANE_VIP}"
metallb_range             = "${METALLB_RANGE}"

control_plane_count             = ${CP_COUNT}
control_plane_start_ip_suffix   = ${CP_START_IP_SUFFIX}
control_plane_cores             = ${CP_CORES}
control_plane_memory            = ${CP_MEMORY}
control_plane_disk              = ${CP_DISK}

${workers_json}

nfs_server                = "${NFS_SERVER}"
nfs_path                  = "${NFS_PATH}"

talos_iso_path            = "${TALOS_ISO_PATH}"
EOF

  write_talos_config_patches

  log "Initializing OpenTofu..."
  if [[ "${TOFU_INIT_UPGRADE}" == "true" ]]; then
    tofu init -upgrade
  else
    tofu init
  fi
	  
  log "Planning infrastructure..."
  log "Using OpenTofu parallelism=${TOFU_PARALLELISM} lock-timeout=${TOFU_LOCK_TIMEOUT}"
  tofu plan \
    -lock-timeout="${TOFU_LOCK_TIMEOUT}" \
    -parallelism="${TOFU_PARALLELISM}" \
    -var-file=terraform.tfvars \
    -out=tfplan
  
  log "Applying infrastructure..."
  tofu apply \
    -lock-timeout="${TOFU_LOCK_TIMEOUT}" \
    -parallelism="${TOFU_PARALLELISM}" \
    -auto-approve \
    tfplan
  
  # Capture outputs
  mapfile -t CONTROL_PLANE_IPS < <(tofu output -json control_plane_ips | jq -r '.[]')
  mapfile -t WORKER_IPS < <(tofu output -json worker_ips | jq -r '.[]')
  FIRST_CP_IP="${CONTROL_PLANE_IPS[0]}"
  
  log_success "VMs provisioned successfully"
}

# =============================================================================
# Discover VM IPs (DHCP assigned in maintenance mode)
# =============================================================================

discover_vm_ip() {
  local vmid="$1"
  local max_attempts="${2:-60}"
  local ip=""
  local did_reset_for_dhcp="false"
  
  # Log to stderr to avoid mixing with IP output
  echo "[stage0] Discovering IP for VM ${vmid}..." >&2
  
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    # Try QEMU guest agent first (works if Talos has guest agent extension)
    ip=$(proxmox_ssh "qm guest cmd ${vmid} network-get-interfaces 2>/dev/null" 2>/dev/null | \
         jq -r '.[] | select(.name != "lo") | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4") | .["ip-address"]' 2>/dev/null | head -1 || echo "")
    
    if [[ -n "${ip}" && "${ip}" != "null" ]]; then
      echo "${ip}"
      return 0
    fi
    
    # Fallback: resolve the VM MAC and try non-agent discovery methods.
    local mac
    mac=$(proxmox_ssh "qm config ${vmid} 2>/dev/null | grep -oP 'virtio=\\K[^,]+'" 2>/dev/null || echo "")
    if [[ -n "${mac}" ]]; then
      # Robust path: sniff DHCP traffic on the Proxmox bridge for this VM's MAC.
      # This works even when neighbor/ARP caches are empty (common with VLAN-aware bridges).
      local dhcp_ip
      dhcp_ip=$(
        proxmox_ssh "command -v tcpdump >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && timeout 8 tcpdump -i '${NETWORK_BRIDGE}' -nn -l -c 12 \"ether host ${mac} and udp and (port 67 or port 68)\" 2>/dev/null | sed -n 's/.*> \\([0-9.]\\+\\)\\.68:.*BOOTP\\/DHCP, Reply.*/\\1/p' | head -n1" 2>/dev/null || echo ""
      )
      if [[ -n "${dhcp_ip}" && "${dhcp_ip}" != "null" ]]; then
        echo "${dhcp_ip}"
        return 0
      fi

      # If the VM already did DHCP before we started sniffing, the passive sniff above will be empty.
      # As a one-time recovery, force a reset to trigger a new DHCP exchange and sniff it.
      if [[ "${did_reset_for_dhcp}" != "true" && "${attempt}" -ge 5 ]]; then
        did_reset_for_dhcp="true"
        dhcp_ip=$(
          proxmox_ssh "command -v tcpdump >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && \
tmp=\$(mktemp /tmp/deploykube-dhcp.XXXXXX) && \
(timeout 20 tcpdump -i '${NETWORK_BRIDGE}' -nn -l -c 20 \"ether host ${mac} and udp and (port 67 or port 68)\" 2>/dev/null >\"\$tmp\") & \
pid=\$! && \
qm reset ${vmid} >/dev/null 2>&1 || qm reboot ${vmid} >/dev/null 2>&1 || true && \
wait \$pid >/dev/null 2>&1 || true && \
sed -n 's/.*> \\([0-9.]\\+\\)\\.68:.*BOOTP\\/DHCP, Reply.*/\\1/p' \"\$tmp\" | head -n1 && \
rm -f \"\$tmp\"" 2>/dev/null || echo ""
        )
        if [[ -n "${dhcp_ip}" && "${dhcp_ip}" != "null" ]]; then
          echo "${dhcp_ip}"
          return 0
        fi
      fi

      # Legacy path: try neighbor/ARP caches on Proxmox host.
      # Ping the broadcast to populate table
      proxmox_ssh "ping -c 1 -b '${NETWORK_BROADCAST}' >/dev/null 2>&1" || true
      
      # Try 'ip neighbor' (modern) then 'arp' (legacy).
      # Strictly filter for FAILED or INCOMPLETE states. STALE is acceptable but we prioritize reachable.
      # We fetch all matching IPs and then verify them via Port 50000 check from Proxmox.
      # NOTE: Using cut instead of awk to avoid escaping issues over SSH.
      local candidates
      candidates=$(proxmox_ssh "ip neighbor show 2>/dev/null | grep -i '${mac}' | grep -vE 'FAILED|INCOMPLETE' | cut -d' ' -f1" 2>/dev/null || echo "")
      if [[ -z "${candidates}" ]]; then
        # Legacy fallback using arp
        candidates=$(proxmox_ssh "arp -an 2>/dev/null | grep -i '${mac}' | grep -oP '\\(\\K[^)]+'" 2>/dev/null || echo "")
      fi

      for candidate_ip in ${candidates}; do
        if [[ -n "${candidate_ip}" && "${candidate_ip}" != "null" ]]; then
          # Verify if Port 50000 is open on this IP from the Proxmox host (fast check)
          if proxmox_ssh "nc -zv -w 1 ${candidate_ip} 50000 >/dev/null 2>&1"; then
            echo "${candidate_ip}"
            return 0
          fi
        fi
      done
    fi
    
    if [[ $((attempt % 10)) -eq 0 ]]; then
      echo "[stage0] Still waiting for VM ${vmid} IP... (attempt ${attempt}/${max_attempts})" >&2
    fi
    sleep 5
  done
  
  return 1
}

# =============================================================================
# Apply Talos Configurations
# =============================================================================

apply_talos_configs() {
  export TALOSCONFIG="${TALOS_DIR}/talosconfig"

  if [[ "${REUSED_EXISTING_VMS}" == "true" ]]; then
    log_warn "Reuse mode: reconciling Talos nodes via static IPs (skipping DHCP discovery)"

    for i in $(seq 1 "${CP_COUNT}"); do
      local ip="${CONTROL_PLANE_IPS[$((i - 1))]}"
      local node_config="${TALOS_DIR}/${CLUSTER_NAME}-cp-${i}.yaml"
      local mode
      mode="$(talos_node_mode "${ip}" || true)"

      case "${mode}" in
        secure)
          log "Control plane ${CLUSTER_NAME}-cp-${i} is reachable (secure API) at ${ip}"
          ;;
        maintenance)
          log_warn "Control plane ${CLUSTER_NAME}-cp-${i} is in maintenance mode at ${ip}; reapplying config"
          talosctl apply-config --insecure --nodes "${ip}" --file "${node_config}"
          wait_for_talos_api "${ip}" "${TALOS_REBOOT_WAIT_TIMEOUT_SECONDS}" || { diagnose_talos_node "${ip}"; exit 1; }
          ;;
        *)
          log_error "Control plane ${CLUSTER_NAME}-cp-${i} is not reachable at ${ip}"
          diagnose_talos_node "${ip}"
          exit 1
          ;;
      esac
    done

    for i in $(seq 0 $((WORKER_COUNT - 1))); do
      local name="${WORKER_NAMES[$i]}"
      local ip="${WORKER_IPS[$i]}"
      local node_config="${TALOS_DIR}/${CLUSTER_NAME}-${name}.yaml"
      local mode
      mode="$(talos_node_mode "${ip}" || true)"

      case "${mode}" in
        secure)
          log "Worker ${CLUSTER_NAME}-${name} is reachable (secure API) at ${ip}"
          ;;
        maintenance)
          log_warn "Worker ${CLUSTER_NAME}-${name} is in maintenance mode at ${ip}; reapplying config"
          talosctl apply-config --insecure --nodes "${ip}" --file "${node_config}"
          wait_for_talos_api "${ip}" "${TALOS_REBOOT_WAIT_TIMEOUT_SECONDS}" || { diagnose_talos_node "${ip}"; exit 1; }
          ;;
        *)
          # Some Talos versions/configurations won't expose the Talos API on workers until later in bootstrap.
          # Treat kubelet as the liveness signal here to avoid deadlocking Stage 0 before etcd bootstrap.
          if wait_for_kubelet_api "${ip}" 5; then
            log_warn "Worker ${CLUSTER_NAME}-${name} Talos API is not reachable at ${ip}, but kubelet is up (continuing)"
          else
            log_error "Worker ${CLUSTER_NAME}-${name} is not reachable at ${ip}"
            diagnose_talos_node "${ip}"
            exit 1
          fi
          ;;
      esac
    done

    log_success "Reuse mode: Talos nodes are reachable on static IPs"
    return 0
  fi

  log "Waiting for VMs to boot and get DHCP addresses..."
  sleep "${TALOS_DHCP_BOOT_WAIT_SECONDS}"  # Give VMs time to boot and get DHCP
  
  # Build arrays of VMIDs and their configs
  declare -a CP_VMIDS=()
  declare -a WORKER_VMIDS=()
  
  for i in $(seq 1 ${CP_COUNT}); do
    CP_VMIDS+=($((1000 + i)))
  done
  for i in $(seq 0 $((WORKER_COUNT - 1))); do
    WORKER_VMIDS+=($((2001 + i)))
  done
  
  log "Applying Talos configurations to control plane nodes..."
  local idx=0
  for vmid in "${CP_VMIDS[@]}"; do
    local node_config="${TALOS_DIR}/${CLUSTER_NAME}-cp-$((idx + 1)).yaml"
    local node_name="${CLUSTER_NAME}-cp-$((idx + 1))"
    local static_ip="${CONTROL_PLANE_IPS[$idx]}"
    
    # Optimization: if the node is already reachable on its static IP AND the API is up, skip discovery.
    # We check port 50000 to ensure we aren't picking up a stale ARP entry during a reboot/reset.
    if ping -c 1 -W 1 "${static_ip}" >/dev/null 2>&1 && wait_for_tcp_port "${static_ip}" 50000 2 "Check API" >/dev/null 2>&1; then
      log "Control plane ${node_name} is already reachable on its static IP: ${static_ip}"
      dhcp_ip="${static_ip}"
    else
      # Discover actual DHCP IP
      dhcp_ip=$(discover_vm_ip "${vmid}" 60)
      
      if [[ -z "${dhcp_ip}" ]]; then
        log_error "Could not discover IP for VM ${vmid} (${node_name})"
        log_error "Check Proxmox console for the VM's IP address"
        exit 1
      fi
      log "Discovered ${node_name} at DHCP IP: ${dhcp_ip}"
    fi
    
    # Wait for Talos API to be ready (port 50000)
    log "Waiting for Talos API on ${dhcp_ip}..."
    wait_for_tcp_port "${dhcp_ip}" 50000 "${TALOS_TALOSAPI_WAIT_TIMEOUT_SECONDS}" "Talos API" || exit 1
    log "Talos API is reachable on ${dhcp_ip}"
    
    local mode
    mode="$(talos_node_mode "${dhcp_ip}" || true)"
    case "${mode}" in
      secure)
        log "Applying config to ${node_name} (${dhcp_ip}) via secure API..."
        talosctl apply-config --nodes "${dhcp_ip}" --file "${node_config}"
        ;;
      maintenance)
        log "Applying config to ${node_name} (${dhcp_ip}) via maintenance API (--insecure)..."
        talosctl apply-config --insecure --nodes "${dhcp_ip}" --file "${node_config}"
        ;;
      *)
        log_error "Talos node ${node_name} at ${dhcp_ip} is not reachable via API"
        diagnose_talos_node "${dhcp_ip}"
        exit 1
        ;;
    esac
    log_success "Applied config to ${node_name}"
    
    idx=$((idx + 1))
  done
  
  log "Applying Talos configurations to worker nodes..."
  idx=0
  for vmid in "${WORKER_VMIDS[@]}"; do
    local name="${WORKER_NAMES[$idx]}"
    local node_config="${TALOS_DIR}/${CLUSTER_NAME}-${name}.yaml"
    local node_name="${CLUSTER_NAME}-${name}"
    local static_ip="${WORKER_IPS[$idx]}"

    # Optimization: if the node is already reachable on its static IP and API is up, skip discovery.
    if ping -c 1 -W 1 "${static_ip}" >/dev/null 2>&1 && wait_for_tcp_port "${static_ip}" 50000 2 "Check API" >/dev/null 2>&1; then
      log "Worker ${node_name} is already reachable on its static IP: ${static_ip}"
      dhcp_ip="${static_ip}"
    # Rerun safety: if the node is already configured (kubelet is up) but the Talos API is not
    # reachable (common in some environments), don't attempt DHCP discovery or config reapply.
    elif ping -c 1 -W 1 "${static_ip}" >/dev/null 2>&1 && wait_for_tcp_port "${static_ip}" 10250 2 "Check Kubelet" >/dev/null 2>&1; then
      log_warn "Worker ${node_name} Talos API is not reachable on ${static_ip}:50000, but kubelet is up; skipping apply-config"
      idx=$((idx + 1))
      continue
    else
      # Discover actual DHCP IP
      dhcp_ip=$(discover_vm_ip "${vmid}" 60)
      
      if [[ -z "${dhcp_ip}" ]]; then
        log_error "Could not discover IP for VM ${vmid} (${node_name})"
        exit 1
      fi
      log "Discovered ${node_name} at DHCP IP: ${dhcp_ip}"
    fi
    
    # Wait for Talos API (port 50000)
    log "Waiting for Talos API on ${dhcp_ip}..."
    wait_for_tcp_port "${dhcp_ip}" 50000 "${TALOS_TALOSAPI_WAIT_TIMEOUT_SECONDS}" "Talos API" || exit 1
    log "Talos API is reachable on ${dhcp_ip}"
    
    local mode
    mode="$(talos_node_mode "${dhcp_ip}" || true)"
    case "${mode}" in
      secure)
        log "Applying config to ${node_name} (${dhcp_ip}) via secure API..."
        talosctl apply-config --nodes "${dhcp_ip}" --file "${node_config}"
        ;;
      maintenance)
        log "Applying config to ${node_name} (${dhcp_ip}) via maintenance API (--insecure)..."
        talosctl apply-config --insecure --nodes "${dhcp_ip}" --file "${node_config}"
        ;;
      *)
        log_error "Talos node ${node_name} at ${dhcp_ip} is not reachable via API"
        diagnose_talos_node "${dhcp_ip}"
        exit 1
        ;;
    esac
    log_success "Applied config to ${node_name}"
    
    idx=$((idx + 1))
  done
  
  log "Waiting for nodes to reboot and come up on their static IPs..."
  for ip in "${CONTROL_PLANE_IPS[@]}"; do
    log "Waiting for Talos API on control plane node ${ip}..."
    wait_for_talos_api "${ip}" "${TALOS_REBOOT_WAIT_TIMEOUT_SECONDS}" || { diagnose_talos_node "${ip}"; exit 1; }
  done
  for ip in "${WORKER_IPS[@]}"; do
    log "Waiting for kubelet on worker node ${ip}..."
    wait_for_kubelet_api "${ip}" "${TALOS_REBOOT_WAIT_TIMEOUT_SECONDS}" || { diagnose_talos_node "${ip}"; exit 1; }

    # Best-effort: check whether Talos API is reachable yet.
    if ! nc -z -w 2 "${ip}" 50000 >/dev/null 2>&1; then
      log_warn "Talos API is not reachable on worker ${ip}:50000 yet; continuing (Kubelet is up)"
    fi
  done
  log_success "All nodes are reachable on their static IPs"
}

# =============================================================================
# Bootstrap Kubernetes Cluster
# =============================================================================

bootstrap_cluster() {
  export TALOSCONFIG="${TALOS_DIR}/talosconfig"
  
  log "Bootstrapping etcd on first control plane (${FIRST_CP_IP})..."

  # Ensure the node is actually reachable before attempting bootstrap.
  wait_for_talos_api "${FIRST_CP_IP}" "${TALOS_REBOOT_WAIT_TIMEOUT_SECONDS}" || { diagnose_talos_node "${FIRST_CP_IP}"; exit 1; }

  # Always attempt bootstrap; it's safe to rerun and avoids false positives (kubeconfig can
  # often be generated even when etcd hasn't been bootstrapped yet).
  local deadline=$((SECONDS + TALOS_BOOTSTRAP_TIMEOUT_SECONDS))
  local last_output=""
  local bootstrap_cmd_timeout="${TALOSCTL_BOOTSTRAP_CMD_TIMEOUT_SECONDS:-60}"

  while (( SECONDS < deadline )); do
    local output=""
    if run_with_timeout_capture "${bootstrap_cmd_timeout}" talosctl --endpoints "${FIRST_CP_IP}" --nodes "${FIRST_CP_IP}" bootstrap; then
      output="${RUN_OUTPUT}"
      log_success "Talos bootstrap command succeeded on ${FIRST_CP_IP}"
      break
    else
      local status=$?
      output="${RUN_OUTPUT}"
      if [[ "${status}" -eq 124 ]]; then
        log_warn "talosctl bootstrap timed out after ${bootstrap_cmd_timeout}s; retrying (overall timeout ${TALOS_BOOTSTRAP_TIMEOUT_SECONDS}s)"
      fi
    fi

    # Some Talos versions return non-zero when bootstrap is already done/in progress; treat that as success.
    if printf "%s" "${output}" | grep -qiE "already.*(performed|bootstrapped|initialized)|bootstrap.*(already|in progress|begun|started)"; then
      log_success "Talos bootstrap is already performed/in progress on ${FIRST_CP_IP}"
      break
    fi

    last_output="${output}"
    sleep 10
  done

  if (( SECONDS >= deadline )); then
    log_error "Timeout waiting for Talos bootstrap on ${FIRST_CP_IP} after ${TALOS_BOOTSTRAP_TIMEOUT_SECONDS}s"
    if [[ -n "${last_output}" ]]; then
      log_error "Last talosctl output:"
      printf "%s\n" "${last_output}" | indent_lines >&2
    fi
    diagnose_talos_node "${FIRST_CP_IP}"
    exit 1
  fi

  log "Fetching kubeconfig from ${FIRST_CP_IP}..."
  local kubeconfig_deadline=$((SECONDS + KUBECONFIG_WAIT_TIMEOUT_SECONDS))
  local kubeconfig_out=""
  while (( SECONDS < kubeconfig_deadline )); do
    if run_with_timeout_capture 60 talosctl --endpoints "${FIRST_CP_IP}" --nodes "${FIRST_CP_IP}" kubeconfig --force "${REPO_ROOT}/tmp/kubeconfig-prod"; then
      kubeconfig_out="${RUN_OUTPUT}"
      break
    fi
    sleep 10
  done

  if (( SECONDS >= kubeconfig_deadline )); then
    log_error "Timeout fetching kubeconfig from ${FIRST_CP_IP} after ${KUBECONFIG_WAIT_TIMEOUT_SECONDS}s"
    if [[ -n "${kubeconfig_out}" ]]; then
      log_error "Last talosctl kubeconfig output:"
      printf "%s\n" "${kubeconfig_out}" | indent_lines >&2
    fi
    diagnose_talos_node "${FIRST_CP_IP}"
    exit 1
  fi
  
  export KUBECONFIG="${REPO_ROOT}/tmp/kubeconfig-prod"

  log "Waiting for Kubernetes API to become ready (VIP ${CONTROL_PLANE_VIP}:6443)..."
  local api_deadline=$((SECONDS + KUBERNETES_API_WAIT_TIMEOUT_SECONDS))
  while (( SECONDS < api_deadline )); do
    if kubectl --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  if (( SECONDS >= api_deadline )); then
    log_error "Timeout waiting for Kubernetes API after ${KUBERNETES_API_WAIT_TIMEOUT_SECONDS}s"
    log_error "Last known cluster state (best effort):"
    (kubectl get nodes -o wide 2>&1 | indent_lines >&2) || true
    exit 1
  fi

  # Nodes might not be Ready until a CNI is installed (we install Cilium next),
  # but they should register with the API. Wait for registration here, and for Ready later.
  log "Waiting for Kubernetes nodes to register with the API..."
  local expected_nodes=$((CP_COUNT + WORKER_COUNT))
  if ! wait_for_k8s_nodes "${expected_nodes}" 600; then
    log_warn "Proceeding with fewer nodes registered than expected (${expected_nodes}); continuing to CNI install"
  fi

  log_success "Kubernetes API is up (nodes registered)"
  kubectl get nodes -o wide
}

# =============================================================================
# Install Core Networking
# =============================================================================

install_networking() {
  export KUBECONFIG="${REPO_ROOT}/tmp/kubeconfig-prod"
  
  log "Installing Cilium CNI..."
  local cilium_chart="cilium/cilium"
  local -a cilium_chart_args=(--version "${CILIUM_CHART_VERSION}")
  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    local bundle_chart="${OFFLINE_BUNDLE_DIR}/charts/cilium-${CILIUM_CHART_VERSION}.tgz"
    if [[ ! -f "${bundle_chart}" ]]; then
      log_error "Offline mode enabled but Cilium chart is missing from bundle: ${bundle_chart}"
      exit 1
    fi
    cilium_chart="${bundle_chart}"
    cilium_chart_args=()
    log "Offline mode: using Cilium chart from bundle (${bundle_chart})"
  else
    helm_cmd repo add cilium https://helm.cilium.io/ || true
    helm_cmd repo update
  fi

  if [[ "${FORCE_CILIUM_UPGRADE}" != "true" ]] && cilium_is_healthy; then
    log_success "Cilium is already installed and healthy; skipping upgrade"
  else
    local cilium_timeout="${CILIUM_HELM_TIMEOUT:-20m}"
    log "Cilium helm timeout: ${cilium_timeout} (set FORCE_CILIUM_UPGRADE=true to force upgrade on reruns)"
  
    # Prefer running the operator on worker nodes (when present) to reduce churn during control-plane reboots/recovery.
    if ! run_helm_with_progress "${cilium_timeout}" upgrade --install cilium "${cilium_chart}" \
      --namespace kube-system \
      "${cilium_chart_args[@]}" \
      --set kubeProxyReplacement=true \
      --set socketLB.enabled=true \
      --set socketLB.hostNamespaceOnly=true \
      --set cni.exclusive=false \
      --set k8sServiceHost="${CONTROL_PLANE_VIP}" \
      --set k8sServicePort=6443 \
      --set resources.requests.cpu=145m \
      --set resources.requests.memory=288Mi \
      --set resources.limits.memory=432Mi \
      --set envoy.resources.requests.cpu=15m \
      --set envoy.resources.requests.memory=80Mi \
      --set envoy.resources.limits.memory=120Mi \
      --set operator.resources.requests.cpu=15m \
      --set operator.resources.requests.memory=96Mi \
      --set operator.resources.limits.memory=144Mi \
      --set hubble.relay.resources.requests.cpu=15m \
      --set hubble.relay.resources.requests.memory=64Mi \
      --set hubble.relay.resources.limits.memory=96Mi \
      --set hubble.ui.backend.resources.requests.cpu=15m \
      --set hubble.ui.backend.resources.requests.memory=32Mi \
      --set hubble.ui.backend.resources.limits.memory=48Mi \
      --set hubble.ui.frontend.resources.requests.cpu=15m \
      --set hubble.ui.frontend.resources.requests.memory=32Mi \
      --set hubble.ui.frontend.resources.limits.memory=48Mi \
      --set-string 'securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}' \
      --set-string 'securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}' \
      --set 'operator.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100' \
      --set 'operator.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key=node-role.kubernetes.io/control-plane' \
      --set 'operator.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator=DoesNotExist' \
      --set 'operator.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[1].weight=50' \
      --set 'operator.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[1].preference.matchExpressions[0].key=node-role.kubernetes.io/master' \
      --set 'operator.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[1].preference.matchExpressions[0].operator=DoesNotExist' \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true \
      --wait \
      --timeout "${cilium_timeout}"; then
      local status=$?
      log_error "Cilium install/upgrade failed (exit ${status})"
      if [[ -n "${RUN_OUTPUT}" ]]; then
        log_error "Helm output (tail):"
        printf "%s\n" "${RUN_OUTPUT}" | tail -n 80 | indent_lines >&2
      fi
      log_error "Diagnostics (kube-system):"
      (kubectl -n kube-system get pods -o wide 2>&1 | indent_lines >&2) || true
      (kubectl -n kube-system describe ds/cilium 2>&1 | tail -n 200 | indent_lines >&2) || true
      (kubectl -n kube-system describe deploy/hubble-relay 2>&1 | tail -n 120 | indent_lines >&2) || true
      (kubectl -n kube-system describe deploy/hubble-ui 2>&1 | tail -n 120 | indent_lines >&2) || true
      cilium_dump_failure_logs
      exit 1
    fi
  fi
  
  log_success "Cilium installed"

  log "Waiting for all nodes to be Ready (after CNI install)..."
  wait_for_k8s_nodes_ready 1 900
  log_success "All nodes are Ready"

  log "Applying CoreDNS resource policy..."
  kubectl -n kube-system patch deployment coredns --type merge -p '{
    "spec": {
      "template": {
        "spec": {
          "containers": [
            {
              "name": "coredns",
              "resources": {
                "requests": {
                  "cpu": "15m",
                  "memory": "64Mi"
                },
                "limits": {
                  "memory": "96Mi"
                }
              }
            }
          ]
        }
      }
    }
  }' >/dev/null 2>&1 || log_warn "Skipping CoreDNS patch (kube-system/deploy coredns not found or patch failed)"
  
  log "Installing Gateway API CRDs..."
  if [[ ! -f "${GATEWAY_API_MANIFEST_PATH}" ]]; then
    log_error "Missing Gateway API manifest: ${GATEWAY_API_MANIFEST_PATH}"
    exit 1
  fi
  kubectl apply -f "${GATEWAY_API_MANIFEST_PATH}"
  log_success "Gateway API CRDs installed"
  
  # MetalLB is GitOps-managed in this repo (apps/base/networking-metallb*).
  # If Stage 1/Argo CD is already installed, do not attempt to manage MetalLB from Stage 0:
  # Helm uses apply semantics and will hit managed-fields conflicts with the Argo CD controller.
  if argocd_is_installed; then
    if metallb_is_healthy; then
      log_success "Argo CD detected and MetalLB is already healthy; skipping MetalLB install/config in Stage 0"
    else
      log_warn "Argo CD detected; skipping MetalLB install/config in Stage 0 (manage via Argo apps: networking-metallb + networking-metallb-config)"
    fi
    return 0
  fi

  log "Installing MetalLB..."
  local metallb_chart="metallb/metallb"
  local -a metallb_chart_args=(--version "${METALLB_CHART_VERSION}")
  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    local bundle_chart="${OFFLINE_BUNDLE_DIR}/charts/metallb-${METALLB_CHART_VERSION}.tgz"
    if [[ ! -f "${bundle_chart}" ]]; then
      log_error "Offline mode enabled but MetalLB chart is missing from bundle: ${bundle_chart}"
      exit 1
    fi
    metallb_chart="${bundle_chart}"
    metallb_chart_args=()
    log "Offline mode: using MetalLB chart from bundle (${bundle_chart})"
  else
    helm_cmd repo add metallb https://metallb.github.io/metallb || true
    helm_cmd repo update
  fi

  local skip_metallb_chart=false
  if [[ "${FORCE_METALLB_UPGRADE:-false}" != "true" ]] && metallb_is_healthy; then
    log_success "MetalLB is already installed and healthy; skipping chart upgrade (set FORCE_METALLB_UPGRADE=true to force)"
    skip_metallb_chart=true
  fi

  # MetalLB speaker/controllers require privileged operations (host networking/caps) and will be blocked
  # if Pod Security Admission enforces "restricted"/"baseline" in the namespace.
  if [[ "${METALLB_CONFIGURE_POD_SECURITY}" == "true" ]]; then
    log "Configuring Pod Security Admission labels for metallb-system (${METALLB_POD_SECURITY_LEVEL})..."
    ensure_namespace_pod_security metallb-system "${METALLB_POD_SECURITY_LEVEL}"
  fi
  
  if [[ "${skip_metallb_chart}" != "true" ]]; then
    helm_cmd upgrade --install metallb "${metallb_chart}" \
      --namespace metallb-system \
      --create-namespace \
      "${metallb_chart_args[@]}" \
      --timeout "${METALLB_HELM_TIMEOUT:-15m}" \
      --wait
  fi
  
  # Wait for MetalLB to be ready
  kubectl -n metallb-system wait --for=condition=Ready pods --all --timeout=120s
  
  # Configure MetalLB IP pool
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: orbstack-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: orbstack-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - orbstack-pool
EOF
  
  log_success "MetalLB installed and configured with range ${METALLB_RANGE}"
}

# =============================================================================
# Install NFS Storage Provisioner
# =============================================================================

install_storage() {
  export KUBECONFIG="${REPO_ROOT}/tmp/kubeconfig-prod"
  
  log "Installing NFS subdir external provisioner..."
  local chart_ref="nfs-subdir-external-provisioner/nfs-subdir-external-provisioner"
  local -a chart_version_args=(--version "${NFS_PROVISIONER_CHART_VERSION}")
  if [[ -n "${OFFLINE_BUNDLE_DIR}" ]]; then
    local bundle_chart="${OFFLINE_BUNDLE_DIR}/charts/nfs-subdir-external-provisioner-${NFS_PROVISIONER_CHART_VERSION}.tgz"
    if [[ ! -f "${bundle_chart}" ]]; then
      log_error "Offline mode enabled but NFS provisioner chart is missing from bundle: ${bundle_chart}"
      exit 1
    fi
    chart_ref="${bundle_chart}"
    chart_version_args=()
    log "Offline mode: using NFS provisioner chart from bundle (${bundle_chart})"
  else
    helm_cmd repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ || true
    helm_cmd repo update
  fi

  # The provisioner pod mounts the NFS export via an `nfs` volume which is blocked under
  # Pod Security "restricted" (and often "baseline"). Label the namespace accordingly.
  if [[ "${NFS_CONFIGURE_POD_SECURITY}" == "true" ]]; then
    log "Configuring Pod Security Admission labels for storage-system (${NFS_POD_SECURITY_LEVEL})..."
    ensure_namespace_pod_security storage-system "${NFS_POD_SECURITY_LEVEL}"
  fi

  # Ensure the export root exists (best effort) and create the `rwo/` subdir used by the default StorageClass contract.
  ensure_nfs_path_exists_on_server "${NFS_SERVER}" "${NFS_PATH}"
  local nfs_rwo_path="${NFS_PATH%/}/${NFS_RWO_SUBDIR}"
  ensure_nfs_path_exists_on_server "${NFS_SERVER}" "${nfs_rwo_path}"

  # NFS provisioner is GitOps-managed in this repo (apps/base/storage-nfs-provisioner.yaml).
  # If Stage 1/Argo CD is already installed, do not attempt to install/upgrade it here.
  if argocd_is_installed; then
    if storage_nfs_provisioner_is_healthy; then
      log_success "Argo CD detected and NFS provisioner is already healthy; skipping chart install in Stage 0"
    else
      log_warn "Argo CD detected; skipping chart install in Stage 0 (manage via Argo app: storage-nfs-provisioner)"
    fi

    if kubectl get storageclass shared-rwo >/dev/null 2>&1; then
      log_success "StorageClass shared-rwo already exists; skipping apply"
    else
      kubectl apply -f "${REPO_ROOT}/platform/gitops/components/storage/shared-rwo-storageclass/storageclass-rwo.yaml" >/dev/null
      log_success "StorageClass shared-rwo applied (bootstrap helper)"
    fi
    kubectl get storageclasses
    return 0
  fi
  
  # Install a single NFS provisioner (release name matches GitOps) and use StorageClass
  # path patterns to create per-PVC directories under rwo/.
  local release_name="nfs-provisioner"
  local release_namespace="storage-system"

  local -a helm_args=(
    upgrade --install "${release_name}" "${chart_ref}"
  )
  helm_args+=("${chart_version_args[@]}")
  helm_args+=(
    --namespace "${release_namespace}"
    --create-namespace
    --set "nfs.server=${NFS_SERVER}"
    --set "nfs.path=${NFS_PATH}"
    --set nfs.mountOptions[0]=vers=4.1
    --set nfs.mountOptions[1]=rsize=1048576
    --set nfs.mountOptions[2]=wsize=1048576
    --set nfs.mountOptions[3]=hard
    --set nfs.mountOptions[4]=timeo=600
    --set nfs.mountOptions[5]=retrans=2
    --set storageClass.create=false
    --timeout "${NFS_PROVISIONER_HELM_TIMEOUT:-15m}"
    --wait
  )

  if ! run_with_timeout_capture "$(duration_to_seconds "${NFS_PROVISIONER_HELM_TIMEOUT:-15m}")" helm_cmd "${helm_args[@]}"; then
    local status=$?
    local out="${RUN_OUTPUT}"

    # Common after partial/failed runs: a few resources exist, but without Helm ownership metadata.
    # Attempt a best-effort adoption of the expected ServiceAccount and retry once.
    if printf "%s" "${out}" | grep -q "exists and cannot be imported into the current release: invalid ownership metadata"; then
      log_warn "Detected pre-existing NFS provisioner resources without Helm ownership; attempting adoption and retry"
      adopt_resource_into_helm_release "${release_namespace}" serviceaccount "${release_name}-nfs-subdir-external-provisioner" "${release_name}" "${release_namespace}"
      # Retry once.
      helm_cmd "${helm_args[@]}"
    else
      log_error "NFS provisioner install/upgrade failed (exit ${status})"
      if [[ -n "${out}" ]]; then
        log_error "Helm output (tail):"
        printf "%s\n" "${out}" | tail -n 120 | indent_lines >&2
      fi
      exit "${status}"
    fi
  fi
  
  # Apply the shared-rwo StorageClass definition (GitOps-aligned). This must exist before
  # Stage 1 installs Forgejo/Argo (they use shared-rwo PVCs), and avoids Argo drift later.
  kubectl apply -f "${REPO_ROOT}/platform/gitops/components/storage/shared-rwo-storageclass/storageclass-rwo.yaml" >/dev/null
  
  log_success "NFS storage provisioner installed"
  kubectl get storageclasses
}

# =============================================================================
# Write Sentinel
# =============================================================================

write_sentinel() {
  mkdir -p "$(dirname "${STAGE0_SENTINEL}")"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STAGE0_SENTINEL}"
  log_success "Stage 0 complete - sentinel written to ${STAGE0_SENTINEL}"
}

# =============================================================================
# Main
# =============================================================================

main() {
  log "Starting Stage 0: VM Provisioning + Talos Bootstrap"
  
  parse_config
  preflight_network_dns
  setup_helm_env
  setup_proxmox_ssh_multiplexing
  setup_talos_iso
  provision_vms
  apply_talos_configs

  if [[ -n "${OFFLINE_BUNDLE_DIR}" && "${OFFLINE_BUNDLE_AUTO_LOAD_REGISTRY}" == "1" ]]; then
    local loader="${REPO_ROOT}/shared/scripts/offline-bundle-load-registry.sh"
    if [[ ! -x "${loader}" ]]; then
      log_error "Offline bundle registry loader missing or not executable: ${loader}"
      exit 1
    fi
    log "Offline mode: loading images into bootstrap registry from bundle (OFFLINE_BUNDLE_AUTO_LOAD_REGISTRY=1)"
    "${loader}" --bundle "${OFFLINE_BUNDLE_DIR}" --bootstrap-config "${CONFIG_FILE}"
  fi

  # Build and push bootstrap-tools image to local registry (if configured).
  # This must happen before prepull since Talos nodes can't build images locally.
  build_and_push_bootstrap_tools || exit 1
  build_and_push_validation_tools_core || exit 1
  build_and_push_tenant_provisioner || exit 1
  # Ensure our internal utility image is available before any GitOps hook jobs run.
  # This avoids hard-to-debug ImagePullBackOff later during Stage 1 / Argo sync.
  prepull_bootstrap_tools_image || exit 1
  prepull_validation_tools_core_image || exit 1
  prepull_tenant_provisioner_image || exit 1
  preflight_darksite_runtime_image_mirror || exit 1
  bootstrap_cluster
  install_networking
  install_storage
  write_sentinel
  
  log_success "Stage 0 complete!"
  echo ""
  echo "Cluster endpoints:"
  echo "  Kubernetes API: https://${CONTROL_PLANE_VIP}:6443"
  echo "  Kubeconfig: ${REPO_ROOT}/tmp/kubeconfig-prod"
  echo "  Talosconfig: ${TALOS_DIR}/talosconfig"
  echo ""
}

main "$@"
