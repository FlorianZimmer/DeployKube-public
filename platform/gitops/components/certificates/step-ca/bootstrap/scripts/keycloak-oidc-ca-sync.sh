#!/bin/sh
set -euo pipefail

log() {
  printf '[keycloak-oidc-ca-sync] %s\n' "$1"
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "missing dependency: $1"
    exit 1
  fi
}

require base64
require curl
require jq
require kubectl
require openssl

ISTIO_HELPER="${ISTIO_HELPER:-/helpers/istio-native-exit.sh}"
if [ -f "${ISTIO_HELPER}" ]; then
  # shellcheck disable=SC1090
  . "${ISTIO_HELPER}"
  trap 'deploykube_istio_quit_sidecar || true' EXIT INT TERM
else
  log "warning: missing istio-native-exit helper (${ISTIO_HELPER}); job may hang on istio-proxy"
fi

VAULT_ADDR="${VAULT_ADDR:-http://vault.vault-system.svc:8200}"
VAULT_ROLE="${VAULT_ROLE:-keycloak-oidc-ca-sync}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CA_SECRET_NAME="${CA_SECRET_NAME:-step-ca-root-ca}"

VAULT_WRITE_PATH="${VAULT_WRITE_PATH:-secret/data/keycloak/oidc-ca}"
VAULT_FIELD_NAME="${VAULT_FIELD_NAME:-ca_crt}"
VAULT_WAIT_ATTEMPTS="${VAULT_WAIT_ATTEMPTS:-900}"
SECRET_WAIT_ATTEMPTS="${SECRET_WAIT_ATTEMPTS:-900}"
WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-2}"

wait_for_vault() {
  log "waiting for Vault API at ${VAULT_ADDR}"
  for attempt in $(seq 1 "${VAULT_WAIT_ATTEMPTS}"); do
    health=$(curl -s "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || true)
    if [ -n "${health}" ] && printf '%s' "${health}" | jq -e '.initialized == true and .sealed == false' >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "${health}" ] && [ $((attempt % 30)) -eq 0 ]; then
      log "Vault not ready (attempt ${attempt}/${VAULT_WAIT_ATTEMPTS}): ${health}"
    else
      log "Vault not ready (attempt ${attempt}/${VAULT_WAIT_ATTEMPTS})"
    fi
    sleep "${WAIT_SLEEP_SECONDS}"
  done
  log "Vault did not become ready in time"
  return 1
}

wait_for_secret() {
  ns="$1"
  name="$2"
  log "waiting for secret ${ns}/${name}"
  for attempt in $(seq 1 "${SECRET_WAIT_ATTEMPTS}"); do
    if kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
      return 0
    fi
    log "secret ${ns}/${name} not ready (attempt ${attempt}/${SECRET_WAIT_ATTEMPTS})"
    sleep "${WAIT_SLEEP_SECONDS}"
  done
  log "secret ${ns}/${name} did not appear in time"
  return 1
}

vault_login() {
  jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
  payload=$(jq -n --arg role "${VAULT_ROLE}" --arg jwt "${jwt}" '{role:$role,jwt:$jwt}')
  resp=$(curl -sSf -H "Content-Type: application/json" -X POST --data "${payload}" \
    "${VAULT_ADDR}/v1/auth/kubernetes/login")
  token=$(printf '%s' "${resp}" | jq -r '.auth.client_token')
  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    log "failed to mint Vault token via kubernetes auth"
    exit 1
  fi
  printf '%s' "${token}"
}

main() {
  wait_for_vault
  wait_for_secret "${CERT_MANAGER_NAMESPACE}" "${CA_SECRET_NAME}"

  tmp_ca="$(mktemp)"
  trap 'rm -f "${tmp_ca}"' EXIT INT TERM

  ca_b64=$(kubectl -n "${CERT_MANAGER_NAMESPACE}" get secret "${CA_SECRET_NAME}" -o jsonpath='{.data.tls\.crt}')
  if [ -z "${ca_b64}" ]; then
    log "missing tls.crt in secret ${CERT_MANAGER_NAMESPACE}/${CA_SECRET_NAME}"
    exit 1
  fi
  printf '%s' "${ca_b64}" | base64 -d > "${tmp_ca}"
  if [ ! -s "${tmp_ca}" ]; then
    log "decoded CA bundle is empty"
    exit 1
  fi

  issuer=$(openssl x509 -in "${tmp_ca}" -noout -issuer 2>/dev/null || true)
  subject=$(openssl x509 -in "${tmp_ca}" -noout -subject 2>/dev/null || true)
  log "publishing OIDC CA from ${CERT_MANAGER_NAMESPACE}/${CA_SECRET_NAME} (${issuer}; ${subject})"

  token=$(vault_login)
  payload=$(jq -n --arg ca "$(cat "${tmp_ca}")" --arg key "${VAULT_FIELD_NAME}" '{data:{($key):$ca}}')
  curl -sSf -H "X-Vault-Token: ${token}" -H "Content-Type: application/json" -X POST \
    --data "${payload}" \
    "${VAULT_ADDR}/v1/${VAULT_WRITE_PATH}" >/dev/null

  log "wrote Vault secret ${VAULT_WRITE_PATH} (${VAULT_FIELD_NAME})"

  if command -v deploykube_istio_quit_sidecar >/dev/null 2>&1; then
    deploykube_istio_quit_sidecar || true
  fi
}

main "$@"
