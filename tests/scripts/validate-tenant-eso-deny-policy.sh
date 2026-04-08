#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

policy="platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-deny-external-secrets.yaml"

echo "==> Validating tenant ESO CRDs deny policy (Kyverno)"

if [[ ! -f "${policy}" ]]; then
  echo "error: missing policy file: ${policy}" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "error: missing dependency: yq" >&2
  exit 1
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

name="$(yq -r '.metadata.name // ""' "${policy}")"
if [[ "${name}" != "tenant-deny-external-secrets" ]]; then
  fail "unexpected policy name: ${name} (expected tenant-deny-external-secrets)"
fi

validation_action="$(yq -r '.spec.validationFailureAction // ""' "${policy}")"
if [[ "${validation_action}" != "Enforce" ]]; then
  fail "expected spec.validationFailureAction=Enforce (got ${validation_action})"
fi

deny_message="$(yq -r '.spec.rules[].validate.message // ""' "${policy}" | head -n 1)"
if [[ "${deny_message}" != "Tenant namespaces may not create External Secrets Operator resources (secret projection is platform-owned)." ]]; then
  fail "unexpected deny message: ${deny_message}"
fi

ns_profile_values="$(yq -r '.spec.rules[].match.any[].resources.namespaceSelector.matchLabels."darksite.cloud/rbac-profile" // ""' "${policy}" | sort -u)"
if [[ "${ns_profile_values}" != "tenant" ]]; then
  fail "expected namespaceSelector darksite.cloud/rbac-profile=tenant (got: ${ns_profile_values})"
fi

kinds="$(yq -r '.spec.rules[].match.any[].resources.kinds[]? // ""' "${policy}" | sort -u)"
for expected in ExternalSecret SecretStore PushSecret; do
  if ! printf '%s\n' "${kinds}" | grep -qx "${expected}"; then
    fail "expected kind ${expected} in policy match (kinds=${kinds})"
  fi
done

echo "tenant ESO deny policy validation PASSED"
