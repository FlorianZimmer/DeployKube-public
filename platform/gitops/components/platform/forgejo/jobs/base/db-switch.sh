#!/bin/sh
set -euo pipefail

SCRIPT_NAME="forgejo-db-switch"
NAMESPACE="${NAMESPACE:-forgejo}"
SEED_SENTINEL="forgejo-db-seed-complete"
SWITCH_SENTINEL="${SCRIPT_NAME}-complete"
SECRET_NAME="${POSTGRES_APP_SECRET:-forgejo-postgres-app}"
INLINE_SECRET="${FORGEJO_SECRET:-forgejo-inline-config}"
DEPLOYMENT_NAME="${FORGEJO_DEPLOYMENT:-forgejo}"
DB_HOST="${POSTGRES_HOST:-postgres-rw}"
DB_NAME="${POSTGRES_DB:-forgejo}"
TARGET_REPLICAS="${TARGET_REPLICAS:-2}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
CNPG_SERVICE_WAIT="${CNPG_SERVICE_WAIT:-true}"

wait_for_secret_key() {
  local secret="$1" key="$2" attempt=0
  while [ "$attempt" -lt "$WAIT_ATTEMPTS" ]; do
    value=$(kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath="{.data.${key}}" 2>/dev/null || true)
    if [ -n "$value" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for secret ${secret} key ${key} (${attempt}/${WAIT_ATTEMPTS})"
    sleep "$WAIT_INTERVAL"
  done
  log "secret ${secret} missing key ${key} after waiting"
  exit 1
}

wait_for_service() {
  local svc="$1" attempt=0
  if [ "$CNPG_SERVICE_WAIT" != "true" ]; then
    return 0
  fi
  while [ "$attempt" -lt "$WAIT_ATTEMPTS" ]; do
    if kubectl -n "$NAMESPACE" get svc "$svc" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for service ${svc} (${attempt}/${WAIT_ATTEMPTS})"
    sleep "$WAIT_INTERVAL"
  done
  log "service ${svc} not found"
  exit 1
}

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

db_config_has_ssl_mode_require() {
  local encoded decoded mode
  encoded=$(kubectl -n "${NAMESPACE}" get secret "${INLINE_SECRET}" -o jsonpath='{.data.database}' 2>/dev/null || true)
  if [ -z "${encoded}" ]; then
    return 1
  fi
  decoded=$(printf '%s' "${encoded}" | base64 -d 2>/dev/null || true)
  mode=$(printf '%s\n' "${decoded}" | awk -F= '/^SSL_MODE=/{print $2}' | tail -n 1)
  [ "${mode}" = "require" ]
}

if kubectl -n "${NAMESPACE}" get configmap "${SWITCH_SENTINEL}" >/dev/null 2>&1; then
  if db_config_has_ssl_mode_require; then
    log "switch sentinel exists and SSL_MODE=require already configured; skipping"
    exit 0
  fi
  log "switch sentinel exists but SSL_MODE not set to require; proceeding with in-place config update"
fi

if ! kubectl -n "${NAMESPACE}" get configmap "${SEED_SENTINEL}" >/dev/null 2>&1; then
  log "seed sentinel ${SEED_SENTINEL} missing; run forgejo-db-seed first"
  exit 1
fi

wait_for_secret_key "${SECRET_NAME}" "username"
wait_for_secret_key "${SECRET_NAME}" "password"
wait_for_service "${DB_HOST}"

log "fetching database credentials"
DB_USER=$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.username}' | base64 -d)
DB_PASS=$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.password}' | base64 -d)

if [ -z "${DB_USER}" ] || [ -z "${DB_PASS}" ]; then
  log "failed to read database credentials"
  exit 1
fi

cat <<PATCH > /tmp/db-patch.json
{
  "data": {
    "database": "$(printf 'DB_TYPE=postgres\nHOST=%s\nNAME=%s\nUSER=%s\nPASSWD=%s\nSSL_MODE=require\n' "${DB_HOST}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" | base64 | tr -d '\n')"
  }
}
PATCH

log "patching Forgejo database config"
kubectl -n "${NAMESPACE}" patch secret "${INLINE_SECRET}" --type merge --patch-file /tmp/db-patch.json
rm -f /tmp/db-patch.json

log "forcing Recreate rollout for ${DEPLOYMENT_NAME}"
kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type=json -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}}]'
log "restarting deployment"
kubectl -n "${NAMESPACE}" rollout restart deployment "${DEPLOYMENT_NAME}"
kubectl -n "${NAMESPACE}" rollout status deployment "${DEPLOYMENT_NAME}" --timeout=600s

log "restoring RollingUpdate strategy"
kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type=json -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}]'

log "scaling deployment to ${TARGET_REPLICAS} replicas"
kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge -p "{\"spec\":{\"replicas\":${TARGET_REPLICAS}}}"

log "creating switch sentinel"
kubectl -n "${NAMESPACE}" create configmap "${SWITCH_SENTINEL}" --from-literal=db="${DB_HOST}" --dry-run=client -o yaml | kubectl apply -f -
log "database switch complete"
