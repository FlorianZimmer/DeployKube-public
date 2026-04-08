#!/bin/sh
set -euo pipefail

ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-/vault/userconfig/root/token}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault-system}"
VAULT_POD_SELECTOR="${VAULT_POD_SELECTOR:-app.kubernetes.io/name=vault}"
VAULT_LOCAL_ADDR="${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}"
PKI_MOUNT="${PKI_MOUNT:-pki-ext}"
PKI_MAX_LEASE_TTL="${PKI_MAX_LEASE_TTL:-43800h}"
PKI_ROLE_NAME="${PKI_ROLE_NAME:-platform-ingress}"
PKI_ROLE_TTL="${PKI_ROLE_TTL:-2160h}"
ROOT_ISSUER_NAME="${ROOT_ISSUER_NAME:-deploykube-external-root}"
INTERMEDIATE_ISSUER_NAME="${INTERMEDIATE_ISSUER_NAME:-deploykube-external-intermediate}"
INTERMEDIATE_COMMON_NAME="${INTERMEDIATE_COMMON_NAME:-DeployKube External Intermediate CA}"
INTERMEDIATE_TTL="${INTERMEDIATE_TTL:-43800h}"
STEP_CA_CERTS_PATH="${STEP_CA_CERTS_PATH:-secret/step-ca/certs}"
STEP_CA_KEYS_PATH="${STEP_CA_KEYS_PATH:-secret/step-ca/keys}"
STEP_CA_PASSWORDS_PATH="${STEP_CA_PASSWORDS_PATH:-secret/step-ca/passwords}"
KUBERNETES_AUTH_MOUNT="${KUBERNETES_AUTH_MOUNT:-auth/kubernetes}"
CERT_MANAGER_POLICY_NAME="${CERT_MANAGER_POLICY_NAME:-cert-manager-vault-external}"
CERT_MANAGER_ROLE_NAME="${CERT_MANAGER_ROLE_NAME:-cert-manager-vault-external}"
CRL_EXPIRY="${CRL_EXPIRY:-24h}"
OCSP_EXPIRY="${OCSP_EXPIRY:-12h}"
CRL_AUTO_REBUILD_GRACE="${CRL_AUTO_REBUILD_GRACE:-8h}"
DELTA_REBUILD_INTERVAL="${DELTA_REBUILD_INTERVAL:-10m}"

log() {
  printf '[vault-pki-external] %s\n' "$*"
}

if [ ! -f "${ROOT_TOKEN_FILE}" ]; then
  log "vault root token missing; skipping"
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl missing"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq missing"
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  log "openssl missing"
  exit 1
fi

VAULT_TOKEN="$(cat "${ROOT_TOKEN_FILE}")"
BAO_TOKEN="${BAO_TOKEN:-${VAULT_TOKEN}}"
export VAULT_TOKEN BAO_TOKEN

vault_pod="$(kubectl -n "${VAULT_NAMESPACE}" get pods -l "${VAULT_POD_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "${vault_pod}" ]; then
  log "vault pod not found; skipping"
  exit 0
fi

vault_exec() {
  kubectl -n "${VAULT_NAMESPACE}" exec "${vault_pod}" -- env \
    BAO_ADDR="${VAULT_LOCAL_ADDR}" \
    VAULT_ADDR="${VAULT_LOCAL_ADDR}" \
    BAO_TOKEN="${BAO_TOKEN}" \
    VAULT_TOKEN="${VAULT_TOKEN}" \
    "$@"
}

if ! vault_exec vault status >/dev/null 2>&1; then
  log "vault not ready; skipping"
  exit 0
fi

dep_cfg_json="$(kubectl get deploymentconfigs.platform.darksite.cloud -o json 2>/dev/null || true)"
if [ -z "${dep_cfg_json}" ]; then
  log "deployment config not readable yet; skipping"
  exit 0
fi

dep_cfg_count="$(printf '%s' "${dep_cfg_json}" | jq -r '.items | length' 2>/dev/null || echo 0)"
if [ "${dep_cfg_count}" -ne 1 ]; then
  log "expected exactly one DeploymentConfig, found ${dep_cfg_count}; skipping"
  exit 0
