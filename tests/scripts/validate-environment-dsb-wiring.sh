#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require yq

envs_dir="platform/gitops/apps/environments"
gitops_dir="platform/gitops"

if [[ ! -d "${envs_dir}" ]]; then
  echo "error: missing ${envs_dir}" >&2
  exit 1
fi

failures=0
checked=0

mapfile -t env_dirs < <(
  find "${envs_dir}" -mindepth 1 -maxdepth 1 -type d | sort
)

for env_dir in "${env_dirs[@]}"; do
  env_id="$(basename "${env_dir}")"
  dsb_file="${env_dir}/deployment-secrets-bundle.yaml"
  if [[ ! -f "${dsb_file}" ]]; then
    continue
  fi

  checked=$((checked + 1))

  path="$(yq -r '.spec.source.path // ""' "${dsb_file}" 2>/dev/null || true)"
  expected="deployments/${env_id}"

  if [[ "${path}" != "${expected}" ]]; then
    echo "FAIL: environment DSB path mismatch" >&2
    echo "  - file: ${dsb_file}" >&2
    echo "  - expected: ${expected}" >&2
    echo "  - got: ${path}" >&2
    failures=$((failures + 1))
    continue
  fi

  if [[ ! -d "${gitops_dir}/${expected}" ]]; then
    echo "FAIL: environment DSB points to missing directory: ${gitops_dir}/${expected}" >&2
    echo "  - file: ${dsb_file}" >&2
    failures=$((failures + 1))
  fi
done

if [[ "${failures}" -ne 0 ]]; then
  echo "environment DSB wiring validation FAILED (${failures} issue(s); checked ${checked} environment(s))" >&2
  exit 1
fi

echo "environment DSB wiring validation PASSED (checked ${checked} environment(s))"
