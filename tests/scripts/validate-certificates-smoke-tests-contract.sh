#!/usr/bin/env bash
# validate-certificates-smoke-tests-contract.sh
# Repo-only contract for certificates smoke-test runtime hardening and image pinning.
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
require_cmd yq
require_cmd kustomize

echo "==> Validating certificates smoke-tests contract"

readme_file="platform/gitops/components/certificates/smoke-tests/README.md"
networkpolicy_file="platform/gitops/components/certificates/smoke-tests/base/networkpolicies.yaml"
kustomization_file="platform/gitops/components/certificates/smoke-tests/base/kustomization.yaml"
expected_ref="$(sed -n 's/^- \*\*Image:\*\* `\([^`]*\)`.*$/\1/p' "${readme_file}" | head -n1)"
if [[ -z "${expected_ref}" ]]; then
  fail "could not extract canonical image reference from ${readme_file}"
fi

if [[ ! "${expected_ref}" =~ ^registry\.example\.internal/deploykube/validation-tools-core@sha256:[0-9a-f]{64}$ ]]; then
  fail "README canonical image reference must be digest-pinned validation-tools-core: ${expected_ref}"
fi

if [[ ! -f "${networkpolicy_file}" ]]; then
  fail "missing file: ${networkpolicy_file}"
elif ! yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "cert-smoke-egress")' "${networkpolicy_file}" >/dev/null 2>&1; then
  fail "${networkpolicy_file}: missing NetworkPolicy/cert-smoke-egress"
elif ! yq -e 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "cert-smoke-allow-kube-apiserver")' "${networkpolicy_file}" >/dev/null 2>&1; then
  fail "${networkpolicy_file}: missing CiliumNetworkPolicy/cert-smoke-allow-kube-apiserver"
fi

if ! yq -e '.resources[] | select(. == "networkpolicies.yaml")' "${kustomization_file}" >/dev/null 2>&1; then
  fail "${kustomization_file}: must include networkpolicies.yaml"
fi

if ! yq -e '.namespace == null' "${kustomization_file}" >/dev/null 2>&1; then
  fail "${kustomization_file}: must not set a global namespace transformer; resources declare explicit namespaces"
fi

smoke_files=(
  "platform/gitops/components/certificates/smoke-tests/base/cronjob-step-ca-issuance.yaml"
  "platform/gitops/components/certificates/smoke-tests/base/cronjob-ingress-readiness.yaml"
  "platform/gitops/components/certificates/smoke-tests/base/cronjob-gateway-sni.yaml"
  "platform/gitops/components/certificates/smoke-tests/base/cronjob-vault-external-issuance.yaml"
)

for file in "${smoke_files[@]}"; do
  if [[ ! -f "${file}" ]]; then
    fail "missing file: ${file}"
    continue
  fi

  image_ref="$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "smoke") | .image' "${file}")"
  if [[ "${image_ref}" != "${expected_ref}" ]]; then
    fail "${file}: image ref drifted (${image_ref}); expected ${expected_ref}"
  fi

  if ! yq -e '.spec.jobTemplate.spec.template.spec.securityContext.runAsNonRoot == true' "${file}" >/dev/null 2>&1; then
    fail "${file}: pod securityContext.runAsNonRoot must be true"
  fi
  if ! yq -e '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "smoke") | .securityContext.allowPrivilegeEscalation == false' "${file}" >/dev/null 2>&1; then
    fail "${file}: container allowPrivilegeEscalation must be false"
  fi
  if ! yq -e '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "smoke") | .securityContext.readOnlyRootFilesystem == true' "${file}" >/dev/null 2>&1; then
    fail "${file}: container readOnlyRootFilesystem must be true"
  fi
  if ! yq -e '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "smoke") | .resources.requests.cpu == "25m"' "${file}" >/dev/null 2>&1; then
    fail "${file}: expected cpu request 25m"
  fi
  if ! yq -e '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "smoke") | .resources.requests.memory == "64Mi"' "${file}" >/dev/null 2>&1; then
    fail "${file}: expected memory request 64Mi"
  fi
done

if ! rg -n -F -m1 "./tests/scripts/validate-certificates-smoke-tests-contract.sh" "${readme_file}" >/dev/null 2>&1; then
  fail "${readme_file}: README must reference the certificates smoke-tests contract validator"
fi

if ! rg -n -F -m1 "explicit egress allowlists" "${readme_file}" >/dev/null 2>&1; then
  fail "${readme_file}: README must document the explicit egress allowlist posture"
fi

rendered_proxmox="$(mktemp)"
trap 'rm -f "${rendered_proxmox}"' EXIT
kustomize build platform/gitops/components/certificates/smoke-tests/overlays/proxmox-talos > "${rendered_proxmox}"

if ! yq -e 'select(.kind == "Role" and .metadata.name == "cert-smoke-istio-system" and .metadata.namespace == "istio-system")' "${rendered_proxmox}" >/dev/null 2>&1; then
  fail "rendered proxmox overlay must keep Role/cert-smoke-istio-system in namespace istio-system"
fi

if ! yq -e 'select(.kind == "RoleBinding" and .metadata.name == "cert-smoke-istio-system" and .metadata.namespace == "istio-system")' "${rendered_proxmox}" >/dev/null 2>&1; then
  fail "rendered proxmox overlay must keep RoleBinding/cert-smoke-istio-system in namespace istio-system"
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "certificates smoke-tests contract FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "certificates smoke-tests contract PASSED"
