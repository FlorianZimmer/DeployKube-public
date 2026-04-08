#!/bin/sh
set -euo pipefail

TENANT_REGISTRY_PATH="${TENANT_REGISTRY_PATH:-/tenant-registry/tenant-registry.yaml}"
ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_K8S_AUTH_MOUNT="${VAULT_K8S_AUTH_MOUNT:-kubernetes}"

ESO_SERVICEACCOUNT_NAME="${ESO_SERVICEACCOUNT_NAME:-external-secrets}"
ESO_SERVICEACCOUNT_NAMESPACE="${ESO_SERVICEACCOUNT_NAMESPACE:-external-secrets}"

ESO_TOKEN_TTL="${ESO_TOKEN_TTL:-1h}"
ESO_TOKEN_MAX_TTL="${ESO_TOKEN_MAX_TTL:-4h}"

TENANT_SMOKE_MESSAGE="${TENANT_SMOKE_MESSAGE:-Tenant smoke secret is scoped to project}"

log() {
  printf '[vault-tenant-eso] %s\n' "$*"
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

write_policy() {
  policy_name="$1"
  org_id="$2"
  project_id="$3"

  vault_exec env POLICY_NAME="${policy_name}" ORG_ID="${org_id}" PROJECT_ID="${project_id}" KV_MOUNT="${VAULT_KV_MOUNT}" sh -c '
set -eu
mkdir -p /home/vault/tmp
policy_file="/home/vault/tmp/${POLICY_NAME}.hcl"
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
vault policy write "${POLICY_NAME}" "${policy_file}" >/dev/null
rm -f "${policy_file}" >/dev/null 2>&1 || true
'
}

ensure_role() {
  role_name="$1"
  policy_name="$2"

  vault_exec vault write "auth/${VAULT_K8S_AUTH_MOUNT}/role/${role_name}" \
    bound_service_account_names="${ESO_SERVICEACCOUNT_NAME}" \
    bound_service_account_namespaces="${ESO_SERVICEACCOUNT_NAMESPACE}" \
    token_policies="${policy_name}" \
    token_ttl="${ESO_TOKEN_TTL}" \
    token_max_ttl="${ESO_TOKEN_MAX_TTL}" >/dev/null
}

log "Reconciling per-project ESO policies/roles from ${TENANT_REGISTRY_PATH} into Vault (apiVersion=${api_version}, mount=${VAULT_K8S_AUTH_MOUNT}/)..."

yq -r '.tenants[].orgId // ""' "${TENANT_REGISTRY_PATH}" | while IFS= read -r org_id; do
  [ -z "${org_id}" ] && continue
  validate_tenant_id "orgId" "${org_id}"

  (yq -r ".tenants[] | select(.orgId == \"${org_id}\") | .projects[]? | .projectId // \"\"" "${TENANT_REGISTRY_PATH}" 2>/dev/null || true) | while IFS= read -r project_id; do
    [ -z "${project_id}" ] && continue
    validate_tenant_id "projectId" "${project_id}"

    policy_name="tenant-${org_id}-project-${project_id}-eso-ro"
    role_name="k8s-tenant-${org_id}-project-${project_id}-eso"

    write_policy "${policy_name}" "${org_id}" "${project_id}"
    ensure_role "${role_name}" "${policy_name}"

    if [ "${org_id}" = "smoke" ] && [ "${project_id}" = "demo" ]; then
      vault_exec vault kv put "${VAULT_KV_MOUNT}/tenants/${org_id}/projects/${project_id}/bootstrap" message="${TENANT_SMOKE_MESSAGE}" >/dev/null
    fi
  done
done

log "Tenant ESO policies/roles reconcile completed."
