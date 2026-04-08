#!/bin/sh
set -euo pipefail

ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_K8S_AUTH_MOUNT="${VAULT_K8S_AUTH_MOUNT:-kubernetes}"

K8S_ROLE_NAME="${K8S_ROLE_NAME:-k8s-garage-tenant-s3-provisioner}"
POLICY_NAME="${POLICY_NAME:-garage-tenant-s3-provisioner}"

ROLE_TTL="${ROLE_TTL:-1h}"
ROLE_MAX_TTL="${ROLE_MAX_TTL:-4h}"

log() {
  printf '[vault-tenant-s3-provisioner-role] %s\n' "$*"
}

if [ ! -f "${ROOT_TOKEN_FILE}" ]; then
  log "vault root token missing; skipping"
  exit 0
fi

VAULT_TOKEN="$(cat "${ROOT_TOKEN_FILE}")"
BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN}}"
export VAULT_TOKEN BAO_TOKEN

vault_pod="$(kubectl -n vault-system get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "${vault_pod}" ]; then
  log "vault pod not found; skipping"
  exit 0
fi

vault_exec() {
  kubectl -n vault-system exec "${vault_pod}" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="${BAO_TOKEN}" \
    VAULT_TOKEN="${VAULT_TOKEN}" \
    "$@"
}

if ! vault_exec vault status >/dev/null 2>&1; then
  log "vault not ready; skipping"
  exit 0
fi

log "Reconciling Vault policy/role for Garage tenant S3 provisioner (policy=${POLICY_NAME}, role=${K8S_ROLE_NAME}, mount=${VAULT_K8S_AUTH_MOUNT}/)..."

vault_exec env POLICY_NAME="${POLICY_NAME}" ROLE_NAME="${K8S_ROLE_NAME}" K8S_AUTH_MOUNT="${VAULT_K8S_AUTH_MOUNT}" ROLE_TTL="${ROLE_TTL}" ROLE_MAX_TTL="${ROLE_MAX_TTL}" sh -c '
set -eu
mkdir -p /home/vault/tmp
policy_file="/home/vault/tmp/tenant-s3-provisioner.hcl"

cat >"${policy_file}" <<'"'"'EOF'"'"'
# Use segment wildcards (+) to avoid overly broad matching.
path "secret/data/tenants/+/s3/+" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/tenants/+/s3/+" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF

vault policy write "${POLICY_NAME}" "${policy_file}" >/dev/null
rm -f "${policy_file}" >/dev/null 2>&1 || true

vault write "auth/${K8S_AUTH_MOUNT}/role/${ROLE_NAME}" \
  bound_service_account_names="garage-tenant-s3-provisioner" \
  bound_service_account_namespaces="garage" \
  token_policies="${POLICY_NAME}" \
  token_ttl="${ROLE_TTL}" \
  token_max_ttl="${ROLE_MAX_TTL}" >/dev/null
'

log "Tenant S3 provisioner Vault policy/role reconcile completed."
