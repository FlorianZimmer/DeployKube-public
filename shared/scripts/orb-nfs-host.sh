#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_EXPORT_PATH="${REPO_ROOT}/nfs-data"
DEFAULT_EXPORT_VOLUME="${NFS_EXPORT_VOLUME:-deploykube-nfs-data}"
DEFAULT_USE_VOLUME="${NFS_USE_DOCKER_VOLUME:-1}"
DEFAULT_CONTAINER_NAME="${NFS_CONTAINER_NAME:-deploykube-nfs}"
DEFAULT_IMAGE_NAME="${NFS_IMAGE_NAME:-deploykube/orb-nfs:latest}"
DEFAULT_IMAGE_DIR="${NFS_IMAGE_DIR:-${REPO_ROOT}/shared/images/orb-nfs}"
DEFAULT_DOCKER_CONTEXT="${NFS_DOCKER_CONTEXT:-orbstack}"
DEFAULT_DOCKER_NETWORK="${NFS_DOCKER_NETWORK:-kind}"
DEFAULT_CONTAINER_IP="${NFS_HOST_IP:-203.0.113.20}"
DEFAULT_NFS_OPTIONS="${NFS_EXPORT_OPTIONS:-*(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)}"
DEFAULT_NFS_THREADS="${NFS_THREADS:-8}"
DEFAULT_MOUNTD_PORT="${NFS_MOUNTD_PORT:-20048}"
DEFAULT_STATD_PORT="${NFS_STATD_PORT:-662}"
DEFAULT_STATD_OUTGOING_PORT="${NFS_STATD_OUTGOING_PORT:-2020}"
DEFAULT_RQUOTAD_PORT="${NFS_RQUOTAD_PORT:-875}"
DEFAULT_LOCKD_TCP_PORT="${NFS_LOCKD_TCP_PORT:-32803}"
DEFAULT_LOCKD_UDP_PORT="${NFS_LOCKD_UDP_PORT:-32769}"
DEFAULT_CALLBACK_TCP_PORT="${NFS_CALLBACK_TCP_PORT:-20049}"
DEFAULT_IMAGE_PLATFORM="${NFS_IMAGE_PLATFORM:-}"

SENTINEL_NAME=".deploykube-nfs-host-created"

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

fatal() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: ${BASH_SOURCE[0]##*/} [options] [command]

Commands:
  up        Ensure the OrbStack NFS container is running (default)
  down      Stop and remove the OrbStack NFS container
  status    Print container status information
  logs      Show container logs (pass --follow to follow)

Options:
  --export-path PATH     Host path to export (default: ${DEFAULT_EXPORT_PATH})
  --export-volume NAME   Docker volume name to export (default: ${DEFAULT_EXPORT_VOLUME})
  --use-volume           Force using a Docker volume for exports (default)
  --no-volume            Force using a host path for exports
  --context NAME         Docker context to use (default: ${DEFAULT_DOCKER_CONTEXT})
  --network NAME         Docker network for the container (default: ${DEFAULT_DOCKER_NETWORK})
  --ip ADDRESS           IPv4 address for the container on the network (default: ${DEFAULT_CONTAINER_IP})
  --image NAME           Image to run (default: ${DEFAULT_IMAGE_NAME})
  --image-dir PATH       Directory containing the Dockerfile (default: ${DEFAULT_IMAGE_DIR})
  --container-name NAME  Container name (default: ${DEFAULT_CONTAINER_NAME})
  --force-recreate       Recreate the container even if it is already running
  --force-build          Rebuild the image even if it already exists
  --skip-build           Do not attempt to build the image automatically
  --platform PLATFORM    Build/run platform override (e.g. linux/arm64)
  --nfs-options OPTS     Export options passed to the container
  --threads COUNT        Number of NFS threads (default: ${DEFAULT_NFS_THREADS})
  --mountd-port PORT     rpc.mountd port (default: ${DEFAULT_MOUNTD_PORT})
  --statd-port PORT      rpc.statd port (default: ${DEFAULT_STATD_PORT})
  --statd-out PORT       rpc.statd outgoing port (default: ${DEFAULT_STATD_OUTGOING_PORT})
  --rquotad-port PORT    rpc.rquotad port (default: ${DEFAULT_RQUOTAD_PORT})
  --lockd-tcp PORT       lockd TCP port (default: ${DEFAULT_LOCKD_TCP_PORT})
  --lockd-udp PORT       lockd UDP port (default: ${DEFAULT_LOCKD_UDP_PORT})
  --callback-port PORT   NFS callback TCP port (default: ${DEFAULT_CALLBACK_TCP_PORT})
  --help                 Show this help message

You can also configure defaults via environment variables:
  NFS_EXPORT_PATH, NFS_EXPORT_VOLUME, NFS_USE_DOCKER_VOLUME, NFS_DOCKER_CONTEXT, NFS_DOCKER_NETWORK, NFS_HOST_IP, NFS_IMAGE_NAME, NFS_IMAGE_DIR, NFS_CONTAINER_NAME, NFS_EXPORT_OPTIONS, NFS_THREADS, etc.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    fatal "required command not found: ${cmd}"
  fi
}

