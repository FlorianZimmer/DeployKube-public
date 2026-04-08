#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

echo "==> Validating Argo CD AppProject/default lockdown (deny-by-default)"

default_manifest="platform/gitops/apps/base/appproject-default.yaml"
base_kustomization="platform/gitops/apps/base/kustomization.yaml"

if [[ ! -f "${default_manifest}" ]]; then
  echo "FAIL: missing ${default_manifest}" >&2
  failures=$((failures + 1))
else
  if ! rg -n "^[[:space:]]*name:[[:space:]]*default[[:space:]]*$" "${default_manifest}" >/dev/null 2>&1; then
    echo "FAIL: ${default_manifest} must define AppProject named 'default'" >&2
    failures=$((failures + 1))
  fi
  if rg -n "^[[:space:]]*name:[[:space:]]*in-cluster[[:space:]]*$" "${default_manifest}" >/dev/null 2>&1; then
    echo "FAIL: ${default_manifest} must not allow destination name 'in-cluster'" >&2
    failures=$((failures + 1))
  fi
  if rg -n "^[[:space:]]*namespace:[[:space:]]*\"\\*\"[[:space:]]*$" "${default_manifest}" >/dev/null 2>&1; then
    echo "FAIL: ${default_manifest} must not allow destination namespace '*'" >&2
    failures=$((failures + 1))
  fi
  if rg -n "^[[:space:]]*group:[[:space:]]*\"\\*\"[[:space:]]*$" "${default_manifest}" >/dev/null 2>&1 || rg -n "^[[:space:]]*kind:[[:space:]]*\"\\*\"[[:space:]]*$" "${default_manifest}" >/dev/null 2>&1; then
    echo "FAIL: ${default_manifest} must not allow wildcard resources" >&2
    failures=$((failures + 1))
  fi
  if ! rg -n "https://example\\.invalid/\\*" "${default_manifest}" >/dev/null 2>&1; then
    echo "FAIL: ${default_manifest} must deny source repos (expected https://example.invalid/*)" >&2
    failures=$((failures + 1))
  fi
  if ! rg -n "^[[:space:]]*-[[:space:]]*name:[[:space:]]*do-not-use[[:space:]]*$" "${default_manifest}" >/dev/null 2>&1; then
    echo "FAIL: ${default_manifest} must include deny-by-default destination name 'do-not-use'" >&2
    failures=$((failures + 1))
  fi
fi

if [[ ! -f "${base_kustomization}" ]]; then
  echo "FAIL: missing ${base_kustomization}" >&2
  failures=$((failures + 1))
else
  if ! rg -n "^[[:space:]]*-[[:space:]]*appproject-default\\.yaml[[:space:]]*$" "${base_kustomization}" >/dev/null 2>&1; then
    echo "FAIL: ${base_kustomization} must include ${default_manifest}" >&2
    failures=$((failures + 1))
  fi
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "Argo CD AppProject/default lockdown validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "Argo CD AppProject/default lockdown validation PASSED"
