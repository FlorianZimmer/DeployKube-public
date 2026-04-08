#!/usr/bin/env bash
# validate-loki-limits-controller-cutover.sh - Ensure Loki limits are controller-owned (no repo-side renderer)
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require rg
require yq

render_script="scripts/deployments/render-observability-loki.sh"
legacy_validator="tests/scripts/validate-observability-loki-overlays.sh"
deploy_main="platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml"
platform_apps_base="platform/gitops/components/platform/platform-apps-controller/base/platformapps.platform.darksite.cloud.yaml"

if [[ -e "${render_script}" ]]; then
  fail "legacy renderer still present: ${render_script}"
fi
if [[ -e "${legacy_validator}" ]]; then
  fail "legacy drift validator still present: ${legacy_validator}"
fi
if [[ ! -f "${deploy_main}" ]]; then
  fail "missing tenant-provisioner deployment: ${deploy_main}"
fi
if ! rg -n -q --fixed-strings -- "--loki-limits-observe-only=false" "${deploy_main}"; then
  fail "tenant-provisioner is not in apply-mode for Loki limits (expected --loki-limits-observe-only=false): ${deploy_main}"
fi
if [[ ! -f "${platform_apps_base}" ]]; then
  fail "missing PlatformApps base spec: ${platform_apps_base}"
fi

if ! yq -e '.spec.apps[] | select(.name == "platform-observability-loki") | .ignoreDifferences[] | select(.kind == "ConfigMap" and .name == "loki") | .jsonPointers[] | select(. == "/data/config.yaml")' "${platform_apps_base}" >/dev/null; then
  fail "platform-observability-loki missing ignoreDifferences ConfigMap/loki /data/config.yaml in PlatformApps spec"
fi

echo "loki limits controller cutover validation PASSED"