fi

platform_mode="$(printf '%s' "${dep_cfg_json}" | jq -r '.items[0].spec.certificates.platformIngress.mode // "subCa"')"

vault_hostname="$(printf '%s' "${dep_cfg_json}" | jq -r '.items[0].spec.dns.hostnames.vault // empty')"
if [ -z "${vault_hostname}" ]; then
  log "spec.dns.hostnames.vault is required for platformIngress.mode=vault"
  exit 1
fi

allowed_domains=""
for key in garage forgejo argocd keycloak vault kiali hubble grafana harbor registry; do
  host="$(printf '%s' "${dep_cfg_json}" | jq -r --arg key "${key}" '.items[0].spec.dns.hostnames[$key] // empty')"
  if [ -z "${host}" ]; then
    log "missing platform hostname for key '${key}'"
    exit 1
  fi
  if [ -n "${allowed_domains}" ]; then
    allowed_domains="${allowed_domains},"
  fi
  allowed_domains="${allowed_domains}${host}"
done

issuing_certificates_url="https://${vault_hostname}/v1/${PKI_MOUNT}/ca"
crl_distribution_points_url="https://${vault_hostname}/v1/${PKI_MOUNT}/crl/pem"
ocsp_servers_url="https://${vault_hostname}/v1/${PKI_MOUNT}/ocsp"

ensure_mount() {
  if ! vault_exec vault secrets list -format=json | jq -e --arg path "${PKI_MOUNT}/" '.[$path] != null' >/dev/null 2>&1; then
    log "enabling PKI mount ${PKI_MOUNT}"
    vault_exec vault secrets enable -path="${PKI_MOUNT}" pki >/dev/null
  fi
  vault_exec vault secrets tune -max-lease-ttl="${PKI_MAX_LEASE_TTL}" "${PKI_MOUNT}" >/dev/null
}

issuer_id_by_name() {
  issuer_name="$1"
  list_issuer_ids | while IFS= read -r issuer_id; do
    [ -n "${issuer_id}" ] || continue
    current_name="$(vault_exec vault read -format=json "${PKI_MOUNT}/issuer/${issuer_id}" 2>/dev/null | jq -r '.data.issuer_name // empty' 2>/dev/null || true)"
    if [ "${current_name}" = "${issuer_name}" ]; then
      printf '%s\n' "${issuer_id}"
      break
    fi
  done | head -n1
}

issuer_count() {
  list_issuer_ids | awk 'NF {count++} END {print count+0}'
}

list_issuer_ids() {
  issuers_json="$(vault_exec vault list -format=json "${PKI_MOUNT}/issuers" 2>/dev/null || true)"
  if [ -z "${issuers_json}" ]; then
    return 0
  fi
  printf '%s' "${issuers_json}" | jq -r '.[]' 2>/dev/null || true
}

import_root_ca_material() {
  tmp_dir="$(mktemp -d)"

  log "retrieving Step CA root material from Vault KV"
  vault_exec vault kv get -field=root_ca_crt "${STEP_CA_CERTS_PATH}" > "${tmp_dir}/root_ca.crt"
  vault_exec vault kv get -field=root_ca_key "${STEP_CA_KEYS_PATH}" > "${tmp_dir}/root_ca.key.enc"
  vault_exec vault kv get -field=ca_password "${STEP_CA_PASSWORDS_PATH}" > "${tmp_dir}/ca_password"

  if ! openssl ec -in "${tmp_dir}/root_ca.key.enc" -passin file:"${tmp_dir}/ca_password" -out "${tmp_dir}/root_ca.key" >/dev/null 2>&1; then
    rm -rf "${tmp_dir}"
    log "failed to decrypt Step CA root key from ${STEP_CA_KEYS_PATH}"
    exit 1
  fi

  cat "${tmp_dir}/root_ca.key" "${tmp_dir}/root_ca.crt" > "${tmp_dir}/root_bundle.pem"
  vault_exec vault write "${PKI_MOUNT}/config/ca" pem_bundle="$(cat "${tmp_dir}/root_bundle.pem")" >/dev/null
  rm -rf "${tmp_dir}"
}

