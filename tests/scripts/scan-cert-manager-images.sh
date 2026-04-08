#!/usr/bin/env bash
# scan-cert-manager-images.sh
# Backward-compatible wrapper over the centralized Trivy CI runner.
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

require_cmd jq

output_dir="$(mktemp -d "${root_dir}/tmp/trivy-cert-manager.XXXXXX")"
cleanup() {
  rm -rf "${output_dir}"
}
trap cleanup EXIT INT TERM

echo "==> Scanning cert-manager pinned images"
scan_args=(
  --component cert-manager
  --output-dir "${output_dir}"
  --skip-sarif
  --skip-sbom
)
if [[ -n "${SMOKE_IMAGE_OVERRIDE:-}" ]]; then
  scan_args+=(--image-override "smoke=${SMOKE_IMAGE_OVERRIDE}")
fi

./tests/scripts/scan-trivy-ci.sh \
  "${scan_args[@]}" >/dev/null

jq -c '.image_results[] | {label: .id, image: .ref, critical: .critical, high: .high}' "${output_dir}/summary.json"
