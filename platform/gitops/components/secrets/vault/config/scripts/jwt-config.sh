#!/bin/sh
set -euo pipefail

CONFIGMAP_NAME="${CONFIGMAP_NAME:-vault-jwt-config-complete}"
ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault-system.svc:8200}"
VAULT_JWT_MOUNT="${VAULT_JWT_MOUNT:-jwt}"
VAULT_AUTOMATION_ROLE="${VAULT_AUTOMATION_ROLE:-vault-automation}"
VAULT_AUTOMATION_AUDIENCE="${VAULT_AUTOMATION_AUDIENCE:-vault-cli}"
VAULT_AUTOMATION_BOUND_AUDIENCE="${VAULT_AUTOMATION_BOUND_AUDIENCE:-${VAULT_AUTOMATION_AUDIENCE}}"
VAULT_AUTOMATION_GROUP="${VAULT_AUTOMATION_GROUP:-dk-bot-vault-writer}"
VAULT_AUTOMATION_SUBJECT="${VAULT_AUTOMATION_SUBJECT:-}"

KEYCLOAK_OIDC_REALM="${KEYCLOAK_OIDC_REALM:-deploykube-admin}"
KEYCLOAK_OIDC_HOST="${KEYCLOAK_OIDC_HOST:-__KEYCLOAK_OIDC_HOST__}"
KEYCLOAK_OIDC_SCHEME="${KEYCLOAK_OIDC_SCHEME:-https}"
KEYCLOAK_OIDC_ISSUER="${KEYCLOAK_OIDC_ISSUER:-${KEYCLOAK_OIDC_SCHEME}://${KEYCLOAK_OIDC_HOST}/realms/${KEYCLOAK_OIDC_REALM}}"
KEYCLOAK_OIDC_DISCOVERY_URL="${KEYCLOAK_OIDC_DISCOVERY_URL:-${KEYCLOAK_OIDC_SCHEME}://${KEYCLOAK_OIDC_HOST}/realms/${KEYCLOAK_OIDC_REALM}}"
KEYCLOAK_TOKEN_URL_INTERNAL="${KEYCLOAK_TOKEN_URL_INTERNAL:-http://keycloak.keycloak.svc:8080/realms/${KEYCLOAK_OIDC_REALM}/protocol/openid-connect/token}"
KEYCLOAK_VAULT_CLIENT_ID="${KEYCLOAK_VAULT_CLIENT_ID:-vault-cli}"
KEYCLOAK_VAULT_AUTOMATION_PATH="${KEYCLOAK_VAULT_AUTOMATION_PATH:-secret/keycloak/vault-automation-user}"
KEYCLOAK_VAULT_CLIENT_PATH="${KEYCLOAK_VAULT_CLIENT_PATH:-secret/keycloak/vault-client}"
VAULT_KEYCLOAK_CA_PATH="${VAULT_KEYCLOAK_CA_PATH:-secret/keycloak/oidc-ca}"
VAULT_KEYCLOAK_CA_FIELD="${VAULT_KEYCLOAK_CA_FIELD:-ca_crt}"

