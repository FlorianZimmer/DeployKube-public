#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

echo "==> Validating scoped tenant ESO store manifests (render-time)"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency kustomize
check_dependency yq

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

rendered="$(kustomize build platform/gitops/components/secrets/external-secrets/config)"

store_role="$(
  printf '%s\n' "${rendered}" | yq -r '
    select(.kind == "ClusterSecretStore" and .metadata.name == "vault-tenant-smoke-project-demo")
    | .spec.provider.vault.auth.kubernetes.role
  ' | head -n 1
)"
if [[ "${store_role}" != "k8s-tenant-smoke-project-demo-eso" ]]; then
  fail "ClusterSecretStore/vault-tenant-smoke-project-demo role=${store_role} (expected k8s-tenant-smoke-project-demo-eso)"
fi

es_store="$(
  printf '%s\n' "${rendered}" | yq -r '
    select(.kind == "ExternalSecret" and .metadata.name == "eso-tenant-smoke")
    | .spec.secretStoreRef.name
  ' | head -n 1
)"
if [[ "${es_store}" != "vault-tenant-smoke-project-demo" ]]; then
  fail "ExternalSecret/eso-tenant-smoke storeRef=${es_store} (expected vault-tenant-smoke-project-demo)"
fi

es_key="$(
  printf '%s\n' "${rendered}" | yq -r '
    select(.kind == "ExternalSecret" and .metadata.name == "eso-tenant-smoke")
    | .spec.data[0].remoteRef.key
  ' | head -n 1
)"
if [[ "${es_key}" != "tenants/smoke/projects/demo/bootstrap" ]]; then
  fail "ExternalSecret/eso-tenant-smoke key=${es_key} (expected tenants/smoke/projects/demo/bootstrap)"
fi

job_script="$(
  printf '%s\n' "${rendered}" | yq -r '
    select(.kind == "Job" and .metadata.name == "eso-smoke")
    | .spec.template.spec.containers[]
    | select(.name == "smoke")
    | .command[2]
  '
)"
grep -q 'vault-tenant-smoke-project-demo' <<<"${job_script}" || fail "eso-smoke job does not validate vault-tenant-smoke-project-demo"
grep -q 'eso-tenant-smoke' <<<"${job_script}" || fail "eso-smoke job does not validate eso-tenant-smoke"

echo "Scoped tenant ESO store manifests validation PASSED"
