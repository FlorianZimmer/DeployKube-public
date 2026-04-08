#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

gate="shared/scripts/tenant/validate-prohibited-kinds.sh"
config="shared/contracts/tenant-prohibited-kinds.yaml"
allowed="tests/fixtures/tenant-prohibited-kinds/allowed.yaml"
forbidden="tests/fixtures/tenant-prohibited-kinds/forbidden.yaml"

echo "==> Validating tenant prohibited kinds gate"

if [[ ! -x "${gate}" ]]; then
  echo "error: missing gate script: ${gate}" >&2
  exit 1
fi

"${gate}" --config "${config}" "${allowed}"

if "${gate}" --config "${config}" "${forbidden}" >/dev/null 2>&1; then
  echo "FAIL: prohibited kinds gate should fail for forbidden fixture: ${forbidden}" >&2
  exit 1
fi

echo "tenant prohibited kinds gate validation PASSED"

