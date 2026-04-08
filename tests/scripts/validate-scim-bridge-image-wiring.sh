#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require rg
require yq

deploy_main="platform/gitops/components/platform/keycloak/scim-bridge/base/deployment.yaml"
dockerfile="shared/images/scim-bridge/Dockerfile"
package_index="platform/gitops/artifacts/package-index.yaml"
proxmox_patch="platform/gitops/apps/environments/proxmox-talos/patches/patch-all-apps-bootstrap-tools-image.yaml"
publish_script="shared/scripts/publish-scim-bridge-image.sh"
build_script="shared/scripts/build-scim-bridge-image.sh"

for file in "${deploy_main}" "${dockerfile}" "${package_index}" "${proxmox_patch}" "${publish_script}" "${build_script}"; do
  if [[ ! -f "${file}" ]]; then
    echo "error: missing ${file}" >&2
    exit 1
  fi
done

image_main="$(
  rg -n -m1 '^\s*image:\s*\S*scim-bridge:\S+' "${deploy_main}" \
    | sed -E 's/^.*image:[[:space:]]*//' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | tr -d '"' \
    | head -n 1 \
    || true
)"
if [[ -z "${image_main}" ]]; then
  echo "FAIL: could not find scim-bridge image in ${deploy_main}" >&2
  exit 1
fi

package_ref="$(yq -r '.spec.images[] | select(.name == "scim-bridge") | .source' "${package_index}")"
if [[ -z "${package_ref}" || "${package_ref}" == "null" ]]; then
  echo "FAIL: package index missing scim-bridge source ref" >&2
  exit 1
fi

if [[ "${package_ref}" != "${image_main}" ]]; then
  echo "FAIL: scim-bridge image mismatch between deployment and package index" >&2
  echo "  - ${deploy_main}: ${image_main}" >&2
  echo "  - ${package_index}: ${package_ref}" >&2
  exit 1
fi

tag="${image_main##*:}"
if [[ -z "${tag}" || "${tag}" == "${image_main}" ]]; then
  echo "FAIL: could not extract image tag from ${image_main}" >&2
  exit 1
fi

dockerfile_version="$(
  rg -m1 '^LABEL org\.opencontainers\.image\.version=' "${dockerfile}" \
    | sed -E 's/^LABEL org\.opencontainers\.image\.version="([^"]+)".*/\1/' \
    || true
)"
if [[ -z "${dockerfile_version}" ]]; then
  echo "FAIL: could not extract Dockerfile version label from ${dockerfile}" >&2
  exit 1
fi

if [[ "${dockerfile_version}" != "${tag}" ]]; then
  echo "FAIL: scim-bridge version drift (Dockerfile label vs GitOps image tag)" >&2
  echo "  - Dockerfile: ${dockerfile_version}" >&2
  echo "  - GitOps tag:  ${tag} (${image_main})" >&2
  exit 1
fi

want_override="registry.example.internal/deploykube/scim-bridge:${tag}=198.51.100.11:5010/deploykube/scim-bridge:${tag}"
if ! rg -n -q -F -- "${want_override}" "${proxmox_patch}"; then
  echo "FAIL: proxmox image override missing scim-bridge mapping (${want_override})" >&2
  echo "  file: ${proxmox_patch}" >&2
  exit 1
fi

echo "scim-bridge image wiring validation PASSED (tag=${tag})"
