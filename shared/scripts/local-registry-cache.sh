#!/usr/bin/env bash
set -euo pipefail

# Local pull-through caches for common registries so clean bootstraps reuse layers.
# Default action: `up`. Other actions: `down`, `status`, `prune` (removes volumes).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_CONTEXT="$(docker context show 2>/dev/null || echo default)"
ACTION="${1:-up}"
shift || true

REGISTRY_DOCKER_CONTEXT="${REGISTRY_DOCKER_CONTEXT:-${DEFAULT_CONTEXT}}"
REGISTRY_NETWORK="${REGISTRY_NETWORK:-kind}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-deploykube-registry-cache}"
PUBLISH_HOST="${REGISTRY_PUBLISH_HOST:-127.0.0.1}"

log() {
  printf '[registry-cache] %s\n' "$1"
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [up|down|status|prune] [--context <docker-context>] [--network <network>]

Environment overrides:
  REGISTRY_DOCKER_CONTEXT   Docker context to use (default: ${DEFAULT_CONTEXT})
  REGISTRY_NETWORK          Network to attach caches to (default: kind)
  REGISTRY_IMAGE            Registry image (default: registry:2)
  REGISTRY_PREFIX           Container/volume name prefix (default: deploykube-registry-cache)
  REGISTRY_PUBLISH_HOST     Host interface for published ports (default: 127.0.0.1)
USAGE
}

# name|mode|remote_url|upstream_host|host_port
# mode: proxy (pull-through cache) or mirror (plain registry you seed manually)
CACHES=(
  "docker-io|proxy|https://registry-1.docker.io|docker.io|5001"
  "darksite-cloud|mirror||registry.example.internal|5002" # Canonical DeployKube image domain mirror (pre-seeded)
  "quay-io|proxy|https://quay.io|quay.io|5003"
  "registry-k8s-io|proxy|https://registry.k8s.io|registry.k8s.io|5004"
  "cr-smallstep-com|proxy|https://cr.smallstep.com|cr.smallstep.com|5005"
  "codeberg-org|proxy|https://codeberg.org|codeberg.org|5006"
  "code-forgejo-org|proxy|https://code.forgejo.org|code.forgejo.org|5007"
)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context)
        REGISTRY_DOCKER_CONTEXT="$2"; shift 2 ;;
      --network)
        REGISTRY_NETWORK="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        log "unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

ensure_network() {
  if docker --context "${REGISTRY_DOCKER_CONTEXT}" network inspect "${REGISTRY_NETWORK}" >/dev/null 2>&1; then
    return
  fi
  log "network ${REGISTRY_NETWORK} missing; creating"
  docker --context "${REGISTRY_DOCKER_CONTEXT}" network create "${REGISTRY_NETWORK}" >/dev/null
}

