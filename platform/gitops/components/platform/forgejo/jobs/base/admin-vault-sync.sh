#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="forgejo-admin-vault-sync"
POD_NS="${POD_NAMESPACE:-forgejo}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault-system.svc:8200}"
VAULT_ROLE="${VAULT_ROLE:-forgejo-admin-sync}"

log() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "missing dependency: $1"
    exit 1
  fi
}

require curl
require jq
require kubectl
require base64

ISTIO_HELPER="/helpers/istio-native-exit.sh"
if [[ -f "${ISTIO_HELPER}" ]]; then
  . "${ISTIO_HELPER}"
  trap deploykube_istio_quit_sidecar EXIT INT TERM
fi

secret_field() {
  local field="$1"
  kubectl -n "${POD_NS}" get secret forgejo-admin -o "jsonpath={.data.${field}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

admin_user=$(secret_field username)
admin_pass=$(secret_field password)

if [[ -z "${admin_user}" || -z "${admin_pass}" ]]; then
  log "forgejo-admin secret missing or incomplete; skipping Vault sync"
  exit 0
fi

jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
payload=$(jq -n --arg role "${VAULT_ROLE}" --arg jwt "${jwt}" '{role:$role,jwt:$jwt}')
resp=$(curl -sSf -H "Content-Type: application/json" -X POST --data "${payload}" \
  "${VAULT_ADDR}/v1/auth/kubernetes/login")
vault_token=$(echo "${resp}" | jq -r '.auth.client_token // empty')
if [[ -z "${vault_token}" ]]; then
  log "failed to mint Vault token via kubernetes auth"
  exit 1
fi

payload=$(jq -n --arg u "${admin_user}" --arg p "${admin_pass}" '{data:{username:$u,password:$p}}')
curl -sSf -H "X-Vault-Token: ${vault_token}" -H "Content-Type: application/json" -X POST \
  --data "${payload}" \
  "${VAULT_ADDR}/v1/secret/data/forgejo/admin" >/dev/null

log "synced Forgejo admin credentials into Vault"
