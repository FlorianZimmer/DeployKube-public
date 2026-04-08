#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-deploykube-dev}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
OUT_KUBECONFIG="${OUT_KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-kind-${CLUSTER_NAME}}"
HOME_KUBECONFIG="${HOME_KUBECONFIG:-${HOME}/.kube/config}"
READYZ_TIMEOUT_SECONDS="${READYZ_TIMEOUT_SECONDS:-60}"

log() { printf '[kind-kubeconfig] %s\n' "$1" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { log "missing dependency: $1"; exit 1; }
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

export_one() {
  local kubeconfig_path="$1"
  mkdir -p "$(dirname "${kubeconfig_path}")"
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${kubeconfig_path}" >/dev/null 2>&1
}

server_for() {
  local kubeconfig_path="$1"
  kubectl --kubeconfig "${kubeconfig_path}" config view --minify --context "${KIND_CONTEXT}" \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

readyz_for() {
  local kubeconfig_path="$1"
  kubectl --kubeconfig "${kubeconfig_path}" --context "${KIND_CONTEXT}" get --raw='/readyz' >/dev/null 2>&1
}

wait_readyz() {
  local kubeconfig_path="$1"
  local end=$(( $(date +%s) + READYZ_TIMEOUT_SECONDS ))
  while true; do
    if readyz_for "${kubeconfig_path}"; then
      return 0
    fi
    if (( $(date +%s) >= end )); then
      return 1
    fi
    sleep 2
  done
}

print_diagnostics() {
  local kubeconfig_path="$1"
  local server
  server="$(server_for "${kubeconfig_path}")"
  log "kubeconfig: ${kubeconfig_path}"
  log "server: ${server:-<missing>}"
  if docker inspect "${CLUSTER_NAME}-control-plane" --format '{{json .NetworkSettings.Ports}}' >/tmp/kind-ports.json 2>/dev/null; then
    log "control-plane ports: $(cat /tmp/kind-ports.json)"
    rm -f /tmp/kind-ports.json || true
  fi
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "${CLUSTER_NAME}-control-plane|${CLUSTER_NAME}-worker" || true
}

main() {
  require kind
  require kubectl

  if ! cluster_exists; then
    log "kind cluster ${CLUSTER_NAME} not found"
    exit 1
  fi

  export_one "${OUT_KUBECONFIG}"
  export_one "${HOME_KUBECONFIG}"

  if [[ -n "${KUBECONFIG:-}" ]]; then
    if [[ "${KUBECONFIG}" == *:* ]]; then
      log "KUBECONFIG contains multiple paths; not updating it automatically (${KUBECONFIG})"
    else
      export_one "${KUBECONFIG}"
    fi
  fi

  if ! wait_readyz "${OUT_KUBECONFIG}"; then
    log "kube-apiserver not reachable via OUT_KUBECONFIG within ${READYZ_TIMEOUT_SECONDS}s"
    print_diagnostics "${OUT_KUBECONFIG}"
    exit 1
  fi

  if ! wait_readyz "${HOME_KUBECONFIG}"; then
    log "kube-apiserver not reachable via HOME_KUBECONFIG within ${READYZ_TIMEOUT_SECONDS}s"
    print_diagnostics "${HOME_KUBECONFIG}"
    log "workaround: export KUBECONFIG='${OUT_KUBECONFIG#${REPO_ROOT}/}'"
    exit 1
  fi

  log "kubeconfig refreshed: ${KIND_CONTEXT}"
}

main "$@"

