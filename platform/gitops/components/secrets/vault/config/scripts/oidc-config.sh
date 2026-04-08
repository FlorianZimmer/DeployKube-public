#!/bin/sh
set -euo pipefail

CONFIGMAP_NAME="${CONFIGMAP_NAME:-vault-oidc-config-complete}"
ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault-system.svc:8200}"

VAULT_OIDC_MOUNT="${VAULT_OIDC_MOUNT:-oidc}"
VAULT_OIDC_DEFAULT_ROLE="${VAULT_OIDC_DEFAULT_ROLE:-default}"
VAULT_OIDC_USER_CLAIM="${VAULT_OIDC_USER_CLAIM:-preferred_username}"
VAULT_OIDC_GROUPS_CLAIM="${VAULT_OIDC_GROUPS_CLAIM:-groups}"

VAULT_OIDC_HOST="${VAULT_OIDC_HOST:-vault.invalid}"
VAULT_OIDC_ALLOWED_REDIRECT_URIS="${VAULT_OIDC_ALLOWED_REDIRECT_URIS:-https://${VAULT_OIDC_HOST}/ui/vault/auth/jwt/${VAULT_OIDC_MOUNT}/callback,https://${VAULT_OIDC_HOST}/ui/vault/auth/oidc/${VAULT_OIDC_MOUNT}/callback,http://localhost:8400/oidc/callback,http://127.0.0.1:8400/oidc/callback}"

KEYCLOAK_OIDC_REALM="${KEYCLOAK_OIDC_REALM:-deploykube-admin}"
KEYCLOAK_OIDC_HOST="${KEYCLOAK_OIDC_HOST:-__KEYCLOAK_OIDC_HOST__}"
KEYCLOAK_OIDC_SCHEME="${KEYCLOAK_OIDC_SCHEME:-https}"
KEYCLOAK_OIDC_DISCOVERY_URL="${KEYCLOAK_OIDC_DISCOVERY_URL:-${KEYCLOAK_OIDC_SCHEME}://${KEYCLOAK_OIDC_HOST}/realms/${KEYCLOAK_OIDC_REALM}}"

VAULT_KEYCLOAK_CLIENT_PATH="${VAULT_KEYCLOAK_CLIENT_PATH:-secret/keycloak/vault-client}"
VAULT_KEYCLOAK_CA_PATH="${VAULT_KEYCLOAK_CA_PATH:-secret/keycloak/oidc-ca}"
VAULT_KEYCLOAK_CA_FIELD="${VAULT_KEYCLOAK_CA_FIELD:-ca_crt}"

