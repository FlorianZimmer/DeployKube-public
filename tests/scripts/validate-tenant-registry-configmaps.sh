#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

registry_dir="platform/gitops/apps/tenants/base"
registry_file="${registry_dir}/tenant-registry.yaml"

echo "==> Validating tenant registry ConfigMap rendering"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency kustomize
check_dependency yq
check_dependency python3

if [[ ! -f "${registry_file}" ]]; then
  echo "error: missing tenant registry file: ${registry_file}" >&2
  exit 1
fi

rendered="$(kustomize build "${registry_dir}")"

extract_configmap_data() {
  local namespace="$1"
  printf '%s\n' "${rendered}" \
    | yq -r "select(.kind == \"ConfigMap\" and .metadata.name == \"deploykube-tenant-registry\" and .metadata.namespace == \"${namespace}\") | .data[\"tenant-registry.yaml\"]"
}

compare_content() {
  local namespace="$1"

  python3 -c '
from __future__ import annotations

import difflib
import pathlib
import sys

registry_file = pathlib.Path(sys.argv[1])
namespace = sys.argv[2]

expected = registry_file.read_text().rstrip("\n")
actual = sys.stdin.read().rstrip("\n")

if actual != expected:
    print(f"FAIL: tenant registry ConfigMap content mismatch for namespace {namespace}", file=sys.stderr)
    diff = difflib.unified_diff(
        expected.splitlines(),
        actual.splitlines(),
        fromfile=str(registry_file),
        tofile=f"rendered ConfigMap/{namespace}",
        lineterm="",
    )
    for line in diff:
        print(line, file=sys.stderr)
    sys.exit(1)

print(f"PASS: {namespace}")
' "${registry_file}" "${namespace}"
}

for ns in keycloak vault-system garage backup-system rbac-system; do
  actual="$(extract_configmap_data "${ns}")"
  if [[ -z "${actual}" ]]; then
    echo "FAIL: missing rendered ConfigMap deploykube-tenant-registry in namespace ${ns}" >&2
    exit 1
  fi
  compare_content "${ns}" <<<"${actual}"
done

echo "tenant registry ConfigMap rendering validation PASSED"
