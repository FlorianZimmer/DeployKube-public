#!/usr/bin/env bash
# verify-cert-manager-chart-vendor.sh
# Manually verify the vendored cert-manager chart against the upstream signed archive.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    sha256sum "${file}" | awk '{print $1}'
  fi
}

require_cmd curl
require_cmd diff
require_cmd gpg
require_cmd tar
require_cmd yq

metadata_file="platform/gitops/components/certificates/cert-manager/helm/upstream-chart-metadata.yaml"
vendored_chart_dir="platform/gitops/components/certificates/cert-manager/helm/charts/cert-manager"

repo_url="$(yq -r '.repo_url' "${metadata_file}")"
chart="$(yq -r '.chart' "${metadata_file}")"
version="$(yq -r '.version' "${metadata_file}")"
archive_sha="$(yq -r '.archive_sha256' "${metadata_file}")"
keyring_url="$(yq -r '.keyring_url' "${metadata_file}")"
fingerprint="$(yq -r '.keyring_fingerprint' "${metadata_file}")"

helm_bin="${HELM_BIN:-}"
if [[ -z "${helm_bin}" ]]; then
  if [[ -x "${root_dir}/tmp/tools/helm" ]]; then
    helm_bin="${root_dir}/tmp/tools/helm"
  else
    helm_bin="helm"
  fi
fi
require_cmd "${helm_bin}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

keyring_file="${workdir}/cert-manager-keyring.gpg"
archive_file="${workdir}/${chart}-${version}.tgz"

echo "==> Downloading cert-manager chart signing key"
curl -fsSL "${keyring_url}" -o "${keyring_file}"

echo "==> Verifying upstream cert-manager chart archive"
"${helm_bin}" pull "${chart}" \
  --repo "${repo_url}" \
  --version "${version}" \
  --verify \
  --keyring "${keyring_file}" \
  --destination "${workdir}" >/dev/null

actual_sha="$(sha256_file "${archive_file}")"
if [[ "${actual_sha}" != "${archive_sha}" ]]; then
  echo "error: archive sha mismatch: expected ${archive_sha}, got ${actual_sha}" >&2
  exit 1
fi

echo "==> Comparing unpacked upstream chart to vendored chart tree"
tar -xzf "${archive_file}" -C "${workdir}"
diff -qr "${workdir}/${chart}" "${vendored_chart_dir}"

echo ""
echo "cert-manager upstream chart verification PASSED"
echo "  version: ${version}"
echo "  fingerprint: ${fingerprint}"
echo "  archive sha256: ${actual_sha}"
