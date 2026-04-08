#!/usr/bin/env bash
# validate-access-guardrails-supply-chain-contract.sh
# Repo-only verification control for access-guardrails smoke image references.
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
require_cmd sed

echo "==> Validating access-guardrails smoke image supply-chain contract"

expected_ref="$(sed -n 's/.*Bootstrap tools image (used by bootstrap + many Jobs): `\([^`]*\)`.*/\1/p' target-stack.md | head -n1)"
if [[ -z "${expected_ref}" ]]; then
  fail "could not extract canonical bootstrap-tools reference from target-stack.md"
fi

if [[ ! "${expected_ref}" =~ ^registry\.example\.internal/deploykube/bootstrap-tools:[0-9]+\.[0-9]+$ ]]; then
  fail "canonical bootstrap-tools reference in target-stack.md is not a fixed version tag: ${expected_ref}"
fi

smoke_files=(
  "platform/gitops/components/shared/access-guardrails/smoke-tests/base/cronjob-allow-rbac-mutations.yaml"
  "platform/gitops/components/shared/access-guardrails/smoke-tests/base/cronjob-deny-rbac-mutations.yaml"
  "platform/gitops/components/shared/access-guardrails/smoke-tests/base/cronjob-oidc-runtime-validation.yaml"
)

for file in "${smoke_files[@]}"; do
  if [[ ! -f "${file}" ]]; then
    fail "missing file: ${file}"
    continue
  fi

  if ! rg -n -F -m1 "image: ${expected_ref}" "${file}" >/dev/null 2>&1; then
    fail "${file}: expected image reference not found: ${expected_ref}"
  fi

  refs="$(rg -o "registry\\.darksite\\.cloud/florianzimmer/deploykube/bootstrap-tools:[A-Za-z0-9._-]+" "${file}" || true)"
  if [[ -z "${refs}" ]]; then
    fail "${file}: no bootstrap-tools image reference found"
    continue
  fi

  unique_refs="$(printf '%s\n' "${refs}" | sort -u)"
  unique_count="$(printf '%s\n' "${unique_refs}" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  if [[ "${unique_count}" != "1" ]]; then
    fail "${file}: multiple bootstrap-tools references found (${unique_count}); expected exactly one canonical ref"
    printf '%s\n' "${unique_refs}" >&2
    continue
  fi

  only_ref="$(printf '%s\n' "${unique_refs}" | head -n1)"
  if [[ "${only_ref}" != "${expected_ref}" ]]; then
    fail "${file}: bootstrap-tools reference drifted (${only_ref}); expected ${expected_ref}"
  fi
done

readme_file="platform/gitops/components/shared/access-guardrails/README.md"
if [[ ! -f "${readme_file}" ]]; then
  fail "missing file: ${readme_file}"
else
  if ! rg -n -F -m1 "\`${expected_ref}\`" "${readme_file}" >/dev/null 2>&1; then
    fail "${readme_file}: README does not document canonical smoke image reference ${expected_ref}"
  fi
  if ! rg -n -F -m1 "./tests/scripts/validate-access-guardrails-supply-chain-contract.sh" "${readme_file}" >/dev/null 2>&1; then
    fail "${readme_file}: README must reference the verification control script"
  fi
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "access-guardrails supply-chain contract FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "access-guardrails supply-chain contract PASSED"