docker_cmd() {
  docker --context "${DOCKER_CONTEXT}" "$@"
}

canonical_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).expanduser()
print(path.resolve(strict=False))
PY
}

container_exists() {
  docker_cmd inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || echo false)" == "true" ]]
}

ensure_network() {
  local inspect_json
  if ! inspect_json=$(docker_cmd network inspect "${DOCKER_NETWORK}" 2>/dev/null); then
    fatal "docker network ${DOCKER_NETWORK} not found; create the cluster first"
  fi

  NETWORK_SUBNET=$(python3 - "${inspect_json}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])[0]
cfg = data.get("IPAM", {}).get("Config", [])
if not cfg:
    print("")
    sys.exit(0)
print(cfg[0].get("Subnet",""))
PY
)
  if [[ -z "${NETWORK_SUBNET}" ]]; then
    fatal "failed to determine subnet for network ${DOCKER_NETWORK}"
  fi

  local validation_output=""
  # Capture the Python exit status explicitly so we can branch on the real
  # validation result instead of the negated status from `!`.
  if validation_output=$(python3 - "${inspect_json}" "${CONTAINER_IP}" <<'PY'
import json, sys, ipaddress
data = json.loads(sys.argv[1])[0]
target_ip = ipaddress.ip_address(sys.argv[2])
containers = data.get("Containers", {}) or {}
for info in containers.values():
    addr = info.get("IPv4Address", "")
    if not addr:
        continue
    candidate = ipaddress.ip_address(addr.split("/")[0])
    if candidate == target_ip:
        print(info.get("Name", "<unknown>"))
        raise SystemExit(1)
subnet_cfg = data.get("IPAM", {}).get("Config", [])
if subnet_cfg:
    subnet = ipaddress.ip_network(subnet_cfg[0].get("Subnet", "0.0.0.0/0"), strict=False)
    if target_ip not in subnet:
        print(str(subnet))
        raise SystemExit(2)
PY
  ); then
    return
  else
    local rc=$?
    case "${rc}" in
      1)
        fatal "requested IP ${CONTAINER_IP} already in use on network ${DOCKER_NETWORK} (container ${validation_output})"
        ;;
      2)
        fatal "requested IP ${CONTAINER_IP} not within network ${DOCKER_NETWORK} subnet ${validation_output}"
        ;;
      *)
        fatal "failed to validate IP ${CONTAINER_IP} on network ${DOCKER_NETWORK}"
        ;;
    esac
  fi
}

ensure_export_dir() {
  local created=0
  if [[ ! -d "${EXPORT_PATH}" ]]; then
    mkdir -p "${EXPORT_PATH}"
    created=1
    touch "${SENTINEL_PATH}"
    log "created export directory ${EXPORT_PATH}"
  elif [[ ! -f "${SENTINEL_PATH}" ]]; then
    log "using existing export directory ${EXPORT_PATH}"
  fi

  chmod 0777 "${EXPORT_PATH}"

  if (( created == 0 )) && [[ -f "${SENTINEL_PATH}" ]]; then
    touch "${SENTINEL_PATH}"
  fi
}

