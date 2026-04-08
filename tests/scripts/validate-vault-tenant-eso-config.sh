#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

echo "==> Validating Vault tenant ESO reconcile wiring (render-time)"

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

extract() {
  local rendered="$1"
  local expr="$2"
  printf '%s\n' "${rendered}" | yq -r "${expr}" | head -n 1
}

check_overlay() {
  local overlay="$1"
  echo "==> ${overlay}"
  local rendered
  rendered="$(kustomize build "${overlay}")"

  local sa
  sa="$(extract "${rendered}" 'select(.kind == "CronJob" and .metadata.name == "vault-tenant-eso-config") | .spec.jobTemplate.spec.template.spec.serviceAccountName')"
  [[ "${sa}" == "vault-bootstrap" ]] || fail "${overlay}: serviceAccountName=${sa} (expected vault-bootstrap)"

  local script_cm
  script_cm="$(extract "${rendered}" 'select(.kind == "CronJob" and .metadata.name == "vault-tenant-eso-config") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "script") | .configMap.name')"
  [[ "${script_cm}" == "vault-tenant-eso-config-script" ]] || fail "${overlay}: script ConfigMap=${script_cm} (expected vault-tenant-eso-config-script)"

  local registry_cm registry_optional
  registry_cm="$(extract "${rendered}" 'select(.kind == "CronJob" and .metadata.name == "vault-tenant-eso-config") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "tenant-registry") | .configMap.name')"
  registry_optional="$(extract "${rendered}" 'select(.kind == "CronJob" and .metadata.name == "vault-tenant-eso-config") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "tenant-registry") | .configMap.optional')"
  [[ "${registry_cm}" == "deploykube-tenant-registry" ]] || fail "${overlay}: tenant-registry ConfigMap=${registry_cm} (expected deploykube-tenant-registry)"
  [[ "${registry_optional}" == "true" ]] || fail "${overlay}: tenant-registry optional=${registry_optional} (expected true)"
}

check_overlay "platform/gitops/components/secrets/vault/overlays/mac-orbstack-single/config"
check_overlay "platform/gitops/components/secrets/vault/overlays/proxmox-talos/config"

echo "Vault tenant ESO reconcile wiring validation PASSED"
