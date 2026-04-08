#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require rg

deploy_main="platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml"
deploy_forgejo="platform/gitops/components/platform/tenant-provisioner/base/deployment-tenant-forgejo-controller.yaml"
dockerfile="shared/images/tenant-provisioner/Dockerfile"
proxmox_patch="platform/gitops/apps/environments/proxmox-talos/patches/patch-all-apps-bootstrap-tools-image.yaml"
mac_stage0="shared/scripts/bootstrap-mac-orbstack-stage0.sh"
proxmox_stage0="shared/scripts/bootstrap-proxmox-talos-stage0.sh"

if [[ ! -f "${deploy_main}" ]]; then
  echo "error: missing ${deploy_main}" >&2
  exit 1
fi
if [[ ! -f "${deploy_forgejo}" ]]; then
  echo "error: missing ${deploy_forgejo}" >&2
  exit 1
fi
if [[ ! -f "${dockerfile}" ]]; then
  echo "error: missing ${dockerfile}" >&2
  exit 1
fi
if [[ ! -f "${proxmox_patch}" ]]; then
  echo "error: missing ${proxmox_patch}" >&2
  exit 1
fi

extract_image() {
  local file="$1"
  local img=""
  img="$(
    rg -n -m1 '^\s*image:\s*\S*tenant-provisioner:\S+' "${file}" \
      | sed -E 's/^.*image:[[:space:]]*//' \
      | sed -E 's/[[:space:]]+#.*$//' \
      | tr -d '"' \
      | head -n 1 \
      || true
  )"
  if [[ -z "${img}" ]]; then
    echo "error: could not find tenant-provisioner image in ${file}" >&2
    exit 1
  fi
  printf '%s' "${img}"
}

image_main="$(extract_image "${deploy_main}")"
image_forgejo="$(extract_image "${deploy_forgejo}")"

if [[ "${image_main}" != "${image_forgejo}" ]]; then
  echo "FAIL: tenant-provisioner image mismatch between deployments" >&2
  echo "  - ${deploy_main}:   ${image_main}" >&2
  echo "  - ${deploy_forgejo}: ${image_forgejo}" >&2
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
  echo "FAIL: tenant-provisioner version drift (Dockerfile label vs GitOps image tag)" >&2
  echo "  - Dockerfile: ${dockerfile_version}" >&2
  echo "  - GitOps tag:  ${tag} (${image_main})" >&2
  exit 1
fi

want_override="registry.example.internal/deploykube/tenant-provisioner:${tag}=198.51.100.11:5010/deploykube/tenant-provisioner:${tag}"
if ! rg -n -q -F -- "${want_override}" "${proxmox_patch}"; then
  echo "FAIL: proxmox image override missing tenant-provisioner mapping (${want_override})" >&2
  echo "  file: ${proxmox_patch}" >&2
  exit 1
fi

if [[ -f "${mac_stage0}" ]] && ! rg -n -q -F -- "tenant-provisioner:${tag}" "${mac_stage0}"; then
  echo "FAIL: mac stage0 does not reference tenant-provisioner:${tag} (keep defaults in sync)" >&2
  echo "  file: ${mac_stage0}" >&2
  exit 1
fi

if [[ -f "${proxmox_stage0}" ]] && ! rg -n -q -F -- "tenant-provisioner:${tag}" "${proxmox_stage0}"; then
  echo "FAIL: proxmox stage0 does not reference tenant-provisioner:${tag} (keep defaults in sync)" >&2
  echo "  file: ${proxmox_stage0}" >&2
  exit 1
fi

echo "tenant-provisioner image wiring validation PASSED (tag=${tag})"