log() {
  printf '[vault-oidc-config] %s\n' "$*"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  log "sha256 not available (need sha256sum or shasum)"
  return 1
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

client_json="$(vault_exec vault kv get -format=json "${VAULT_KEYCLOAK_CLIENT_PATH}" 2>/dev/null || true)"
client_id="$(printf '%s' "${client_json}" | jq -r '.data.data.clientId // empty' 2>/dev/null || true)"
client_secret="$(printf '%s' "${client_json}" | jq -r '.data.data.clientSecret // empty' 2>/dev/null || true)"
if [ -z "${client_id}" ] || [ -z "${client_secret}" ]; then
  log "missing Keycloak client in Vault (${VAULT_KEYCLOAK_CLIENT_PATH}); skipping"
  exit 0
fi

ca_json="$(vault_exec vault kv get -format=json "${VAULT_KEYCLOAK_CA_PATH}" 2>/dev/null || true)"
ca_pem="$(printf '%s' "${ca_json}" | jq -r --arg k "${VAULT_KEYCLOAK_CA_FIELD}" '.data.data[$k] // empty' 2>/dev/null || true)"
if [ -z "${ca_pem}" ]; then
  log "missing Keycloak OIDC CA in Vault (${VAULT_KEYCLOAK_CA_PATH}:${VAULT_KEYCLOAK_CA_FIELD}); skipping"
  exit 0
fi

tmp_ca="$(mktemp)"
trap 'rm -f "${tmp_ca}"' EXIT
printf '%s' "${ca_pem}" > "${tmp_ca}"

if ! curl -fsS --max-time 5 --cacert "${tmp_ca}" "${KEYCLOAK_OIDC_DISCOVERY_URL}/.well-known/openid-configuration" 2>/dev/null | grep -q '"issuer"'; then
  log "Keycloak OIDC discovery not reachable (${KEYCLOAK_OIDC_DISCOVERY_URL}); skipping"
  exit 0
fi

desired_sha="$(printf '%s' "${KEYCLOAK_OIDC_DISCOVERY_URL}|${client_id}|${client_secret}|${VAULT_OIDC_MOUNT}|${VAULT_OIDC_DEFAULT_ROLE}|${VAULT_OIDC_USER_CLAIM}|${VAULT_OIDC_GROUPS_CLAIM}|${VAULT_OIDC_ALLOWED_REDIRECT_URIS}|${ca_pem}" | sha256)"
existing_sha="$(kubectl -n vault-system get configmap "${CONFIGMAP_NAME}" -o jsonpath='{.data.configSha256}' 2>/dev/null || true)"
if [ -n "${existing_sha}" ] && [ "${existing_sha}" = "${desired_sha}" ]; then
  log "oidc config already applied (sha256=${existing_sha}); skipping"
  exit 0
fi

ca_b64="$(printf '%s' "${ca_pem}" | base64 | tr -d '\n')"

vault_exec env \
  CA_B64="${ca_b64}" \
  OIDC_CLIENT_ID="${client_id}" \
  OIDC_CLIENT_SECRET="${client_secret}" \
  KEYCLOAK_OIDC_DISCOVERY_URL="${KEYCLOAK_OIDC_DISCOVERY_URL}" \
  VAULT_OIDC_MOUNT="${VAULT_OIDC_MOUNT}" \
  VAULT_OIDC_DEFAULT_ROLE="${VAULT_OIDC_DEFAULT_ROLE}" \
  VAULT_OIDC_USER_CLAIM="${VAULT_OIDC_USER_CLAIM}" \
  VAULT_OIDC_GROUPS_CLAIM="${VAULT_OIDC_GROUPS_CLAIM}" \
  VAULT_OIDC_ALLOWED_REDIRECT_URIS="${VAULT_OIDC_ALLOWED_REDIRECT_URIS}" \
  sh -c '
set -eu
tmp_ca="/home/vault/vault-oidc-discovery-ca.pem"
rm -f "${tmp_ca}" >/dev/null 2>&1 || true
printf "%s" "${CA_B64}" | base64 -d > "${tmp_ca}"

vault auth enable -path="${VAULT_OIDC_MOUNT}" jwt >/dev/null 2>&1 || true

vault write "auth/${VAULT_OIDC_MOUNT}/config" \
  oidc_discovery_url="${KEYCLOAK_OIDC_DISCOVERY_URL}" \
  oidc_discovery_ca_pem=@"${tmp_ca}" \
  oidc_client_id="${OIDC_CLIENT_ID}" \
  oidc_client_secret="${OIDC_CLIENT_SECRET}" \
  default_role="${VAULT_OIDC_DEFAULT_ROLE}" >/dev/null

vault write "auth/${VAULT_OIDC_MOUNT}/role/${VAULT_OIDC_DEFAULT_ROLE}" \
  role_type="oidc" \
  user_claim="${VAULT_OIDC_USER_CLAIM}" \
  groups_claim="${VAULT_OIDC_GROUPS_CLAIM}" \
  allowed_redirect_uris="${VAULT_OIDC_ALLOWED_REDIRECT_URIS}" >/dev/null

rm -f "${tmp_ca}" >/dev/null 2>&1 || true
'

kubectl -n vault-system create configmap "${CONFIGMAP_NAME}" \
  --from-literal=job=vault-oidc-config \
  --from-literal=configSha256="${desired_sha}" \
  --from-literal=completedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --dry-run=client -o yaml | kubectl apply -f -

log "OIDC auth config completed (mount=${VAULT_OIDC_MOUNT} role=${VAULT_OIDC_DEFAULT_ROLE})"
