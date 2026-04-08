#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

gate="shared/scripts/tenant/run-tenant-pr-gates.sh"
secret_gate="shared/scripts/tenant/validate-no-secrets-in-git.sh"

echo "==> Validating tenant PR gates suite"

if [[ ! -x "${gate}" ]]; then
  echo "error: missing gate script: ${gate}" >&2
  exit 1
fi

if [[ ! -x "${secret_gate}" ]]; then
  echo "error: missing secret gate script: ${secret_gate}" >&2
  exit 1
fi

org_id="acme"
project_id="payments"

valid_repo="tests/fixtures/tenant-repo/valid"
invalid_prohibited="tests/fixtures/tenant-repo/invalid-prohibited-kind"
invalid_namespace="tests/fixtures/tenant-repo/invalid-namespace"
invalid_policy="tests/fixtures/tenant-repo/invalid-policy"
invalid_policy_netpol_scope="tests/fixtures/tenant-repo/invalid-policy-netpol-scope"

echo ""
echo "==> Positive case: valid fixture"
"${gate}" --org-id "${org_id}" --project-id "${project_id}" --repo-root "${valid_repo}"

echo ""
echo "==> Negative case: prohibited kind"
if "${gate}" --org-id "${org_id}" --project-id "${project_id}" --repo-root "${invalid_prohibited}" --skip-secret-scan >/dev/null 2>&1; then
  echo "FAIL: expected failure for prohibited kind fixture" >&2
  exit 1
fi

echo ""
echo "==> Negative case: namespace boundary"
if "${gate}" --org-id "${org_id}" --project-id "${project_id}" --repo-root "${invalid_namespace}" --skip-secret-scan >/dev/null 2>&1; then
  echo "FAIL: expected failure for namespace boundary fixture" >&2
  exit 1
fi

echo ""
echo "==> Negative case: policy-aware lint"
if "${gate}" --org-id "${org_id}" --project-id "${project_id}" --repo-root "${invalid_policy}" --skip-secret-scan >/dev/null 2>&1; then
  echo "FAIL: expected failure for policy-aware lint fixture" >&2
  exit 1
fi

echo ""
echo "==> Negative case: policy-aware lint (NetworkPolicy selector scope)"
if "${gate}" --org-id "${org_id}" --project-id "${project_id}" --repo-root "${invalid_policy_netpol_scope}" --skip-secret-scan >/dev/null 2>&1; then
  echo "FAIL: expected failure for NetworkPolicy selector scope fixture" >&2
  exit 1
fi

echo ""
echo "==> Negative case: secret scan (generated fixture)"
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}" || true; }
trap cleanup EXIT INT TERM

mkdir -p "${tmpdir}/repo"
tar -C "${valid_repo}" -cf - . | tar -C "${tmpdir}/repo" -xf -

token="AGE-SECRET-KEY-1$(printf 'Q%.0s' {1..58})"
echo "${token}" > "${tmpdir}/repo/token.txt"

if "${secret_gate}" --source "${tmpdir}/repo" >/dev/null 2>&1; then
  echo "FAIL: expected secret scan failure for generated token fixture" >&2
  exit 1
fi

echo ""
echo "tenant PR gates suite validation PASSED"
