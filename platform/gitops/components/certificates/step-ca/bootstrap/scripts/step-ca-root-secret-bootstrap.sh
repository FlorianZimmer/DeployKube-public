#!/bin/sh
set -eu

log() {
  printf '[step-ca-root-secret-bootstrap] %s\n' "$1"
}

STEP_CA_NAMESPACE="${STEP_CA_NAMESPACE:-step-system}"
STEP_CA_FULLNAME="${STEP_CA_FULLNAME:-step-ca-step-certificates}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
STEP_CA_TLS_SECRET_NAME="${STEP_CA_TLS_SECRET_NAME:-step-ca-root-ca}"

CERTS_SECRET="${STEP_CA_FULLNAME}-certs"
PRIVATE_KEYS_SECRET="${STEP_CA_FULLNAME}-secrets"
PASSWORD_SECRET="${STEP_CA_FULLNAME}-ca-password"

WAIT_SLEEP_SECONDS="${WAIT_SLEEP_SECONDS:-2}"
# Single global wait budget to avoid triple timeouts (certs + keys + password).
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-900}"

ensure_namespace() {
  ns="$1"
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    return
  fi
  log "namespace ${ns} missing, creating it"
  kubectl create namespace "$ns"
}

wait_for_required_secrets() {
  ns="$1"
  secrets="$2"
  log "waiting for required Step CA secrets in ${ns} (up to $((WAIT_ATTEMPTS * WAIT_SLEEP_SECONDS))s)"
  attempt=0
  while [ "$attempt" -lt "$WAIT_ATTEMPTS" ]; do
    missing=""
    for name in $secrets; do
      if ! kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
        missing="${missing} ${name}"
      fi
    done
    if [ -z "$missing" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "still missing (${attempt}/${WAIT_ATTEMPTS}):${missing}"
    sleep "$WAIT_SLEEP_SECONDS"
  done
  log "required secrets did not appear in time:${missing}"
  return 1
}

ensure_namespace "$CERT_MANAGER_NAMESPACE"

if kubectl -n "$CERT_MANAGER_NAMESPACE" get secret "$STEP_CA_TLS_SECRET_NAME" >/dev/null 2>&1; then
  log "secret ${CERT_MANAGER_NAMESPACE}/${STEP_CA_TLS_SECRET_NAME} already exists"
  exit 0
fi

wait_for_required_secrets "$STEP_CA_NAMESPACE" "$CERTS_SECRET $PRIVATE_KEYS_SECRET $PASSWORD_SECRET"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

root_crt_b64=$(kubectl -n "$STEP_CA_NAMESPACE" get secret "$CERTS_SECRET" -o jsonpath='{.data.root_ca\.crt}')
if [ -z "$root_crt_b64" ]; then
  log "missing root certificate in ${CERTS_SECRET}"
  exit 1
fi
printf '%s' "$root_crt_b64" | base64 -d > "${tmpdir}/root.crt"

root_key_b64=$(kubectl -n "$STEP_CA_NAMESPACE" get secret "$PRIVATE_KEYS_SECRET" -o jsonpath='{.data.root_ca_key}')
if [ -z "$root_key_b64" ]; then
  log "missing root key in ${PRIVATE_KEYS_SECRET}"
  exit 1
fi
printf '%s' "$root_key_b64" | base64 -d > "${tmpdir}/root.key.enc"

ca_password=$(kubectl -n "$STEP_CA_NAMESPACE" get secret "$PASSWORD_SECRET" -o jsonpath='{.data.password}' | base64 -d)
if [ -z "$ca_password" ]; then
  log "missing CA password in ${PASSWORD_SECRET}"
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  log "openssl missing from bootstrap tools image; add it to shared/images/bootstrap-tools/Dockerfile"
  exit 1
fi

if ! openssl ec -in "${tmpdir}/root.key.enc" -passin pass:"$ca_password" -out "${tmpdir}/root.key" >/dev/null 2>&1; then
  log "failed to decrypt root key"
  exit 1
fi

kubectl -n "$CERT_MANAGER_NAMESPACE" create secret tls "$STEP_CA_TLS_SECRET_NAME" \
  --cert="${tmpdir}/root.crt" \
  --key="${tmpdir}/root.key" \
  --dry-run=client -o yaml | kubectl apply -f -

log "created ${CERT_MANAGER_NAMESPACE}/${STEP_CA_TLS_SECRET_NAME}"