bootstrap_root_and_intermediate() {
  existing_issuer_count="$(issuer_count)"
  root_issuer_id="$(issuer_id_by_name "${ROOT_ISSUER_NAME}")"
  intermediate_issuer_id="$(issuer_id_by_name "${INTERMEDIATE_ISSUER_NAME}")"

  if [ -n "${intermediate_issuer_id}" ]; then
    return 0
  fi

  if [ -z "${root_issuer_id}" ]; then
    if [ "${existing_issuer_count}" -gt 0 ]; then
      current_default="$(vault_exec vault read -field=default "${PKI_MOUNT}/config/issuers" 2>/dev/null || true)"
      if [ -z "${current_default}" ]; then
        current_default="$(vault_exec vault list -format=json "${PKI_MOUNT}/issuers" 2>/dev/null | jq -r '.data.keys[0] // empty')"
      fi
      if [ -n "${current_default}" ]; then
        log "naming existing default issuer ${current_default} as ${ROOT_ISSUER_NAME}"
        vault_exec vault write "${PKI_MOUNT}/issuer/${current_default}" issuer_name="${ROOT_ISSUER_NAME}" >/dev/null
        root_issuer_id="${current_default}"
      fi
    else
      log "importing existing root CA material into ${PKI_MOUNT}"
      import_root_ca_material
      root_issuer_id="$(vault_exec vault read -field=default "${PKI_MOUNT}/config/issuers" 2>/dev/null || true)"
      if [ -z "${root_issuer_id}" ]; then
        log "failed to resolve imported root issuer"
        exit 1
      fi
      vault_exec vault write "${PKI_MOUNT}/issuer/${root_issuer_id}" issuer_name="${ROOT_ISSUER_NAME}" >/dev/null
    fi
  fi

  if [ -z "${root_issuer_id}" ]; then
    log "root issuer unavailable; cannot generate external intermediate"
    exit 1
  fi

  log "generating dedicated external intermediate ${INTERMEDIATE_ISSUER_NAME}"
  issuers_before="$(list_issuer_ids | tr '\n' ' ')"
  intermediate_json="$(vault_exec vault write -format=json "${PKI_MOUNT}/intermediate/generate/internal" \
    common_name="${INTERMEDIATE_COMMON_NAME}" \
    issuer_name="${INTERMEDIATE_ISSUER_NAME}" \
    ttl="${INTERMEDIATE_TTL}")"
  intermediate_csr="$(printf '%s' "${intermediate_json}" | jq -r '.data.csr // empty' 2>/dev/null || true)"
  if [ -z "${intermediate_csr}" ]; then
    log "failed to read CSR for ${INTERMEDIATE_ISSUER_NAME}"
    exit 1
  fi

  signed_json="$(vault_exec vault write -format=json "${PKI_MOUNT}/root/sign-intermediate" \
    "csr=${intermediate_csr}" \
    format="pem_bundle" \
    ttl="${INTERMEDIATE_TTL}")"
  signed_certificate="$(printf '%s' "${signed_json}" | jq -r '.data.certificate // empty' 2>/dev/null || true)"
  if [ -z "${signed_certificate}" ]; then
    log "failed to read signed certificate for ${INTERMEDIATE_ISSUER_NAME}"
    exit 1
  fi

  vault_exec vault write "${PKI_MOUNT}/intermediate/set-signed" "certificate=${signed_certificate}" >/dev/null

  intermediate_issuer_id=""
  for issuer_id in $(list_issuer_ids); do
    case " ${issuers_before} " in
      *" ${issuer_id} "*) continue ;;
    esac
    intermediate_issuer_id="${issuer_id}"
    break
  done
  if [ -n "${intermediate_issuer_id}" ]; then
    vault_exec vault write "${PKI_MOUNT}/issuer/${intermediate_issuer_id}" issuer_name="${INTERMEDIATE_ISSUER_NAME}" >/dev/null
  fi

  intermediate_issuer_id="$(issuer_id_by_name "${INTERMEDIATE_ISSUER_NAME}")"
  if [ -z "${intermediate_issuer_id}" ]; then
    log "external intermediate did not appear after bootstrap"
    exit 1
  fi
}

