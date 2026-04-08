#!/usr/bin/env bash
# validate-cert-manager-supply-chain-contract.sh
# Repo-only supply-chain contract for the cert-manager component.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

require_cmd rg
require_cmd yq

values_file="platform/gitops/components/certificates/cert-manager/helm/values.yaml"
kustomization_file="platform/gitops/components/certificates/cert-manager/helm/kustomization.yaml"
chart_file="platform/gitops/components/certificates/cert-manager/helm/charts/cert-manager/Chart.yaml"
metadata_file="platform/gitops/components/certificates/cert-manager/helm/upstream-chart-metadata.yaml"
rendered_file="platform/gitops/components/certificates/cert-manager/helm/rendered-chart.yaml"
readme_file="platform/gitops/components/certificates/cert-manager/README.md"
smoke_file="platform/gitops/components/certificates/cert-manager/tests/job-certificate-smoke.yaml"

echo "==> Validating cert-manager supply-chain contract"

chart_version="$(yq -r '.version' "${chart_file}")"
vendored_version="$(yq -r '.version' "${chart_file}")"
app_version="$(yq -r '.appVersion' "${chart_file}")"
metadata_version="$(yq -r '.version' "${metadata_file}")"
archive_sha="$(yq -r '.archive_sha256' "${metadata_file}")"
keyring_url="$(yq -r '.keyring_url' "${metadata_file}")"
fingerprint="$(yq -r '.keyring_fingerprint' "${metadata_file}")"

if [[ "${chart_version}" != "${vendored_version}" ]]; then
  fail "kustomization chart version ${chart_version} does not match vendored Chart.yaml version ${vendored_version}"
fi

if [[ "${chart_version}" != "${app_version}" ]]; then
  fail "kustomization chart version ${chart_version} does not match vendored Chart.yaml appVersion ${app_version}"
fi

if [[ "${chart_version}" != "${metadata_version}" ]]; then
  fail "upstream-chart-metadata.yaml version ${metadata_version} does not match chart version ${chart_version}"
fi

if ! yq -e '.resources[] | select(. == "rendered-chart.yaml")' "${kustomization_file}" >/dev/null 2>&1; then
  fail "kustomization must include rendered-chart.yaml"
fi

if rg -n '(^|[[:space:]])helmCharts:' "${kustomization_file}" >/dev/null 2>&1; then
  fail "kustomization must not use helmCharts after renderer retirement"
fi

if [[ ! -s "${rendered_file}" ]]; then
  fail "rendered chart manifest ${rendered_file} is missing or empty"
fi

if ! rg -n -F -m1 'Source: cert-manager/templates/deployment.yaml' "${rendered_file}" >/dev/null 2>&1; then
  fail "rendered-chart.yaml does not look like a committed cert-manager chart render"
fi

if [[ ! "${archive_sha}" =~ ^[0-9a-f]{64}$ ]]; then
  fail "upstream-chart-metadata.yaml archive_sha256 is not a sha256 digest: ${archive_sha}"
fi

if [[ ! "${fingerprint}" =~ ^[0-9A-F]{40}$ ]]; then
  fail "upstream-chart-metadata.yaml keyring_fingerprint is not a 40-char uppercase fingerprint: ${fingerprint}"
fi

if [[ "${keyring_url}" != https://cert-manager.io/public-keys/* ]]; then
  fail "unexpected keyring URL in upstream-chart-metadata.yaml: ${keyring_url}"
fi

image_refs=(
  "$(yq -r '.image.repository + "@" + .image.digest' "${values_file}")"
  "$(yq -r '.webhook.image.repository + "@" + .webhook.image.digest' "${values_file}")"
  "$(yq -r '.cainjector.image.repository + "@" + .cainjector.image.digest' "${values_file}")"
  "$(yq -r '.acmesolver.image.repository + "@" + .acmesolver.image.digest' "${values_file}")"
  "$(yq -r '.startupapicheck.image.repository + "@" + .startupapicheck.image.digest' "${values_file}")"
)

for ref in "${image_refs[@]}"; do
  if [[ ! "${ref}" =~ ^quay\.io/jetstack/cert-manager-[a-z]+@sha256:[0-9a-f]{64}$ ]]; then
    fail "unexpected cert-manager image reference: ${ref}"
    continue
  fi

  if ! rg -n -F -m1 "\`${ref}\`" "${readme_file}" >/dev/null 2>&1; then
    fail "README does not document pinned image reference ${ref}"
  fi
done

smoke_ref="$(yq -r '.spec.template.spec.containers[] | select(.name == "smoke") | .image' "${smoke_file}")"
if [[ ! "${smoke_ref}" =~ ^registry\.example\.internal/deploykube/validation-tools-core@sha256:[0-9a-f]{64}$ ]]; then
  fail "smoke job image is not digest-pinned: ${smoke_ref}"
fi

if ! rg -n -F -m1 "./tests/scripts/validate-cert-manager-supply-chain-contract.sh" "${readme_file}" >/dev/null 2>&1; then
  fail "README must reference validate-cert-manager-supply-chain-contract.sh"
fi

if ! rg -n -F -m1 "./tests/scripts/verify-cert-manager-chart-vendor.sh" "${readme_file}" >/dev/null 2>&1; then
  fail "README must reference verify-cert-manager-chart-vendor.sh"
fi

if ! rg -n -F -m1 "./tests/scripts/scan-cert-manager-images.sh" "${readme_file}" >/dev/null 2>&1; then
  fail "README must reference scan-cert-manager-images.sh"
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "cert-manager supply-chain contract FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "cert-manager supply-chain contract PASSED"
