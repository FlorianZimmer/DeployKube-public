#!/bin/sh
set -euo pipefail

TENANT_REGISTRY_PATH="${TENANT_REGISTRY_PATH:-/tenant-registry/tenant-registry.yaml}"
ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_K8S_AUTH_MOUNT="${VAULT_K8S_AUTH_MOUNT:-kubernetes}"
TENANT_DNS_ZONE_SUFFIX="${TENANT_DNS_ZONE_SUFFIX:-workloads}"
TENANT_DNS_SERVER="${TENANT_DNS_SERVER:-powerdns.dns-system.svc.cluster.local:53}"
TENANT_DNS_TSIG_ALGORITHM="${TENANT_DNS_TSIG_ALGORITHM:-hmac-sha256}"
TENANT_DNS_ROTATE_AFTER_HOURS="${TENANT_DNS_ROTATE_AFTER_HOURS:-720}"
ESO_SERVICEACCOUNT_NAME="${ESO_SERVICEACCOUNT_NAME:-external-secrets}"
ESO_SERVICEACCOUNT_NAMESPACE="${ESO_SERVICEACCOUNT_NAMESPACE:-external-secrets}"
ESO_TOKEN_TTL="${ESO_TOKEN_TTL:-1h}"
ESO_TOKEN_MAX_TTL="${ESO_TOKEN_MAX_TTL:-4h}"

log() {
  printf '[vault-tenant-dns-rfc2136] %s\n' "$*"
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

random_tsig_secret() {
  head -c 32 /dev/urandom | base64 | tr -d '\n'
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

base_domain="$(kubectl get deploymentconfigs.platform.darksite.cloud -o jsonpath='{.items[0].spec.dns.baseDomain}' 2>/dev/null || true)"
if [ -z "${base_domain}" ]; then
  log "unable to resolve base domain from DeploymentConfig; skipping"
  exit 0
fi
base_domain="$(printf '%s' "${base_domain}" | tr -d '[:space:]' | sed 's/\.$//')"

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

write_cloud_dns_policy() {
  policy_name="$1"
  org_id="$2"

  vault_exec env POLICY_NAME="${policy_name}" ORG_ID="${org_id}" KV_MOUNT="${VAULT_KV_MOUNT}" sh -c '
set -eu
mkdir -p /home/vault/tmp
policy_file="/home/vault/tmp/${POLICY_NAME}.hcl"
cat >"${policy_file}" <<EOF
path "${KV_MOUNT}/data/tenants/${ORG_ID}/sys/dns/rfc2136" {
  capabilities = ["read"]
}

path "${KV_MOUNT}/metadata/tenants/${ORG_ID}/sys/dns/rfc2136" {
  capabilities = ["read"]
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

ensure_cloud_dns_role() {
  role_name="$1"
  policy_name="$2"

  vault_exec vault write "auth/${VAULT_K8S_AUTH_MOUNT}/role/${role_name}" \
    bound_service_account_names="${ESO_SERVICEACCOUNT_NAME}" \
    bound_service_account_namespaces="${ESO_SERVICEACCOUNT_NAMESPACE}" \
    token_policies="${policy_name}" \
    token_ttl="${ESO_TOKEN_TTL}" \
    token_max_ttl="${ESO_TOKEN_MAX_TTL}" >/dev/null
}

rotate_after_seconds=0
if [ "${TENANT_DNS_ROTATE_AFTER_HOURS}" -gt 0 ] 2>/dev/null; then
  rotate_after_seconds=$((TENANT_DNS_ROTATE_AFTER_HOURS * 3600))
fi

log "Reconciling tenant RFC2136 credentials from ${TENANT_REGISTRY_PATH} (baseDomain=${base_domain}, rotateAfterHours=${TENANT_DNS_ROTATE_AFTER_HOURS})..."

yq -r '.tenants[].orgId // ""' "${TENANT_REGISTRY_PATH}" | while IFS= read -r org_id; do
  [ -z "${org_id}" ] && continue
  validate_tenant_id "orgId" "${org_id}"

  zone="${org_id}.${TENANT_DNS_ZONE_SUFFIX}.${base_domain}"
  kv_path="${VAULT_KV_MOUNT}/tenants/${org_id}/sys/dns/rfc2136"
  key_name="tenant-${org_id}-rfc2136"
  txt_owner_id="tenant-${org_id}-cloud-dns"
  policy_name="tenant-${org_id}-cloud-dns-rfc2136-ro"
  role_name="k8s-tenant-${org_id}-cloud-dns-eso"

  existing_json="$(vault_exec vault kv get -format=json "${kv_path}" 2>/dev/null || true)"
  existing_secret="$(printf '%s' "${existing_json}" | jq -r '.data.data.tsigSecret // empty' 2>/dev/null || true)"
  existing_rotated_epoch="$(printf '%s' "${existing_json}" | jq -r '.data.data.rotatedAtEpoch // empty' 2>/dev/null || true)"

  rotate="false"
  if [ -z "${existing_secret}" ]; then
    rotate="true"
  elif [ "${rotate_after_seconds}" -gt 0 ] && [ -n "${existing_rotated_epoch}" ] && printf '%s' "${existing_rotated_epoch}" | grep -Eq '^[0-9]+$'; then
    now_epoch="$(date +%s)"
    age_seconds=$((now_epoch - existing_rotated_epoch))
    if [ "${age_seconds}" -ge "${rotate_after_seconds}" ]; then
      rotate="true"
    fi
  fi

  tsig_secret="${existing_secret}"
  if [ "${rotate}" = "true" ]; then
    tsig_secret="$(random_tsig_secret)"
  fi
  rotated_epoch="$(date +%s)"

  vault_exec vault kv put "${kv_path}" \
    zone="${zone}" \
    server="${TENANT_DNS_SERVER}" \
    tsigKeyName="${key_name}" \
    tsigSecret="${tsig_secret}" \
    tsigAlgorithm="${TENANT_DNS_TSIG_ALGORITHM}" \
    txtOwnerId="${txt_owner_id}" \
    rotatedAtEpoch="${rotated_epoch}" >/dev/null

  write_cloud_dns_policy "${policy_name}" "${org_id}"
  ensure_cloud_dns_role "${role_name}" "${policy_name}"

  if [ "${rotate}" = "true" ]; then
    log "issued/rotated TSIG secret and reconciled scoped Vault role for orgId=${org_id} zone=${zone}"
  else
    log "reconciled TSIG metadata and scoped Vault role for orgId=${org_id} zone=${zone}"
  fi
done

log "Tenant RFC2136 credential reconcile completed."
