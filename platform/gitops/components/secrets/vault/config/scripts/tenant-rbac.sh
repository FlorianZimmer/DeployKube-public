#!/bin/sh
set -euo pipefail

TENANT_REGISTRY_PATH="${TENANT_REGISTRY_PATH:-/tenant-registry/tenant-registry.yaml}"
ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_OIDC_MOUNT="${VAULT_OIDC_MOUNT:-oidc}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"

log() {
  printf '[vault-tenant-rbac] %s\n' "$*"
}

validate_tenant_id() {
  label="$1"
  value="$2"
  if [ -z "${value}" ]; then
    log "tenant registry: missing ${label}"
    return 1
  fi
  if [ "${#value}" -gt 63 ]; then
    log "tenant registry: ${label} too long (>63): ${value}"
    return 1
  fi
  if ! printf '%s' "${value}" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
    log "tenant registry: ${label} must be DNS-label-safe ([a-z0-9-], start/end alnum): ${value}"
    return 1
  fi
}

if [ ! -f "${ROOT_TOKEN_FILE}" ]; then
  log "vault root token missing; skipping"
  exit 0
fi

if [ ! -f "${TENANT_REGISTRY_PATH}" ]; then
  log "tenant registry not present at ${TENANT_REGISTRY_PATH}; skipping"
  exit 0
fi

kind="$(yq -r '.kind // ""' "${TENANT_REGISTRY_PATH}")"
api_version="$(yq -r '.apiVersion // ""' "${TENANT_REGISTRY_PATH}")"
if [ "${kind}" != "TenantRegistry" ]; then
  log "tenant registry has unexpected kind=${kind} (expected TenantRegistry)"
  exit 1
fi
if [ -z "${api_version}" ]; then
  log "tenant registry missing apiVersion"
  exit 1
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
  org_id="$3"
  project_id="${4:-}"

  vault_exec env POLICY_NAME="${policy_name}" POLICY_KIND="${policy_kind}" ORG_ID="${org_id}" PROJECT_ID="${project_id}" KV_MOUNT="${VAULT_KV_MOUNT}" sh -c '
set -eu
mkdir -p /home/vault/tmp
policy_file="/home/vault/tmp/${POLICY_NAME}.hcl"

case "${POLICY_KIND}" in
  org-rw)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/tenants/${ORG_ID}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/tenants/${ORG_ID}/*" {
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
    ;;
  org-ro)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/tenants/${ORG_ID}/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/metadata/tenants/${ORG_ID}/*" {
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
    ;;
  project-rw)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/tenants/${ORG_ID}/projects/${PROJECT_ID}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/tenants/${ORG_ID}/projects/${PROJECT_ID}/*" {
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
    ;;
  project-wo)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/tenants/${ORG_ID}/projects/${PROJECT_ID}/*" {
  capabilities = ["create", "update", "delete", "list"]
}

path "${KV_MOUNT}/metadata/tenants/${ORG_ID}/projects/${PROJECT_ID}/*" {
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
    ;;
  project-ro)
    cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/tenants/${ORG_ID}/projects/${PROJECT_ID}/*" {
  capabilities = ["read", "list"]
}

path "${KV_MOUNT}/metadata/tenants/${ORG_ID}/projects/${PROJECT_ID}/*" {
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
    ;;
  *)
    echo "unknown policy kind: ${POLICY_KIND}" >&2
    exit 1
    ;;
esac

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

log "Reconciling tenant policies and group aliases from ${TENANT_REGISTRY_PATH} into Vault (apiVersion=${api_version}, mount=${VAULT_OIDC_MOUNT}/)..."

yq -r '.tenants[].orgId // ""' "${TENANT_REGISTRY_PATH}" | while IFS= read -r org_id; do
  [ -z "${org_id}" ] && continue
  validate_tenant_id "orgId" "${org_id}"

  write_policy "tenant-${org_id}-rw" org-rw "${org_id}"
  write_policy "tenant-${org_id}-ro" org-ro "${org_id}"

  org_admin_group="dk-tenant-${org_id}-admins"
  org_viewer_group="dk-tenant-${org_id}-viewers"

  org_admin_id="$(ensure_identity_group_id "${org_admin_group}" "tenant-${org_id}-rw")"
  ensure_group_alias "${org_admin_group}" "${org_admin_id}"

  org_viewer_id="$(ensure_identity_group_id "${org_viewer_group}" "tenant-${org_id}-ro")"
  ensure_group_alias "${org_viewer_group}" "${org_viewer_id}"

  (yq -r ".tenants[] | select(.orgId == \"${org_id}\") | .projects[]? | .projectId // \"\"" "${TENANT_REGISTRY_PATH}" 2>/dev/null || true) | while IFS= read -r project_id; do
    [ -z "${project_id}" ] && continue
    validate_tenant_id "projectId" "${project_id}"

    write_policy "tenant-${org_id}-project-${project_id}-rw" project-rw "${org_id}" "${project_id}"
    write_policy "tenant-${org_id}-project-${project_id}-wo" project-wo "${org_id}" "${project_id}"
    write_policy "tenant-${org_id}-project-${project_id}-ro" project-ro "${org_id}" "${project_id}"

    admin_group="dk-tenant-${org_id}-project-${project_id}-admins"
    dev_group="dk-tenant-${org_id}-project-${project_id}-developers"
    viewer_group="dk-tenant-${org_id}-project-${project_id}-viewers"

    admin_id="$(ensure_identity_group_id "${admin_group}" "tenant-${org_id}-project-${project_id}-rw")"
    ensure_group_alias "${admin_group}" "${admin_id}"

    dev_id="$(ensure_identity_group_id "${dev_group}" "tenant-${org_id}-project-${project_id}-wo")"
    ensure_group_alias "${dev_group}" "${dev_id}"

    viewer_id="$(ensure_identity_group_id "${viewer_group}" "tenant-${org_id}-project-${project_id}-ro")"
    ensure_group_alias "${viewer_group}" "${viewer_id}"
  done
done

log "Tenant policies and group aliases reconcile completed."
