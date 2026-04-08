#!/usr/bin/env bash
# validate-egress-proxy-controller-cutover.sh - Ensure egress-proxy is controller-owned (no repo-side renderer)
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

render_script="scripts/deployments/render-egress-proxy.sh"
rendered_yaml="platform/gitops/components/networking/egress-proxy/rendered.yaml"
deploy_main="platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml"

if [[ -e "${render_script}" ]]; then
  fail "legacy renderer still present: ${render_script}"
fi
if [[ -e "${rendered_yaml}" ]]; then
  fail "legacy rendered manifest still present: ${rendered_yaml}"
fi
if [[ ! -f "${deploy_main}" ]]; then
  fail "missing tenant-provisioner deployment: ${deploy_main}"
fi
if ! rg -n -q --fixed-strings -- "--egress-proxy-observe-only=false" "${deploy_main}"; then
  fail "tenant-provisioner is not in apply-mode for egress proxy (expected --egress-proxy-observe-only=false): ${deploy_main}"
fi

for env in mac-orbstack-single proxmox-talos; do
  overlay="platform/gitops/components/platform/platform-apps-controller/overlays/${env}/patch-platformapps.yaml"
  if [[ ! -f "${overlay}" ]]; then
    fail "missing ${overlay}"
  fi
  if ! yq -e '.spec.disabledApps[] | select(. == "networking-egress-proxy")' "${overlay}" >/dev/null; then
    fail "expected networking-egress-proxy disabled in ${overlay}"
  fi
done

echo "egress proxy controller cutover validation PASSED"
