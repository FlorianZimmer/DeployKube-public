#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require yq
require rg

crd_app="platform/gitops/apps/base/platform-deployment-config-crd.yaml"
controller_app="platform/gitops/apps/base/platform-deployment-config-controller.yaml"
controller_deploy="platform/gitops/components/platform/deployment-config-controller/base/deployment.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ ! -f "${crd_app}" ]]; then
  fail "missing ${crd_app}"
fi
if [[ ! -f "${controller_app}" ]]; then
  fail "missing ${controller_app}"
fi
if [[ ! -f "${controller_deploy}" ]]; then
  fail "missing ${controller_deploy}"
fi

crd_wave="$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // ""' "${crd_app}" 2>/dev/null || true)"
controller_wave="$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // ""' "${controller_app}" 2>/dev/null || true)"

if [[ "${crd_wave}" != "-11" ]]; then
  fail "${crd_app} must set argocd.argoproj.io/sync-wave: \"-11\" (got '${crd_wave}')"
fi
if [[ "${controller_wave}" != "-9" ]]; then
  fail "${controller_app} must set argocd.argoproj.io/sync-wave: \"-9\" (got '${controller_wave}')"
fi

if ! rg -n -q -F -- '--controller-profile=deployment-config' "${controller_deploy}"; then
  fail "${controller_deploy} must run with --controller-profile=deployment-config"
fi
if ! rg -n -q -F -- '--snapshot-name=deploykube-deployment-config' "${controller_deploy}"; then
  fail "${controller_deploy} must set --snapshot-name=deploykube-deployment-config"
fi
if ! rg -n -q -F -- '--snapshot-key=deployment-config.yaml' "${controller_deploy}"; then
  fail "${controller_deploy} must set --snapshot-key=deployment-config.yaml"
fi

deployments_dir="platform/gitops/deployments"
if rg -n -q -F -g'kustomization.yaml' -- 'name: deploykube-deployment-config' "${deployments_dir}"; then
  fail "${deployments_dir}/*/kustomization.yaml must not configMapGenerate deploykube-deployment-config (snapshot is controller-owned)"
fi

echo "deployment config API validation PASSED"