write_cert_manager_policy() {
  vault_exec sh -c '
set -eu
tmp_dir="/home/vault/tmp"
mkdir -p "${tmp_dir}"
policy_file="${tmp_dir}/'"${CERT_MANAGER_POLICY_NAME}"'.hcl"
cat > "${policy_file}" <<EOF
path "'"${PKI_MOUNT}"'/sign/'"${PKI_ROLE_NAME}"'" {
  capabilities = ["update"]
}

path "'"${PKI_MOUNT}"'/issue/'"${PKI_ROLE_NAME}"'" {
  capabilities = ["update"]
}

path "'"${PKI_MOUNT}"'/issuer/default" {
  capabilities = ["read"]
}

path "'"${PKI_MOUNT}"'/issuer/default/json" {
  capabilities = ["read"]
}

path "'"${PKI_MOUNT}"'/ca" {
  capabilities = ["read"]
}

path "'"${PKI_MOUNT}"'/ca/pem" {
  capabilities = ["read"]
}

path "'"${PKI_MOUNT}"'/cert/ca" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
vault policy write "'"${CERT_MANAGER_POLICY_NAME}"'" "${policy_file}" >/dev/null
rm -f "${policy_file}"
'
}

ensure_mount
bootstrap_root_and_intermediate

log "configuring ${PKI_MOUNT} URLs, CRL/OCSP settings, and issuance role"
log "deployment contract currently sets platformIngress.mode=${platform_mode}"
vault_exec vault write "${PKI_MOUNT}/config/urls" \
  issuing_certificates="${issuing_certificates_url}" \
  crl_distribution_points="${crl_distribution_points_url}" \
  ocsp_servers="${ocsp_servers_url}" >/dev/null

vault_exec vault write "${PKI_MOUNT}/config/issuers" \
  default="${INTERMEDIATE_ISSUER_NAME}" \
  default_follows_latest_issuer=false >/dev/null

vault_exec vault write "${PKI_MOUNT}/config/crl" \
  expiry="${CRL_EXPIRY}" \
  disable=false \
  ocsp_disable=false \
  ocsp_expiry="${OCSP_EXPIRY}" \
  auto_rebuild=true \
  auto_rebuild_grace_period="${CRL_AUTO_REBUILD_GRACE}" \
  enable_delta=true \
  delta_rebuild_interval="${DELTA_REBUILD_INTERVAL}" >/dev/null

vault_exec vault write "${PKI_MOUNT}/roles/${PKI_ROLE_NAME}" \
  allowed_domains="${allowed_domains}" \
  allow_bare_domains=true \
  allow_subdomains=false \
  allow_glob_domains=false \
  allow_any_name=false \
  allow_localhost=false \
  allow_ip_sans=false \
  allow_wildcard_certificates=false \
  enforce_hostnames=true \
  require_cn=false \
  key_type="rsa" \
  key_bits=2048 \
  server_flag=true \
  client_flag=false \
  code_signing_flag=false \
  email_protection_flag=false \
  ttl="${PKI_ROLE_TTL}" \
  max_ttl="${PKI_ROLE_TTL}" \
  no_store=false >/dev/null

write_cert_manager_policy

log "binding cert-manager Kubernetes auth role ${CERT_MANAGER_ROLE_NAME}"
vault_exec vault write "${KUBERNETES_AUTH_MOUNT}/role/${CERT_MANAGER_ROLE_NAME}" \
  bound_service_account_names="cert-manager" \
  bound_service_account_namespaces="cert-manager" \
  policies="${CERT_MANAGER_POLICY_NAME}" \
  token_ttl="1h" \
  token_max_ttl="24h" >/dev/null

vault_exec vault read "${PKI_MOUNT}/crl/rotate" >/dev/null 2>&1 || true
vault_exec vault read "${PKI_MOUNT}/crl/rotate-delta" >/dev/null 2>&1 || true

log "Vault/OpenBao external PKI reconcile completed"
