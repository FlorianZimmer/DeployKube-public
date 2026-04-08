#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

echo "==> Validating Vault OIDC auth config wiring (render-time)"

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

extract_env() {
  local rendered="$1"
  local env_name="$2"
  printf '%s\n' "${rendered}" \
    | yq -r "select(.kind == \"CronJob\" and .metadata.name == \"vault-oidc-config\") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name == \"oidc-config\") | .env[] | select(.name == \"${env_name}\") | .value" \
    | head -n 1
}

check_overlay() {
  local overlay="$1"
  local expected_keycloak="$2"
  local expected_vault="$3"

  echo "==> ${overlay}"
  local rendered
  rendered="$(kustomize build "${overlay}")"

  local keycloak_host vault_host
  keycloak_host="$(extract_env "${rendered}" "KEYCLOAK_OIDC_HOST")"
  vault_host="$(extract_env "${rendered}" "VAULT_OIDC_HOST")"

  if [[ -z "${keycloak_host}" || "${keycloak_host}" == "__KEYCLOAK_OIDC_HOST__" ]]; then
    fail "${overlay}: KEYCLOAK_OIDC_HOST is unset/placeholder"
  fi
  if [[ -z "${vault_host}" || "${vault_host}" == "vault.invalid" ]]; then
    fail "${overlay}: VAULT_OIDC_HOST is unset/placeholder"
  fi

  if [[ "${keycloak_host}" != "${expected_keycloak}" ]]; then
    fail "${overlay}: KEYCLOAK_OIDC_HOST=${keycloak_host} (expected ${expected_keycloak})"
  fi
  if [[ "${vault_host}" != "${expected_vault}" ]]; then
    fail "${overlay}: VAULT_OIDC_HOST=${vault_host} (expected ${expected_vault})"
  fi
}

check_overlay "platform/gitops/components/secrets/vault/overlays/mac-orbstack-single/config" "keycloak.dev-single.internal.example.com" "vault.dev-single.internal.example.com"
check_overlay "platform/gitops/components/secrets/vault/overlays/proxmox-talos/config" "keycloak.prod.internal.example.com" "vault.prod.internal.example.com"

echo "Vault OIDC auth config wiring validation PASSED"
