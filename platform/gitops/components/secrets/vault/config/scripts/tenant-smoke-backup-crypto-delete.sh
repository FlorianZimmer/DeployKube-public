#!/bin/sh
set -euo pipefail

ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_KEY="${VAULT_KEY:-tenants/smoke/projects/demo/sys/backup}"

log() {
  printf '[vault-tenant-smoke-backup-crypto-delete] %s\n' "$*"
}

if [ ! -f "${ROOT_TOKEN_FILE}" ]; then
  log "vault root token missing; skipping"
  exit 0
fi

vault_pod="$(kubectl -n vault-system get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "${vault_pod}" ]; then
  log "vault pod not found; skipping"
  exit 0
fi

VAULT_TOKEN="$(cat "${ROOT_TOKEN_FILE}")"
BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN}}"
export VAULT_TOKEN BAO_TOKEN

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

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
new_pw="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"

log "setting a new RESTIC_PASSWORD in ${VAULT_KV_MOUNT}/${VAULT_KEY} (crypto-delete drill)"

vault_exec env NEW_PW="${new_pw}" NOW="${now}" KV_MOUNT="${VAULT_KV_MOUNT}" KEY="${VAULT_KEY}" sh -c '
set -eu
vault kv patch "${KV_MOUNT}/${KEY}" \
  RESTIC_PASSWORD="${NEW_PW}" \
  CRYPTO_DELETED_AT="${NOW}" \
  CRYPTO_DELETED_BY="vault-tenant-smoke-backup-crypto-delete" >/dev/null
'

log "crypto-delete completed"

