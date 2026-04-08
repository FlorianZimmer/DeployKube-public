#!/usr/bin/env bash
# validate-coredns-upstream-corefile-contract.sh
# Keep the committed CoreDNS root block aligned to the curated upstream baseline.
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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_cmd rg
require_cmd yq
require_cmd diff
require_cmd mktemp

coredns_cm="platform/gitops/components/networking/coredns/base/coredns-configmap.yaml"
baseline_file="platform/gitops/components/networking/coredns/upstream-corefile-baseline.yaml"
readme_file="platform/gitops/components/networking/coredns/README.md"
target_stack_file="target-stack.md"

[[ -f "${coredns_cm}" ]] || fail "missing CoreDNS ConfigMap: ${coredns_cm}"
[[ -f "${baseline_file}" ]] || fail "missing baseline file: ${baseline_file}"
[[ -f "${readme_file}" ]] || fail "missing README: ${readme_file}"
[[ -f "${target_stack_file}" ]] || fail "missing target stack doc: ${target_stack_file}"

begin_marker="# deploykube:stub-domain-begin"
end_marker="# deploykube:stub-domain-end"

committed_corefile="$(yq -r '.data.Corefile' "${coredns_cm}")"
baseline_root_corefile="$(yq -r '.root_corefile' "${baseline_file}")"
kubernetes_version="$(yq -r '.kubernetes_version' "${baseline_file}")"
talos_version="$(yq -r '.talos_version' "${baseline_file}")"

[[ -n "${committed_corefile}" ]] || fail "committed Corefile is empty: ${coredns_cm}"
[[ -n "${baseline_root_corefile}" ]] || fail "baseline root_corefile is empty: ${baseline_file}"
[[ "${kubernetes_version}" != "null" ]] || fail "baseline kubernetes_version missing: ${baseline_file}"
[[ "${talos_version}" != "null" ]] || fail "baseline talos_version missing: ${baseline_file}"

if ! printf '%s\n' "${committed_corefile}" | rg -n -q --fixed-strings -- "${begin_marker}"; then
  fail "committed Corefile missing begin marker ${begin_marker}"
fi
if ! printf '%s\n' "${committed_corefile}" | rg -n -q --fixed-strings -- "${end_marker}"; then
  fail "committed Corefile missing end marker ${end_marker}"
fi

committed_root_corefile="$(
  printf '%s\n' "${committed_corefile}" | awk -v begin="${begin_marker}" -v end="${end_marker}" '
    index($0, begin) { skip=1; next }
    index($0, end) { skip=0; next }
    !skip { print }
  '
)"

[[ -n "${committed_root_corefile}" ]] || fail "failed to isolate committed root Corefile outside managed stub block"

if ! rg -n -F -m1 "Kubernetes \`${kubernetes_version}\`" "${target_stack_file}" >/dev/null; then
  fail "baseline kubernetes_version ${kubernetes_version} not found in ${target_stack_file}"
fi
if ! rg -n -F -m1 "Talos \`${talos_version}\`" "${target_stack_file}" >/dev/null; then
  fail "baseline talos_version ${talos_version} not found in ${target_stack_file}"
fi

if ! rg -n -F -m1 "./tests/scripts/validate-coredns-upstream-corefile-contract.sh" "${readme_file}" >/dev/null; then
  fail "README must reference validate-coredns-upstream-corefile-contract.sh"
fi
if ! rg -n -F -m1 "upstream-corefile-baseline.yaml" "${readme_file}" >/dev/null; then
  fail "README must reference upstream-corefile-baseline.yaml"
fi

baseline_tmp="$(mktemp)"
committed_tmp="$(mktemp)"
trap 'rm -f "${baseline_tmp}" "${committed_tmp}"' EXIT

printf '%s\n' "${baseline_root_corefile}" >"${baseline_tmp}"
printf '%s\n' "${committed_root_corefile}" >"${committed_tmp}"

echo "==> Validating CoreDNS upstream Corefile contract"
if ! diff -u "${baseline_tmp}" "${committed_tmp}"; then
  fail "committed CoreDNS root block drifted from ${baseline_file}; review the upstream CoreDNS skeleton and update both files intentionally"
fi

echo "coredns upstream Corefile contract PASSED"
