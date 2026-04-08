#!/usr/bin/env bash
set -euo pipefail

# Build and publish the DeployKube bootstrap-tools image to a real registry
# (default: registry.example.internal).
#
# This is the “proper” fix for non-kind clusters (e.g. Talos on Proxmox) where images cannot be
# side-loaded easily and must be pullable by Kubernetes nodes.
#
# Requirements:
#   - docker (with buildx)
#   - authenticated `docker login` to the target registry
#
# Example:
#   docker login registry.example.internal
#   ./shared/scripts/publish-bootstrap-tools-image.sh
#
# Optional:
#   BOOTSTRAP_TOOLS_IMAGE=registry.example.internal/deploykube/bootstrap-tools:1.4 ./shared/scripts/publish-bootstrap-tools-image.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEFAULT_IMAGE="registry.example.internal/deploykube/bootstrap-tools:1.4"
DEFAULT_DOCKERFILE="${REPO_ROOT}/shared/images/bootstrap-tools/Dockerfile"
DEFAULT_CONTEXT="$(dirname "${DEFAULT_DOCKERFILE}")"
DEFAULT_PLATFORMS="linux/amd64,linux/arm64"
DEFAULT_BUILDER="deploykube-bootstrap-tools"

BOOTSTRAP_TOOLS_IMAGE="${BOOTSTRAP_TOOLS_IMAGE:-${DEFAULT_IMAGE}}"
DOCKERFILE="${DOCKERFILE:-${DEFAULT_DOCKERFILE}}"
DOCKER_CONTEXT="${DOCKER_CONTEXT:-${DEFAULT_CONTEXT}}"
PLATFORMS="${PLATFORMS:-${DEFAULT_PLATFORMS}}"
BUILDER="${BUILDER:-${DEFAULT_BUILDER}}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--image <ref>] [--dockerfile <path>] [--context <path>] [--platforms <csv>] [--builder <name>]

Defaults:
  --image       ${DEFAULT_IMAGE}
  --dockerfile  ${DEFAULT_DOCKERFILE}
  --context     ${DEFAULT_CONTEXT}
  --platforms   ${DEFAULT_PLATFORMS}
  --builder     ${DEFAULT_BUILDER}
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) BOOTSTRAP_TOOLS_IMAGE="$2"; shift 2 ;;
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    --context) DOCKER_CONTEXT="$2"; shift 2 ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --builder) BUILDER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Dockerfile ${DOCKERFILE} not found" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

echo "[bootstrap-tools] ensuring buildx builder: ${BUILDER}"
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDER}" --use >/dev/null
else
  docker buildx use "${BUILDER}" >/dev/null
fi

echo "[bootstrap-tools] building and pushing ${BOOTSTRAP_TOOLS_IMAGE} (${PLATFORMS})"
docker buildx build \
  --platform "${PLATFORMS}" \
  -t "${BOOTSTRAP_TOOLS_IMAGE}" \
  -f "${DOCKERFILE}" \
  --push \
  "${DOCKER_CONTEXT}"

echo "[bootstrap-tools] published ${BOOTSTRAP_TOOLS_IMAGE}"
echo "[bootstrap-tools] digest (best effort):"
docker buildx imagetools inspect "${BOOTSTRAP_TOOLS_IMAGE}" 2>/dev/null | sed -n '1,80p' || true
