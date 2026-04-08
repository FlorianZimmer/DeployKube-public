#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

echo "==> Validating tenant repo CI template (tenant PR gates)"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency rg

template_forgejo="shared/templates/tenant-repo/.forgejo/workflows/tenant-pr-gates.yaml"
template_github="shared/templates/tenant-repo/.github/workflows/tenant-pr-gates.yaml"

fixture_root="platform/gitops/tenant-repos/tenant-factorio/apps-factorio"
fixture_workflow="${fixture_root}/.forgejo/workflows/tenant-pr-gates.yaml"
fixture_gate="${fixture_root}/shared/scripts/tenant/run-tenant-pr-gates.sh"
fixture_contract="${fixture_root}/shared/contracts/tenant-prohibited-kinds.yaml"

require_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "FAIL: missing file: ${file}" >&2
    exit 1
  fi
}

require_file "${template_forgejo}"
require_file "${template_github}"
require_file "${fixture_workflow}"
require_file "${fixture_gate}"
require_file "${fixture_contract}"

require_contains() {
  local file="$1"
  local pattern="$2"
  if ! rg -n -q --fixed-strings "${pattern}" "${file}"; then
    echo "FAIL: ${file}: missing '${pattern}'" >&2
    exit 1
  fi
}

require_contains "${template_forgejo}" "name: tenant-pr-gates"
require_contains "${template_forgejo}" "./shared/scripts/tenant/run-tenant-pr-gates.sh"

require_contains "${template_github}" "name: tenant-pr-gates"
require_contains "${template_github}" "./shared/scripts/tenant/run-tenant-pr-gates.sh"

require_contains "${fixture_workflow}" "name: tenant-pr-gates"
require_contains "${fixture_workflow}" "./shared/scripts/tenant/run-tenant-pr-gates.sh"

echo "tenant repo CI template validation PASSED"

