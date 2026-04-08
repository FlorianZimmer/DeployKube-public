#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEFAULT_IMAGE="registry.example.internal/deploykube/validation-tools-core:0.1.0"
DEFAULT_DOCKERFILE="${REPO_ROOT}/shared/images/validation-tools-core/Dockerfile"
DEFAULT_CONTEXT="$(dirname "${DEFAULT_DOCKERFILE}")"
DEFAULT_PLATFORMS="linux/amd64,linux/arm64"
DEFAULT_BUILDER="deploykube-validation-tools-core"

VALIDATION_TOOLS_CORE_IMAGE="${VALIDATION_TOOLS_CORE_IMAGE:-${DEFAULT_IMAGE}}"
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
    --image) VALIDATION_TOOLS_CORE_IMAGE="$2"; shift 2 ;;
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

echo "[validation-tools-core] ensuring buildx builder: ${BUILDER}"
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDER}" --use >/dev/null
else
  docker buildx use "${BUILDER}" >/dev/null
fi

echo "[validation-tools-core] building and pushing ${VALIDATION_TOOLS_CORE_IMAGE} (${PLATFORMS})"
docker buildx build \
  --platform "${PLATFORMS}" \
  -t "${VALIDATION_TOOLS_CORE_IMAGE}" \
  -f "${DOCKERFILE}" \
  --push \
  "${DOCKER_CONTEXT}"

echo "[validation-tools-core] published ${VALIDATION_TOOLS_CORE_IMAGE}"
echo "[validation-tools-core] digest (best effort):"
docker buildx imagetools inspect "${VALIDATION_TOOLS_CORE_IMAGE}" 2>/dev/null | sed -n '1,80p' || true
