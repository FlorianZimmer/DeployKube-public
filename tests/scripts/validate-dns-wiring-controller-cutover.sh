#!/usr/bin/env bash
# validate-dns-wiring-controller-cutover.sh - Ensure DNS wiring is controller-owned (no repo-side renderer)
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

render_script="scripts/deployments/render-dns.sh"
legacy_validator="tests/scripts/validate-dns-overlays.sh"
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
if ! rg -n -q --fixed-strings -- "--dns-wiring-observe-only=false" "${deploy_main}"; then
  fail "tenant-provisioner is not in apply-mode for DNS wiring (expected --dns-wiring-observe-only=false): ${deploy_main}"
fi
if [[ ! -f "${platform_apps_base}" ]]; then
  fail "missing PlatformApps base spec: ${platform_apps_base}"
fi

# Ensure app catalog points at component roots for controller-owned DNS apps.
coredns_path="$(yq -r '.spec.apps[] | select(.name == "networking-coredns") | .path' "${platform_apps_base}")"
if [[ "${coredns_path}" != "components/networking/coredns" ]]; then
  fail "networking-coredns must point to components/networking/coredns (got: ${coredns_path})"
fi
if [[ "${coredns_path}" == *"/overlays/"* ]]; then
  fail "networking-coredns must not point at overlays"
fi

external_sync_path="$(yq -r '.spec.apps[] | select(.name == "networking-dns-external-sync") | .path' "${platform_apps_base}")"
if [[ "${external_sync_path}" != "components/dns/external-sync" ]]; then
  fail "networking-dns-external-sync must point to components/dns/external-sync (got: ${external_sync_path})"
fi
if [[ "${external_sync_path}" == *"/overlays/"* ]]; then
  fail "networking-dns-external-sync must not point at overlays"
fi

# Renderer-owned overlays must be empty of YAML after cutover.
empty_overlays_dirs=(
  "platform/gitops/components/networking/coredns/overlays"
  "platform/gitops/components/dns/external-sync/overlays"
)
for d in "${empty_overlays_dirs[@]}"; do
  if [[ ! -d "${d}" ]]; then
    fail "missing overlays dir: ${d}"
  fi
  if find "${d}" -type f -name '*.yaml' -print -quit | rg -q '.'; then
    fail "unexpected YAML remains under renderer-retired overlays dir: ${d}"
  fi
done

# PowerDNS overlays are still allowed (static deltas), but renderer-owned files must not exist.
if find platform/gitops/components/dns/powerdns/overlays -type f -name 'powerdns-config.yaml' -print -quit | rg -q '.'; then
  fail "unexpected rendered powerdns-config.yaml remains under powerdns overlays"
fi
if find platform/gitops/components/dns/powerdns/overlays -type f -name 'externaldns.yaml' -print -quit | rg -q '.'; then
  fail "unexpected rendered externaldns.yaml remains under powerdns overlays"
fi
if find platform/gitops/components/dns/powerdns/overlays -type f -name 'patch-powerdns.yaml' -print -quit | rg -q '.'; then
  fail "unexpected rendered patch-powerdns.yaml remains under powerdns overlays"
fi

# PowerDNS templates must not exist after renderer retirement.
if [[ -d "platform/gitops/components/dns/powerdns/templates" ]]; then
  if find "platform/gitops/components/dns/powerdns/templates" -type f -print -quit | rg -q '.'; then
    fail "powerdns templates still exist under platform/gitops/components/dns/powerdns/templates"
  fi
fi

# Ensure CoreDNS Corefile stub markers exist (controller patches within these markers).
coredns_cm="platform/gitops/components/networking/coredns/base/coredns-configmap.yaml"
if [[ ! -f "${coredns_cm}" ]]; then
  fail "missing coredns configmap: ${coredns_cm}"
fi
if ! rg -n -q --fixed-strings -- "deploykube:stub-domain-begin" "${coredns_cm}"; then
  fail "coredns configmap missing stub-domain markers: ${coredns_cm}"
fi

# Ensure jobs are wired via ConfigMap/deploykube-dns-wiring (not renderer patches).
if rg -n -q --fixed-strings -- "REPLACE_ME_DNS_DOMAIN" platform/gitops/components/dns/external-sync/base/*.yaml; then
  fail "external-sync still contains renderer placeholder literals (REPLACE_ME_DNS_DOMAIN)"
fi
if rg -n -q --fixed-strings -- "REPLACE_ME_DNS_SYNC_HOSTS" platform/gitops/components/dns/external-sync/base/*.yaml; then
  fail "external-sync still contains renderer placeholder literals (REPLACE_ME_DNS_SYNC_HOSTS)"
fi

if ! rg -n -q --fixed-strings -- "name: deploykube-dns-wiring" platform/gitops/components/dns/external-sync/base/*.yaml; then
  fail "external-sync jobs are not wired to ConfigMap/deploykube-dns-wiring"
fi
if ! rg -n -q --fixed-strings -- "name: deploykube-dns-wiring" platform/gitops/components/dns/powerdns/base/*.yaml; then
  fail "powerdns jobs are not wired to ConfigMap/deploykube-dns-wiring"
fi
if ! rg -n -q --fixed-strings -- "name: deploykube-dns-wiring" platform/gitops/components/networking/coredns/base/job-coredns-smoke.yaml; then
  fail "coredns smoke job is not wired to ConfigMap/deploykube-dns-wiring"
fi

echo "dns wiring controller cutover validation PASSED"
