#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEFAULT_IMAGE="registry.example.internal/deploykube/scim-bridge:0.1.0"
DEFAULT_DOCKERFILE="${REPO_ROOT}/shared/images/scim-bridge/Dockerfile"
DEFAULT_CONTEXT="${REPO_ROOT}"
DEFAULT_PLATFORMS="linux/amd64,linux/arm64"
DEFAULT_BUILDER="deploykube-scim-bridge"
DEFAULT_REGISTRY_INSECURE="0"

SCIM_BRIDGE_IMAGE="${SCIM_BRIDGE_IMAGE:-${DEFAULT_IMAGE}}"
DOCKERFILE="${DOCKERFILE:-${DEFAULT_DOCKERFILE}}"
DOCKER_CONTEXT="${DOCKER_CONTEXT:-${DEFAULT_CONTEXT}}"
PLATFORMS="${PLATFORMS:-${DEFAULT_PLATFORMS}}"
BUILDER="${BUILDER:-${DEFAULT_BUILDER}}"
REGISTRY_INSECURE="${REGISTRY_INSECURE:-${DEFAULT_REGISTRY_INSECURE}}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--image <ref>] [--dockerfile <path>] [--context <path>] [--platforms <csv>] [--builder <name>] [--insecure-registry]

Defaults:
  --image       ${DEFAULT_IMAGE}
  --dockerfile  ${DEFAULT_DOCKERFILE}
  --context     ${DEFAULT_CONTEXT}
  --platforms   ${DEFAULT_PLATFORMS}
  --builder     ${DEFAULT_BUILDER}
  --insecure-registry  ${DEFAULT_REGISTRY_INSECURE}
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) SCIM_BRIDGE_IMAGE="$2"; shift 2 ;;
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    --context) DOCKER_CONTEXT="$2"; shift 2 ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --builder) BUILDER="$2"; shift 2 ;;
    --insecure-registry) REGISTRY_INSECURE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Dockerfile ${DOCKERFILE} not found" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

echo "[scim-bridge] ensuring buildx builder: ${BUILDER}"
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDER}" --use >/dev/null
else
  docker buildx use "${BUILDER}" >/dev/null
fi

echo "[scim-bridge] building and pushing ${SCIM_BRIDGE_IMAGE} (${PLATFORMS})"
if [[ "${REGISTRY_INSECURE}" == "1" ]]; then
  docker buildx build \
    --platform "${PLATFORMS}" \
    -f "${DOCKERFILE}" \
    "${DOCKER_CONTEXT}" \
    --output "type=registry,name=${SCIM_BRIDGE_IMAGE},push=true,registry.insecure=true"
else
  docker buildx build \
    --platform "${PLATFORMS}" \
    -t "${SCIM_BRIDGE_IMAGE}" \
    -f "${DOCKERFILE}" \
    --push \
    "${DOCKER_CONTEXT}"
fi

echo "[scim-bridge] published ${SCIM_BRIDGE_IMAGE}"
echo "[scim-bridge] digest (best effort):"
docker buildx imagetools inspect "${SCIM_BRIDGE_IMAGE}" 2>/dev/null | sed -n '1,80p' || true
