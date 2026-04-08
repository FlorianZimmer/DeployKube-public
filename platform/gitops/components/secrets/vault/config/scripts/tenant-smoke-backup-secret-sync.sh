#!/bin/sh
set -euo pipefail

TARGET_NAMESPACE="${TARGET_NAMESPACE:-tenant-smoke-demo}"
TARGET_SECRET_NAME="${TARGET_SECRET_NAME:-tenant-backup-s3}"

ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_KEY="${VAULT_KEY:-tenants/smoke/projects/demo/sys/backup}"

log() {
  printf '[vault-tenant-smoke-backup-secret-sync] %s\n' "$*"
}

if [ ! -f "${ROOT_TOKEN_FILE}" ]; then
  log "vault root token missing; skipping"
  exit 0
fi

if ! kubectl get namespace "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  log "target namespace ${TARGET_NAMESPACE} not present; skipping"
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

get_field() {
  vault_exec vault kv get -field="$1" "${VAULT_KV_MOUNT}/${VAULT_KEY}" 2>/dev/null || true
}

s3_endpoint="$(get_field S3_ENDPOINT)"
s3_region="$(get_field S3_REGION)"
s3_bucket="$(get_field S3_BUCKET)"
s3_access="$(get_field S3_ACCESS_KEY)"
s3_secret="$(get_field S3_SECRET_KEY)"
restic_repo="$(get_field RESTIC_REPOSITORY)"
restic_password="$(get_field RESTIC_PASSWORD)"

if [ -z "${s3_endpoint}" ] || [ -z "${s3_region}" ] || [ -z "${s3_bucket}" ] || [ -z "${s3_access}" ] || [ -z "${s3_secret}" ] || [ -z "${restic_repo}" ] || [ -z "${restic_password}" ]; then
  log "required Vault fields missing at ${VAULT_KV_MOUNT}/${VAULT_KEY}; skipping"
  exit 0
fi

log "syncing Vault ${VAULT_KV_MOUNT}/${VAULT_KEY} -> Secret/${TARGET_SECRET_NAME} in ${TARGET_NAMESPACE}"

kubectl -n "${TARGET_NAMESPACE}" create secret generic "${TARGET_SECRET_NAME}" \
  --from-literal=S3_ENDPOINT="${s3_endpoint}" \
  --from-literal=S3_REGION="${s3_region}" \
  --from-literal=S3_BUCKET="${s3_bucket}" \
  --from-literal=S3_ACCESS_KEY="${s3_access}" \
  --from-literal=S3_SECRET_KEY="${s3_secret}" \
  --from-literal=RESTIC_REPOSITORY="${restic_repo}" \
  --from-literal=RESTIC_PASSWORD="${restic_password}" \
  --dry-run=client -o yaml \
  | kubectl -n "${TARGET_NAMESPACE}" apply -f - >/dev/null

log "sync completed"

