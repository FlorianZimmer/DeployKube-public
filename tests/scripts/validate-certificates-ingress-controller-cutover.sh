#!/usr/bin/env bash
# validate-certificates-ingress-controller-cutover.sh - Ensure platform ingress certs are controller-owned (no repo-side renderer)
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
require find
require yq

render_script="scripts/deployments/render-certificates-ingress.sh"
deploy_main="platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml"
overlays_dir="platform/gitops/components/certificates/ingress/overlays"

if [[ -e "${render_script}" ]]; then
  fail "legacy renderer still present: ${render_script}"
fi
if [[ ! -f "${deploy_main}" ]]; then
  fail "missing tenant-provisioner deployment: ${deploy_main}"
fi
if ! rg -n -q --fixed-strings -- "--platform-ingress-certs-observe-only=false" "${deploy_main}"; then
  fail "tenant-provisioner is not in apply-mode for platform ingress certs (expected --platform-ingress-certs-observe-only=false): ${deploy_main}"
fi

if [[ ! -d "${overlays_dir}" ]]; then
  fail "missing overlays dir (expected to exist, but empty): ${overlays_dir}"
fi
if find "${overlays_dir}" -type f -name '*.yaml' -print -quit | rg -q '.'; then
  fail "legacy per-deployment overlay YAMLs still present under: ${overlays_dir}"
fi

for env in mac-orbstack-single proxmox-talos; do
  overlay="platform/gitops/components/platform/platform-apps-controller/overlays/${env}/patch-platformapps.yaml"
  if [[ ! -f "${overlay}" ]]; then
    fail "missing ${overlay}"
  fi
  if ! yq -e '.spec.disabledApps[] | select(. == "certificates-platform-ingress")' "${overlay}" >/dev/null; then
    fail "expected certificates-platform-ingress disabled in ${overlay}"
  fi
done

echo "certificates/ingress controller cutover validation PASSED"