cleanup_export_dir() {
  if [[ ! -d "${EXPORT_PATH}" || ! -f "${SENTINEL_PATH}" ]]; then
    return
  fi

  local removable=true
  shopt -s dotglob nullglob
  local entries=("${EXPORT_PATH}"/*)
  for entry in "${entries[@]}"; do
    if [[ "$(basename "${entry}")" == "${SENTINEL_NAME}" ]]; then
      continue
    fi
    removable=false
    break
  done
  shopt -u dotglob nullglob

  rm -f "${SENTINEL_PATH}"

  if "${removable}"; then
    rmdir "${EXPORT_PATH}"
    log "removed empty export directory ${EXPORT_PATH}"
  else
    warn "export directory ${EXPORT_PATH} contains data; leaving in place"
  fi
}

image_exists() {
  docker_cmd image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

build_image() {
  if [[ ! -d "${IMAGE_DIR}" ]]; then
    fatal "image directory ${IMAGE_DIR} not found"
  fi

  local args=()
  if [[ -n "${IMAGE_PLATFORM}" ]]; then
    args+=(--platform "${IMAGE_PLATFORM}")
  fi

  log "building ${IMAGE_NAME} from ${IMAGE_DIR}"
  if (( ${#args[@]} > 0 )); then
    docker_cmd build "${IMAGE_DIR}" -t "${IMAGE_NAME}" "${args[@]}"
  else
    docker_cmd build "${IMAGE_DIR}" -t "${IMAGE_NAME}"
  fi
}

ensure_image() {
  if (( FORCE_BUILD == 1 )); then
    build_image
    return
  fi

  if image_exists; then
    return
  fi

  if (( SKIP_BUILD == 1 )); then
    fatal "image ${IMAGE_NAME} not found and --skip-build specified"
  fi

  build_image
}

remove_container() {
  if container_exists; then
    log "removing container ${CONTAINER_NAME}"
    docker_cmd rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

stop_container() {
  if container_running; then
    log "stopping container ${CONTAINER_NAME}"
    docker_cmd stop "${CONTAINER_NAME}" >/dev/null
  fi
}

ensure_export_volume() {
  if [[ -z "${EXPORT_VOLUME}" ]]; then
    fatal "export volume not specified"
  fi

  if docker_cmd volume inspect "${EXPORT_VOLUME}" >/dev/null 2>&1; then
    log "using existing export volume ${EXPORT_VOLUME}"
  else
    log "creating export volume ${EXPORT_VOLUME}"
    docker_cmd volume create \
      --label deploykube.component=shared-storage \
      "${EXPORT_VOLUME}" >/dev/null
  fi
}

run_container() {
  local args=(
    run -d
    --name "${CONTAINER_NAME}"
    --hostname "${CONTAINER_NAME}"
    --privileged
    --restart unless-stopped
    --network "${DOCKER_NETWORK}"
    --ip "${CONTAINER_IP}"
    --tmpfs /run
    --tmpfs /var/run
    --label deploykube.component=shared-storage
    --log-opt max-size=10m
    --log-opt max-file=3
    -v "${EXPORT_MOUNT_SOURCE}:/export:rw"
    -e NFS_EXPORT_DIR=/export
    -e NFS_EXPORT_OPTIONS="${NFS_OPTIONS}"
    -e NFS_THREADS="${NFS_THREADS}"
    -e NFS_MOUNTD_PORT="${MOUNTD_PORT}"
    -e NFS_STATD_PORT="${STATD_PORT}"
    -e NFS_STATD_OUTGOING_PORT="${STATD_OUTGOING_PORT}"
    -e NFS_RQUOTAD_PORT="${RQUOTAD_PORT}"
    -e NFS_LOCKD_TCP_PORT="${LOCKD_TCP_PORT}"
    -e NFS_LOCKD_UDP_PORT="${LOCKD_UDP_PORT}"
    -e NFS_CALLBACK_TCP_PORT="${CALLBACK_TCP_PORT}"
  )

  if [[ -n "${IMAGE_PLATFORM}" ]]; then
    args+=(--platform "${IMAGE_PLATFORM}")
  fi

  args+=("${IMAGE_NAME}")

  log "starting OrbStack NFS container ${CONTAINER_NAME} (${IMAGE_NAME}) on ${DOCKER_NETWORK}/${CONTAINER_IP}"
  docker_cmd "${args[@]}"
}

wait_for_ready() {
  local attempts=0 max_attempts=30
  while (( attempts < max_attempts )); do
    if ! container_running; then
      fatal "container ${CONTAINER_NAME} exited unexpectedly; inspect logs"
    fi
    if docker_cmd run --rm --pull never --network "${DOCKER_NETWORK}" \
      --entrypoint rpcinfo "${IMAGE_NAME}" -p "${CONTAINER_IP}" >/dev/null 2>&1; then
      docker_cmd run --rm --pull never --network "${DOCKER_NETWORK}" \
        --entrypoint showmount "${IMAGE_NAME}" -e "${CONTAINER_IP}" >/dev/null 2>&1 || true
      log "NFS container is ready (rpcinfo reachable via ${CONTAINER_IP})"
      return
    fi
    log "waiting for NFS container readiness (${attempts}/${max_attempts})"
    sleep 2
    attempts=$((attempts + 1))
  done
  fatal "timed out waiting for rpcinfo to respond via ${CONTAINER_IP}"
}

show_status() {
  if container_exists; then
    if container_running; then
      log "container ${CONTAINER_NAME} is running (IP ${CONTAINER_IP})"
    else
      warn "container ${CONTAINER_NAME} exists but is not running"
    fi
  else
    warn "container ${CONTAINER_NAME} not found"
  fi
}

show_logs() {
  if [[ "${FOLLOW_LOGS}" == "1" ]]; then
    docker_cmd logs -f "${CONTAINER_NAME}"
  else
    docker_cmd logs "${CONTAINER_NAME}"
  fi
}

COMMAND="up"
EXPORT_PATH="${NFS_EXPORT_PATH:-}"
EXPORT_VOLUME="${DEFAULT_EXPORT_VOLUME}"
USE_VOLUME=1
if [[ "${DEFAULT_USE_VOLUME}" == "0" ]]; then
  USE_VOLUME=0
fi
if [[ -n "${EXPORT_PATH}" ]]; then
  USE_VOLUME=0
fi
DOCKER_CONTEXT="${DEFAULT_DOCKER_CONTEXT}"
DOCKER_NETWORK="${DEFAULT_DOCKER_NETWORK}"
CONTAINER_IP="${DEFAULT_CONTAINER_IP}"
IMAGE_NAME="${DEFAULT_IMAGE_NAME}"
IMAGE_DIR="${DEFAULT_IMAGE_DIR}"
CONTAINER_NAME="${DEFAULT_CONTAINER_NAME}"
NFS_OPTIONS="${DEFAULT_NFS_OPTIONS}"
NFS_THREADS="${DEFAULT_NFS_THREADS}"
MOUNTD_PORT="${DEFAULT_MOUNTD_PORT}"
STATD_PORT="${DEFAULT_STATD_PORT}"
STATD_OUTGOING_PORT="${DEFAULT_STATD_OUTGOING_PORT}"
RQUOTAD_PORT="${DEFAULT_RQUOTAD_PORT}"
LOCKD_TCP_PORT="${DEFAULT_LOCKD_TCP_PORT}"
LOCKD_UDP_PORT="${DEFAULT_LOCKD_UDP_PORT}"
CALLBACK_TCP_PORT="${DEFAULT_CALLBACK_TCP_PORT}"
IMAGE_PLATFORM="${DEFAULT_IMAGE_PLATFORM}"
FORCE_RECREATE=0
FORCE_BUILD=0
SKIP_BUILD=0
FOLLOW_LOGS=0

ARGS=("$@")
i=0
while (( i < ${#ARGS[@]} )); do
  arg="${ARGS[i]}"
  case "${arg}" in
    up|down|status|logs)
      COMMAND="${arg}"
      ;;
    --export-path)
      i=$((i + 1)); EXPORT_PATH="${ARGS[i]}"
      USE_VOLUME=0
      ;;
    --export-volume)
      i=$((i + 1)); EXPORT_VOLUME="${ARGS[i]}"
      USE_VOLUME=1
      ;;
    --use-volume)
      USE_VOLUME=1
      ;;
    --no-volume)
      USE_VOLUME=0
      ;;
    --context)
      i=$((i + 1)); DOCKER_CONTEXT="${ARGS[i]}"
      ;;
    --network)
      i=$((i + 1)); DOCKER_NETWORK="${ARGS[i]}"
      ;;
    --ip)
      i=$((i + 1)); CONTAINER_IP="${ARGS[i]}"
      ;;
    --image)
      i=$((i + 1)); IMAGE_NAME="${ARGS[i]}"
      ;;
    --image-dir)
      i=$((i + 1)); IMAGE_DIR="${ARGS[i]}"
      ;;
    --container-name)
      i=$((i + 1)); CONTAINER_NAME="${ARGS[i]}"
      ;;
    --force-recreate)
      FORCE_RECREATE=1
      ;;
    --force-build)
      FORCE_BUILD=1
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    --platform)
      i=$((i + 1)); IMAGE_PLATFORM="${ARGS[i]}"
      ;;
    --nfs-options)
      i=$((i + 1)); NFS_OPTIONS="${ARGS[i]}"
      ;;
    --threads)
      i=$((i + 1)); NFS_THREADS="${ARGS[i]}"
      ;;
    --mountd-port)
      i=$((i + 1)); MOUNTD_PORT="${ARGS[i]}"
      ;;
    --statd-port)
      i=$((i + 1)); STATD_PORT="${ARGS[i]}"
      ;;
    --statd-out)
      i=$((i + 1)); STATD_OUTGOING_PORT="${ARGS[i]}"
      ;;
    --rquotad-port)
      i=$((i + 1)); RQUOTAD_PORT="${ARGS[i]}"
      ;;
    --lockd-tcp)
      i=$((i + 1)); LOCKD_TCP_PORT="${ARGS[i]}"
      ;;
    --lockd-udp)
      i=$((i + 1)); LOCKD_UDP_PORT="${ARGS[i]}"
      ;;
    --callback-port)
      i=$((i + 1)); CALLBACK_TCP_PORT="${ARGS[i]}"
      ;;
    --follow)
      FOLLOW_LOGS=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fatal "unknown argument: ${arg}"
      ;;
  esac
  i=$((i + 1))
done

require_cmd docker
require_cmd python3

if (( USE_VOLUME == 1 )); then
  EXPORT_MOUNT_SOURCE="${EXPORT_VOLUME}"
  if [[ -z "${EXPORT_MOUNT_SOURCE}" ]]; then
    fatal "export volume not specified"
  fi
else
  if [[ -z "${EXPORT_PATH}" ]]; then
    EXPORT_PATH="${DEFAULT_EXPORT_PATH}"
  fi
  EXPORT_PATH="$(canonical_path "${EXPORT_PATH}")"
  EXPORT_MOUNT_SOURCE="${EXPORT_PATH}"
  SENTINEL_PATH="${EXPORT_PATH}/${SENTINEL_NAME}"
fi

case "${COMMAND}" in
  up)
    if container_running; then
      if (( FORCE_RECREATE == 1 )); then
        stop_container
        remove_container
      else
        log "container ${CONTAINER_NAME} already running; verifying service"
        wait_for_ready
        exit 0
      fi
    fi

    if container_exists; then
      remove_container
    fi

    ensure_network
    ensure_image
    if (( USE_VOLUME == 1 )); then
      ensure_export_volume
    else
      ensure_export_dir
    fi
    run_container
    wait_for_ready
    ;;
  down)
    stop_container || true
    remove_container || true
    if (( USE_VOLUME == 0 )); then
      cleanup_export_dir
    fi
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs
    ;;
  *)
    usage
    exit 1
    ;;
esac
