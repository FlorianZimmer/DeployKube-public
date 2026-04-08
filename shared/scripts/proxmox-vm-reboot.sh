#!/usr/bin/env bash
# =============================================================================
# Proxmox Talos VM Graceful Reboot Script
# =============================================================================
# Drains a Kubernetes node, reboots the Proxmox VM, and waits for it to return.
#
# Usage:
#   ./proxmox-vm-reboot.sh <vm-id|node-name> [--all-workers] [--force]
#
# Examples:
#   ./proxmox-vm-reboot.sh 2002                    # Reboot VM 2002
#   ./proxmox-vm-reboot.sh kube-proxmox-worker-2   # Reboot by node name
#   ./proxmox-vm-reboot.sh --all-workers           # Reboot all workers sequentially
#   ./proxmox-vm-reboot.sh 2002 --force            # Skip drain, force reboot
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration - adjust these for your environment
PROXMOX_HOST="${PROXMOX_HOST:-198.51.100.10}"
KUBECONFIG_PATH="${KUBECONFIG:-$REPO_ROOT/tmp/kubeconfig-prod}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120s}"
REBOOT_WAIT_TIMEOUT="${REBOOT_WAIT_TIMEOUT:-300}"  # seconds

# VM ID to node name mapping (from terraform.tfvars / config.yaml)
declare -A VM_TO_NODE=(
    [1001]="kube-proxmox-cp-1"
    [1002]="kube-proxmox-cp-2"
    [1003]="kube-proxmox-cp-3"
    [2001]="kube-proxmox-worker-1"
    [2002]="kube-proxmox-worker-2"
    [2003]="kube-proxmox-worker-3"
)

declare -A NODE_TO_VM
for vm in "${!VM_TO_NODE[@]}"; do
    NODE_TO_VM[${VM_TO_NODE[$vm]}]=$vm
done

WORKER_VMS=(2001 2002 2003)

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 <vm-id|node-name> [--all-workers] [--force]

Arguments:
  <vm-id>         Proxmox VM ID (e.g., 2002)
  <node-name>     Kubernetes node name (e.g., kube-proxmox-worker-2)
  --all-workers   Reboot all worker nodes sequentially
  --force         Skip draining, force reboot

Environment:
  PROXMOX_HOST    Proxmox host IP (default: 198.51.100.10)
  KUBECONFIG      Path to kubeconfig (default: tmp/kubeconfig-prod)
  DRAIN_TIMEOUT   Drain timeout (default: 120s)

Examples:
  $0 2002                           # Drain and reboot VM 2002
  $0 kube-proxmox-worker-3          # Drain and reboot worker-3
  $0 --all-workers                  # Reboot all workers sequentially
  $0 2002 --force                   # Force reboot without drain
EOF
    exit 1
}

resolve_vm_id() {
    local input="$1"
    
    # If it's a number, assume it's a VM ID
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return
    fi
    
    # Otherwise, look up by node name
    if [[ -n "${NODE_TO_VM[$input]:-}" ]]; then
        echo "${NODE_TO_VM[$input]}"
        return
    fi
    
    error "Unknown node/VM: $input"
    error "Valid VMs: ${!VM_TO_NODE[*]}"
    error "Valid nodes: ${!NODE_TO_VM[*]}"
    exit 1
}

get_node_name() {
    local vm_id="$1"
    echo "${VM_TO_NODE[$vm_id]:-unknown}"
}

drain_node() {
    local node="$1"
    log "Draining node $node..."
    
    if ! kubectl --kubeconfig="$KUBECONFIG_PATH" drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout="$DRAIN_TIMEOUT" 2>&1; then
        error "Drain failed for $node (continuing anyway)"
    fi
    
    log "Node $node drained"
}

reboot_vm() {
    local vm_id="$1"
    log "Rebooting VM $vm_id on $PROXMOX_HOST..."
    
    ssh "$PROXMOX_HOST" "qm reboot $vm_id"
    
    log "Reboot command sent for VM $vm_id"
}

wait_for_node() {
    local node="$1"
    local timeout="$REBOOT_WAIT_TIMEOUT"
    local elapsed=0
    
    log "Waiting for node $node to become Ready (timeout: ${timeout}s)..."
    
    # Wait for node to go NotReady first (indicates reboot started)
    sleep 10
    
    while (( elapsed < timeout )); do
        local status
        status=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get node "$node" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$status" == "True" ]]; then
            log "Node $node is Ready"
            return 0
        fi
        
        sleep 10
        (( elapsed += 10 ))
        log "  Still waiting... ($elapsed/${timeout}s, status: $status)"
    done
    
    error "Timeout waiting for node $node to become Ready"
    return 1
}

uncordon_node() {
    local node="$1"
    log "Uncordoning node $node..."
    
    kubectl --kubeconfig="$KUBECONFIG_PATH" uncordon "$node"
    
    log "Node $node uncordoned and ready for scheduling"
}

show_node_status() {
    local node="$1"
    log "Current status for $node:"
    kubectl --kubeconfig="$KUBECONFIG_PATH" get node "$node" \
        -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory"
}

reboot_single_vm() {
    local vm_id="$1"
    local force="${2:-false}"
    local node
    node=$(get_node_name "$vm_id")
    
    log "=========================================="
    log "Rebooting VM $vm_id ($node)"
    log "=========================================="
    
    if [[ "$force" != "true" ]]; then
        drain_node "$node"
    else
        log "Skipping drain (--force)"
    fi
    
    reboot_vm "$vm_id"
    wait_for_node "$node"
    uncordon_node "$node"
    show_node_status "$node"
    
    log "VM $vm_id ($node) reboot complete!"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    local force=false
    local all_workers=false
    local target=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            --all-workers)
                all_workers=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done
    
    # Validate kubeconfig exists
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
        error "Kubeconfig not found: $KUBECONFIG_PATH"
        error "Set KUBECONFIG env var or run from repo root"
        exit 1
    fi
    
    # Handle --all-workers
    if [[ "$all_workers" == "true" ]]; then
        log "Rebooting all workers sequentially..."
        for vm_id in "${WORKER_VMS[@]}"; do
            reboot_single_vm "$vm_id" "$force"
        done
        log "All workers rebooted successfully!"
        exit 0
    fi
    
    # Handle single VM/node
    if [[ -z "$target" ]]; then
        usage
    fi
    
    local vm_id
    vm_id=$(resolve_vm_id "$target")
    reboot_single_vm "$vm_id" "$force"
}

main "$@"
