#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_CLUSTER_NAME="deploykube-dev"
DEFAULT_IMAGE="registry.example.internal/deploykube/bootstrap-tools:1.4"
DEFAULT_DOCKERFILE="${REPO_ROOT}/shared/images/bootstrap-tools/Dockerfile"
DEFAULT_PLATFORM=""

BUILD_IMAGE="${BUILD_IMAGE:-${DEFAULT_IMAGE}}"
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
DOCKERFILE="${DOCKERFILE:-${DEFAULT_DOCKERFILE}}"
DOCKER_CONTEXT="${DOCKER_CONTEXT:-$(dirname "${DOCKERFILE}")}"
PLATFORM="${PLATFORM:-${DEFAULT_PLATFORM}}"
BOOTSTRAP_TOOLS_PULL="${BOOTSTRAP_TOOLS_PULL:-0}"
BOOTSTRAP_TOOLS_USE_LOCAL_CACHE="${BOOTSTRAP_TOOLS_USE_LOCAL_CACHE:-1}"

print_usage() {
  cat <<USAGE
Usage: ${BASH_SOURCE[0]##*/} [options]
Options:
  --image IMAGE        Image name to build (default ${DEFAULT_IMAGE})
  --cluster NAME       Kind cluster name for loading the image (default ${DEFAULT_CLUSTER_NAME})
  --dockerfile PATH    Dockerfile to use (default ${DEFAULT_DOCKERFILE})
  --context PATH       Docker build context (default directory of the Dockerfile)
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
  echo "docker is required to build the bootstrap tools image" >&2
  exit 1
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is required to load the bootstrap tools image" >&2
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

local_registry_available() {
  curl -fsS "http://127.0.0.1:5001/v2/" >/dev/null 2>&1
}

detect_platform

echo "[bootstrap-tools] building ${BUILD_IMAGE} from ${DOCKERFILE}"
build_args=()
build_flags=()

if [[ "${BOOTSTRAP_TOOLS_PULL}" == "1" ]]; then
  build_flags+=(--pull)
fi

if [[ "${BOOTSTRAP_TOOLS_USE_LOCAL_CACHE}" == "1" ]] && local_registry_available; then
  # Route base image pulls through the local docker.io pull-through cache when available.
  # This avoids Docker Hub token requests on flaky connections once the cache is warm.
  build_args+=(--build-arg "ALPINE_IMAGE=127.0.0.1:5001/library/alpine:3.22.2")
  build_args+=(--build-arg "GARAGE_IMAGE=127.0.0.1:5001/dxflrs/garage@sha256:4c9b34c113e61358466e83fd6e7d66e6d18657ede14b776eb78a93ee8da7cf6a")
  build_args+=(--build-arg "KUBECTL_IMAGE=127.0.0.1:5004/kubectl:v1.34.1")
  build_args+=(--build-arg "KEYCLOAK_IMAGE=127.0.0.1:5003/keycloak/keycloak:26.4.4")
fi

docker build "${build_flags[@]}" --platform "${PLATFORM}" "${build_args[@]}" -t "${BUILD_IMAGE}" -f "${DOCKERFILE}" "${DOCKER_CONTEXT}"

echo "[bootstrap-tools] loading ${BUILD_IMAGE} into kind cluster ${CLUSTER_NAME}"
kind load docker-image "${BUILD_IMAGE}" --name "${CLUSTER_NAME}"
