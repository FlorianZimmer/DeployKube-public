#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_CLUSTER_NAME="deploykube-dev"
DEFAULT_IMAGE="registry.example.internal/deploykube/scim-bridge:0.1.0"
DEFAULT_DOCKERFILE="${REPO_ROOT}/shared/images/scim-bridge/Dockerfile"
DEFAULT_PLATFORM=""

BUILD_IMAGE="${BUILD_IMAGE:-${DEFAULT_IMAGE}}"
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
DOCKERFILE="${DOCKERFILE:-${DEFAULT_DOCKERFILE}}"
DOCKER_CONTEXT="${DOCKER_CONTEXT:-${REPO_ROOT}}"
PLATFORM="${PLATFORM:-${DEFAULT_PLATFORM}}"
SCIM_BRIDGE_PULL="${SCIM_BRIDGE_PULL:-0}"

print_usage() {
  cat <<USAGE
Usage: ${BASH_SOURCE[0]##*/} [options]
Options:
  --image IMAGE        Image name to build (default ${DEFAULT_IMAGE})
  --cluster NAME       Kind cluster name for loading the image (default ${DEFAULT_CLUSTER_NAME})
  --dockerfile PATH    Dockerfile to use (default ${DEFAULT_DOCKERFILE})
  --context PATH       Docker build context (default repo root)
  --platform PLATFORM  Target platform (default: host arch)
  --help               Show this message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      BUILD_IMAGE="$2"
      shift 2
      ;;
    --cluster)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --dockerfile)
      DOCKERFILE="$2"
      shift 2
      ;;
    --context)
      DOCKER_CONTEXT="$2"
      shift 2
      ;;
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Dockerfile ${DOCKERFILE} not found" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to build the scim-bridge image" >&2
  exit 1
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is required to load the scim-bridge image" >&2
  exit 1
fi

detect_platform() {
  if [[ -n "${PLATFORM}" ]]; then
    return 0
  fi
  case "$(uname -m)" in
    arm64|aarch64) PLATFORM="linux/arm64" ;;
    x86_64|amd64) PLATFORM="linux/amd64" ;;
    *) PLATFORM="linux/amd64" ;;
  esac
}

detect_platform

echo "[scim-bridge] building ${BUILD_IMAGE} from ${DOCKERFILE}"
build_flags=()
if [[ "${SCIM_BRIDGE_PULL}" == "1" ]]; then
  build_flags+=(--pull)
fi

docker build "${build_flags[@]}" --platform "${PLATFORM}" -t "${BUILD_IMAGE}" -f "${DOCKERFILE}" "${DOCKER_CONTEXT}"

echo "[scim-bridge] loading ${BUILD_IMAGE} into kind cluster ${CLUSTER_NAME}"
kind load docker-image "${BUILD_IMAGE}" --name "${CLUSTER_NAME}"
