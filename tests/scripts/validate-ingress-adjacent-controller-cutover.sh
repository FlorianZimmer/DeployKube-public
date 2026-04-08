#!/usr/bin/env bash
# validate-ingress-adjacent-controller-cutover.sh - Ensure ingress-adjacent hostname overlays are controller-owned (no repo-side renderer)
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

render_script="scripts/deployments/render-ingress-adjacent-overlays.sh"
legacy_validator="tests/scripts/validate-ingress-adjacent-overlays.sh"
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
if ! rg -n -q --fixed-strings -- "--ingress-adjacent-observe-only=false" "${deploy_main}"; then
  fail "tenant-provisioner is not in apply-mode for ingress-adjacent hostnames (expected --ingress-adjacent-observe-only=false): ${deploy_main}"
fi
if [[ ! -f "${platform_apps_base}" ]]; then
  fail "missing PlatformApps base spec: ${platform_apps_base}"
fi

# These must now point at component roots.
for app in platform-argocd-ingress platform-forgejo-ingress secrets-vault-ingress platform-keycloak-ingress platform-observability-ingress; do
  path="$(yq -r ".spec.apps[] | select(.name == \"${app}\") | .path" "${platform_apps_base}")"
  if [[ -z "${path}" || "${path}" == "null" ]]; then
    fail "missing ${app} in PlatformApps spec"
  fi
  if [[ "${path}" == *"/overlays/"* ]]; then
    fail "${app} still points at overlays in PlatformApps spec (${path})"
  fi
done

# Overlays directories that were previously renderer-owned should now be empty of YAML files.
empty_overlays_dirs=(
  "platform/gitops/components/platform/argocd/ingress/overlays"
  "platform/gitops/components/platform/forgejo/ingress/overlays"
  "platform/gitops/components/secrets/vault/ingress/overlays"
  "platform/gitops/components/platform/keycloak/ingress/overlays"
  "platform/gitops/components/platform/observability/ingress/overlays"
)

for d in "${empty_overlays_dirs[@]}"; do
  if [[ ! -d "${d}" ]]; then
    fail "missing overlays dir: ${d}"
  fi
  if find "${d}" -type f -name '*.yaml' -print -quit | rg -q '.'; then
    fail "unexpected YAML remains under renderer-retired overlays dir: ${d}"
  fi
done

# Garage still uses per-deployment overlays for non-hostname patches, but hostname patch must be gone.
garage_overlays="platform/gitops/components/storage/garage/overlays"
if [[ ! -d "${garage_overlays}" ]]; then
  fail "missing garage overlays dir: ${garage_overlays}"
fi
if find "${garage_overlays}" -type f -name 'patch-httproute-host.yaml' -print -quit | rg -q '.'; then
  fail "legacy garage hostname patch still present under: ${garage_overlays}"
fi
if rg -n -q --fixed-strings -- "patch-httproute-host.yaml" "${garage_overlays}"/**/kustomization.yaml 2>/dev/null; then
  fail "garage overlays still reference patch-httproute-host.yaml"
fi

echo "ingress-adjacent controller cutover validation PASSED"
