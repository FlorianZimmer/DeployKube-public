#!/bin/sh
set -euo pipefail

ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_OIDC_MOUNT="${VAULT_OIDC_MOUNT:-oidc}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"

log() {
  printf '[vault-platform-rbac] %s\n' "$*"
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

auth_json="$(vault_exec vault auth list -format=json 2>/dev/null || true)"
oidc_accessor="$(printf '%s' "${auth_json}" | jq -r --arg p "${VAULT_OIDC_MOUNT}/" '.[$p].accessor // empty' 2>/dev/null || true)"
if [ -z "${oidc_accessor}" ]; then
  log "Vault auth mount ${VAULT_OIDC_MOUNT}/ not found; skipping"
  exit 0
fi

write_policy() {
  policy_name="$1"
  policy_kind="$2"

  vault_exec env POLICY_NAME="${policy_name}" POLICY_KIND="${policy_kind}" KV_MOUNT="${VAULT_KV_MOUNT}" sh -c '
set -eu
mkdir -p /home/vault/tmp
policy_file="/home/vault/tmp/${POLICY_NAME}.hcl"

case "${POLICY_KIND}" in
  platform-admin-rw)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
    ;;
  platform-operator-rw)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/platform/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/platform/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/data/tenants/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/metadata/tenants/*" {
  capabilities = ["read", "list"]
}
EOF
    ;;
  platform-security-ops-ro)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
    ;;
  platform-auditor-ro)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
    ;;
  platform-iam-admin-rw)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/keycloak/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/keycloak/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/data/iam/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/iam/*" {
  capabilities = ["read", "list"]
}
EOF
    ;;
  *)
    echo "unknown policy kind: ${POLICY_KIND}" >&2
    exit 1
    ;;
esac

cat >>"${policy_file}" <<'EOF'
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

vault policy write "${POLICY_NAME}" "${policy_file}" >/dev/null
rm -f "${policy_file}" >/dev/null 2>&1 || true
'
}

ensure_identity_group_id() {
  group_name="$1"
  policy_name="$2"

  vault_exec vault write identity/group name="${group_name}" type="external" policies="${policy_name}" >/dev/null
  group_json="$(vault_exec vault read -format=json "identity/group/name/${group_name}" 2>/dev/null || true)"
  group_id="$(printf '%s' "${group_json}" | jq -r '.data.id // empty' 2>/dev/null || true)"
  if [ -z "${group_id}" ]; then
    log "failed to resolve identity group id for ${group_name}"
    return 1
  fi
  printf '%s' "${group_id}"
}

find_group_alias_id() {
  alias_name="$1"
  ids_json="$(vault_exec vault list -format=json identity/group-alias/id 2>/dev/null || true)"
  if [ -z "${ids_json}" ] || [ "${ids_json}" = "null" ]; then
    return 0
  fi

  for id in $(printf '%s' "${ids_json}" | jq -r '.[]' 2>/dev/null); do
    alias_json="$(vault_exec vault read -format=json "identity/group-alias/id/${id}" 2>/dev/null || true)"
    [ -z "${alias_json}" ] && continue
    name="$(printf '%s' "${alias_json}" | jq -r '.data.name // empty' 2>/dev/null || true)"
    mount_accessor="$(printf '%s' "${alias_json}" | jq -r '.data.mount_accessor // empty' 2>/dev/null || true)"
    if [ "${name}" = "${alias_name}" ] && [ "${mount_accessor}" = "${oidc_accessor}" ]; then
      printf '%s' "${id}"
      return 0
    fi
  done
}

ensure_group_alias() {
  alias_name="$1"
  canonical_id="$2"

  if vault_exec vault write identity/group-alias name="${alias_name}" mount_accessor="${oidc_accessor}" canonical_id="${canonical_id}" >/dev/null 2>&1; then
    return 0
  fi

  alias_id="$(find_group_alias_id "${alias_name}")"
  if [ -z "${alias_id}" ]; then
    log "failed to ensure group alias ${alias_name} (could not create or find existing)"
    return 1
  fi

  vault_exec vault write "identity/group-alias/id/${alias_id}" \
    name="${alias_name}" mount_accessor="${oidc_accessor}" canonical_id="${canonical_id}" >/dev/null
}

log "Reconciling platform Vault OIDC policies and group aliases (mount=${VAULT_OIDC_MOUNT}/)..."

write_policy "platform-admin-rw" "platform-admin-rw"
write_policy "platform-operator-rw" "platform-operator-rw"
write_policy "platform-security-ops-ro" "platform-security-ops-ro"
write_policy "platform-auditor-ro" "platform-auditor-ro"
write_policy "platform-iam-admin-rw" "platform-iam-admin-rw"

admin_id="$(ensure_identity_group_id "dk-platform-admins" "platform-admin-rw")"
ensure_group_alias "dk-platform-admins" "${admin_id}"

operator_id="$(ensure_identity_group_id "dk-platform-operators" "platform-operator-rw")"
ensure_group_alias "dk-platform-operators" "${operator_id}"

security_id="$(ensure_identity_group_id "dk-security-ops" "platform-security-ops-ro")"
ensure_group_alias "dk-security-ops" "${security_id}"

auditor_id="$(ensure_identity_group_id "dk-auditors" "platform-auditor-ro")"
ensure_group_alias "dk-auditors" "${auditor_id}"

iam_admin_id="$(ensure_identity_group_id "dk-iam-admins" "platform-iam-admin-rw")"
ensure_group_alias "dk-iam-admins" "${iam_admin_id}"

log "Platform policies and group aliases reconcile completed."
