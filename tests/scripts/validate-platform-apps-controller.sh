#!/usr/bin/env bash
# validate-platform-apps-controller.sh - Validate PlatformApps controller contract
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require kustomize
require rg
require find

env_root="platform/gitops/apps/environments"
component_root="platform/gitops/components/platform/platform-apps-controller"
base_cr="${component_root}/base/platformapps.platform.darksite.cloud.yaml"

if [[ ! -d "${env_root}" ]]; then
  echo "error: missing ${env_root}" >&2
  exit 1
fi
if [[ ! -d "${component_root}" ]]; then
  echo "error: missing ${component_root}" >&2
  exit 1
fi
if [[ ! -f "${base_cr}" ]]; then
  echo "error: missing ${base_cr}" >&2
  exit 1
fi

# Renderer artifact must no longer be wired in env bundles.
if rg -n -q --fixed-strings -- "overlay-apps.yaml" "${env_root}"/*/kustomization.yaml; then
  echo "error: environment kustomizations must not reference overlay-apps.yaml" >&2
  rg -n --fixed-strings -- "overlay-apps.yaml" "${env_root}"/*/kustomization.yaml >&2
  exit 1
fi

# Supported deployment overlays must exist for the controller-owned API.
for dep in mac-orbstack-single proxmox-talos; do
  overlay_dir="${component_root}/overlays/${dep}"
  if [[ ! -f "${overlay_dir}/kustomization.yaml" ]]; then
    echo "error: missing platform-apps-controller overlay kustomization: ${overlay_dir}/kustomization.yaml" >&2
    exit 1
  fi
  if [[ ! -f "${overlay_dir}/patch-platformapps.yaml" ]]; then
    echo "error: missing platform-apps-controller overlay patch: ${overlay_dir}/patch-platformapps.yaml" >&2
    exit 1
  fi
done

failures=0
checked=0

while IFS= read -r env_dir; do
  checked=$((checked + 1))
  echo ""
  echo "==> ${env_dir}"

  if ! kustomize build "${env_dir}" --enable-helm >/dev/null 2>&1; then
    echo "FAIL: kustomize build failed for ${env_dir}" >&2
    echo "  kustomize build ${env_dir} --enable-helm" >&2
    failures=$((failures + 1))
  else
    echo "PASS"
  fi
done < <(find "${env_root}" -maxdepth 1 -mindepth 1 -type d | sort)

echo ""
echo "==> Summary"
echo "- Checked env bundles: ${checked}"

if [[ "${failures}" -ne 0 ]]; then
  echo "platform-apps controller validation FAILED (${failures} env(s))" >&2
  exit 1
fi

echo "platform-apps controller validation PASSED"