log() {
  printf '[vault-jwt-config] %s\n' "$*"
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

if [ ! -f "$ROOT_TOKEN_FILE" ]; then
  log "vault root token missing; skipping"
  exit 0
fi

VAULT_TOKEN="$(cat "$ROOT_TOKEN_FILE")"
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

if [ -z "${VAULT_AUTOMATION_SUBJECT:-}" ]; then
  automation_json="$(vault_exec vault kv get -format=json "${KEYCLOAK_VAULT_AUTOMATION_PATH}" 2>/dev/null || true)"
  automation_username="$(printf '%s' "${automation_json}" | jq -r '.data.data.username // empty' 2>/dev/null || true)"
  automation_password="$(printf '%s' "${automation_json}" | jq -r '.data.data.password // empty' 2>/dev/null || true)"
  vault_client_json="$(vault_exec vault kv get -format=json "${KEYCLOAK_VAULT_CLIENT_PATH}" 2>/dev/null || true)"
  vault_client_secret="$(printf '%s' "${vault_client_json}" | jq -r '.data.data.clientSecret // empty' 2>/dev/null || true)"
  if [ -n "${automation_username}" ] && [ -n "${automation_password}" ] && [ -n "${vault_client_secret}" ]; then
    token_json="$(curl -fsS --max-time 8 -X POST "${KEYCLOAK_TOKEN_URL_INTERNAL}" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=${KEYCLOAK_VAULT_CLIENT_ID}" \
      --data-urlencode "client_secret=${vault_client_secret}" \
      --data-urlencode "username=${automation_username}" \
      --data-urlencode "password=${automation_password}" \
      --data-urlencode "scope=openid profile email roles" 2>/dev/null || true)"
    access_token="$(printf '%s' "${token_json}" | jq -r '.access_token // empty' 2>/dev/null || true)"
    if [ -n "${access_token}" ]; then
      token_claims="$(jq -rRn --arg t "${access_token}" '($t | split(".")[1]) as $p | ($p | gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - (length % 4)) % 4)) | @base64d | fromjson)' 2>/dev/null || true)"
      if [ -n "${token_claims}" ] && [ "${token_claims}" != "null" ]; then
        VAULT_AUTOMATION_SUBJECT="$(printf '%s' "${token_claims}" | jq -r '.sub // empty' 2>/dev/null || true)"
        resolved_audience="$(printf '%s' "${token_claims}" | jq -r --arg client "${KEYCLOAK_VAULT_CLIENT_ID}" '
          (.aud // empty) as $aud
          | if ($aud | type) == "string" then $aud
            elif ($aud | type) == "array" then
              (if ($aud | index($client)) != null then $client
               elif ($aud | index("account")) != null then "account"
               else ($aud[0] // empty) end)
            else empty end' 2>/dev/null || true)"
        if [ -n "${resolved_audience:-}" ]; then
          VAULT_AUTOMATION_BOUND_AUDIENCE="${resolved_audience}"
        fi
      fi
    fi
  fi
fi

if [ -n "${VAULT_AUTOMATION_SUBJECT:-}" ]; then
  log "resolved automation subject for Vault JWT role: ${VAULT_AUTOMATION_SUBJECT}"
else
  log "unable to resolve automation subject; writing Vault JWT role without bound_subject"
fi
log "resolved automation audience for Vault JWT role: ${VAULT_AUTOMATION_BOUND_AUDIENCE}"

desired_sha="$(printf '%s' "${KEYCLOAK_OIDC_ISSUER}|${KEYCLOAK_OIDC_DISCOVERY_URL}|${VAULT_JWT_MOUNT}|${VAULT_AUTOMATION_ROLE}|${KEYCLOAK_VAULT_CLIENT_ID}|${VAULT_AUTOMATION_BOUND_AUDIENCE}|${VAULT_AUTOMATION_GROUP}|${VAULT_AUTOMATION_SUBJECT}|${ca_pem}" | sha256)"
existing_sha="$(kubectl -n vault-system get configmap "${CONFIGMAP_NAME}" -o jsonpath='{.data.configSha256}' 2>/dev/null || true)"
if [ -n "${existing_sha}" ] && [ "${existing_sha}" = "${desired_sha}" ]; then
  log "jwt config already applied (sha256=${existing_sha}); skipping"
  exit 0
fi

vault_exec vault auth enable -path="$VAULT_JWT_MOUNT" jwt >/dev/null 2>&1 || true

ca_b64="$(printf '%s' "${ca_pem}" | base64 | tr -d '\n')"
vault_exec env \
  KEYCLOAK_CA_B64="${ca_b64}" \
  KEYCLOAK_OIDC_ISSUER="${KEYCLOAK_OIDC_ISSUER}" \
  KEYCLOAK_OIDC_DISCOVERY_URL="${KEYCLOAK_OIDC_DISCOVERY_URL}" \
  VAULT_JWT_MOUNT="${VAULT_JWT_MOUNT}" \
  sh -c '
set -eu
tmp_ca="/home/vault/keycloak-jwt-oidc-ca.pem"
printf "%s" "${KEYCLOAK_CA_B64}" | base64 -d > "${tmp_ca}"
vault write "auth/${VAULT_JWT_MOUNT}/config" \
  bound_issuer="${KEYCLOAK_OIDC_ISSUER}" \
  oidc_discovery_url="${KEYCLOAK_OIDC_DISCOVERY_URL}" \
  oidc_discovery_ca_pem=@"${tmp_ca}" \
  jwt_supported_algs="RS256" >/dev/null
rm -f "${tmp_ca}" >/dev/null 2>&1 || true
'

vault_exec sh -c 'cat <<'"'"'EOF'"'"' >/home/vault/automation-write.hcl
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "sys/capabilities-self" {
  capabilities = ["update"]
}
EOF
vault policy write automation-write /home/vault/automation-write.hcl >/dev/null
rm -f /home/vault/automation-write.hcl'

role_payload_b64="$(
  jq -cn \
    --arg aud "${VAULT_AUTOMATION_BOUND_AUDIENCE}" \
    --arg group "${VAULT_AUTOMATION_GROUP}" \
    --arg azp "${KEYCLOAK_VAULT_CLIENT_ID}" \
    --arg subj "${VAULT_AUTOMATION_SUBJECT:-}" \
    '{
      role_type: "jwt",
      user_claim: "preferred_username",
      groups_claim: "groups",
      bound_audiences: ([$aud, $azp, "account"] | unique),
      bound_claims: {groups: $group, azp: $azp},
      token_policies: ["automation-write"],
      token_ttl: "15m",
      token_max_ttl: "1h"
    } + (if $subj != "" then {bound_subject: $subj} else {} end)' \
    | base64 | tr -d '\n'
)"

vault_exec env \
  ROLE_PAYLOAD_B64="${role_payload_b64}" \
  VAULT_JWT_MOUNT="${VAULT_JWT_MOUNT}" \
  VAULT_AUTOMATION_ROLE="${VAULT_AUTOMATION_ROLE}" \
  sh -c '
set -eu
tmp_role="/home/vault/jwt-role.json"
printf "%s" "${ROLE_PAYLOAD_B64}" | base64 -d > "${tmp_role}"
role_path="auth/${VAULT_JWT_MOUNT}/role/${VAULT_AUTOMATION_ROLE}"
vault delete "${role_path}" >/dev/null 2>&1 || true
vault write "${role_path}" @"${tmp_role}" >/dev/null
rm -f "${tmp_role}" >/dev/null 2>&1 || true
'

kubectl -n vault-system create configmap "${CONFIGMAP_NAME}" \
  --from-literal=job=vault-jwt-config \
  --from-literal=configSha256="${desired_sha}" \
  --from-literal=completedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --dry-run=client -o yaml | kubectl apply -f -

log "JWT auth config completed"