start_cache() {
  local name="$1" mode="$2" remote_url="$3" host="$4" port="$5"
  local container="${REGISTRY_PREFIX}-${name}"
  local volume="${REGISTRY_PREFIX}-${name}"

  if ! docker --context "${REGISTRY_DOCKER_CONTEXT}" volume inspect "${volume}" >/dev/null 2>&1; then
    log "creating volume ${volume}"
    docker --context "${REGISTRY_DOCKER_CONTEXT}" volume create "${volume}" >/dev/null
  fi

  if docker --context "${REGISTRY_DOCKER_CONTEXT}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    # If the container exists but the desired mode changed, recreate it while keeping the volume.
    local has_proxy_env=0
    if docker --context "${REGISTRY_DOCKER_CONTEXT}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${container}" 2>/dev/null | grep -q '^REGISTRY_PROXY_REMOTEURL='; then
      has_proxy_env=1
    fi
    if [[ "${mode}" == "proxy" && "${has_proxy_env}" == "0" ]] || [[ "${mode}" != "proxy" && "${has_proxy_env}" == "1" ]]; then
      log "recreating ${container} to switch mode -> ${mode} (volume preserved)"
      docker --context "${REGISTRY_DOCKER_CONTEXT}" stop "${container}" >/dev/null || true
      docker --context "${REGISTRY_DOCKER_CONTEXT}" rm "${container}" >/dev/null || true
    fi
  fi

  if ! docker --context "${REGISTRY_DOCKER_CONTEXT}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    log "starting cache ${container} (${mode}) ${remote_url:+-> ${remote_url}}"
    if [[ "${mode}" == "proxy" ]]; then
      docker --context "${REGISTRY_DOCKER_CONTEXT}" run -d --restart=always \
        --name "${container}" \
        -p "${PUBLISH_HOST}:${port}:5000" \
        --network "${REGISTRY_NETWORK}" \
        -v "${volume}:/var/lib/registry" \
        -e "REGISTRY_PROXY_REMOTEURL=${remote_url}" \
        "${REGISTRY_IMAGE}" >/dev/null
    else
      docker --context "${REGISTRY_DOCKER_CONTEXT}" run -d --restart=always \
        --name "${container}" \
        -p "${PUBLISH_HOST}:${port}:5000" \
        --network "${REGISTRY_NETWORK}" \
        -v "${volume}:/var/lib/registry" \
        "${REGISTRY_IMAGE}" >/dev/null
    fi
  else
    if ! docker --context "${REGISTRY_DOCKER_CONTEXT}" inspect -f '{{.State.Running}}' "${container}" >/dev/null 2>&1; then
      log "starting stopped cache ${container}"
      docker --context "${REGISTRY_DOCKER_CONTEXT}" start "${container}" >/dev/null
    fi
    if ! docker --context "${REGISTRY_DOCKER_CONTEXT}" network inspect "${REGISTRY_NETWORK}" | grep -q "${container}"; then
      docker --context "${REGISTRY_DOCKER_CONTEXT}" network connect "${REGISTRY_NETWORK}" "${container}" >/dev/null 2>&1 || true
    fi
  fi

  # Render a hosts.toml snippet for containerd consumers (documentation aid).
  mkdir -p "${REPO_ROOT}/tmp/registry-cache"
  cat > "${REPO_ROOT}/tmp/registry-cache/${host}.hosts.toml" <<HOSTS
server = "http://${container}:5000"
[host]
  capabilities = ["pull", "resolve"]
HOSTS
}

stop_cache() {
  local name="$1"
  local container="${REGISTRY_PREFIX}-${name}"
  if docker --context "${REGISTRY_DOCKER_CONTEXT}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    log "stopping ${container}"
    docker --context "${REGISTRY_DOCKER_CONTEXT}" stop "${container}" >/dev/null || true
    docker --context "${REGISTRY_DOCKER_CONTEXT}" rm "${container}" >/dev/null || true
  fi
}

status_cache() {
  local name="$1" host="$2" port="$3" remote_url="${4:-}"
  local container="${REGISTRY_PREFIX}-${name}"
  if docker --context "${REGISTRY_DOCKER_CONTEXT}" ps --format '{{.Names}}' | grep -qx "${container}"; then
    printf '✔ %-34s listening on %s:%s (caching %s)\n' "${container}" "${PUBLISH_HOST}" "${port}" "${host}"
  elif docker --context "${REGISTRY_DOCKER_CONTEXT}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    printf '⏸ %-34s stopped (cached %s)\n' "${container}" "${host}"
  else
    printf '✖ %-34s missing (target %s)\n' "${container}" "${remote_url:-${host}}"
  fi
}

prune_cache() {
  local name="$1"
  local volume="${REGISTRY_PREFIX}-${name}"
  stop_cache "$1"
  if docker --context "${REGISTRY_DOCKER_CONTEXT}" volume inspect "${volume}" >/dev/null 2>&1; then
    log "removing volume ${volume}"
    docker --context "${REGISTRY_DOCKER_CONTEXT}" volume rm "${volume}" >/dev/null || true
  fi
}

run_up() {
  ensure_network
  for entry in "${CACHES[@]}"; do
    IFS='|' read -r name mode remote host port <<<"${entry}"
    start_cache "${name}" "${mode}" "${remote}" "${host}" "${port}"
  done
}

run_down() {
  for entry in "${CACHES[@]}"; do
    IFS='|' read -r name _ _ _ <<<"${entry}"
    stop_cache "${name}"
  done
}

run_status() {
  for entry in "${CACHES[@]}"; do
    IFS='|' read -r name _mode remote host port <<<"${entry}"
    status_cache "${name}" "${host}" "${port}" "${remote}"
  done
}

run_prune() {
  for entry in "${CACHES[@]}"; do
    IFS='|' read -r name _ _ _ <<<"${entry}"
    prune_cache "${name}"
  done
}

parse_args "$@"
case "${ACTION}" in
  up) run_up ;;
  down) run_down ;;
  status) run_status ;;
  prune) run_prune ;;
  *) log "unknown action ${ACTION}"; usage; exit 1 ;;
esac
