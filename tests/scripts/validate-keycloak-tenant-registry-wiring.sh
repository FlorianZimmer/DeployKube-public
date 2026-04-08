#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

job="platform/gitops/components/platform/keycloak/bootstrap-job/base/job.yaml"
script="platform/gitops/components/platform/keycloak/bootstrap-job/base/scripts/bootstrap.sh"

echo "==> Validating Keycloak tenant registry wiring"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency yq
check_dependency rg

if [[ ! -f "${job}" ]]; then
  echo "error: missing file: ${job}" >&2
  exit 1
fi

if [[ ! -f "${script}" ]]; then
  echo "error: missing file: ${script}" >&2
  exit 1
fi

# Job wiring: volume + mount + env var.
yq -e '.spec.template.spec.volumes[] | select(.configMap.name == "deploykube-tenant-registry")' "${job}" >/dev/null
yq -e '.spec.template.spec.containers[].volumeMounts[] | select(.mountPath == "/tenant-registry/tenant-registry.yaml" and .subPath == "tenant-registry.yaml")' "${job}" >/dev/null
yq -e '.spec.template.spec.containers[].env[] | select(.name == "TENANT_REGISTRY_PATH" and .value == "/tenant-registry/tenant-registry.yaml")' "${job}" >/dev/null

# Bootstrap logic: env var present + reconcile called.
rg -n '^TENANT_REGISTRY_PATH=' "${script}" >/dev/null
rg -n '^ensure_tenant_groups\(\)' "${script}" >/dev/null
rg -n '^[[:space:]]*ensure_tenant_groups[[:space:]]*$' "${script}" >/dev/null

echo "Keycloak tenant registry wiring validation PASSED"
