#!/bin/sh
set -euo pipefail

SCRIPT_NAME="forgejo-cache-switch"
NAMESPACE="${NAMESPACE:-forgejo}"
SENTINEL_CM="${SCRIPT_NAME}-complete"
SECRET_NAME="${FORGEJO_SECRET:-forgejo-inline-config}"
DEPLOYMENT_NAME="${FORGEJO_DEPLOYMENT:-forgejo}"
VALKEY_MASTER="${VALKEY_MASTER:-forgejo-valkey}"
VALKEY_SENTINEL_HEADLESS="${VALKEY_SENTINEL_HEADLESS:-forgejo-valkey-sentinel-headless}"
VALKEY_SENTINEL_STATEFULSET="${VALKEY_SENTINEL_STATEFULSET:-${VALKEY_MASTER}-sentinel}"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

decode_secret_key() {
  key="$1"
  raw=$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o "jsonpath={.data.${key}}" 2>/dev/null || true)
  if [ -z "${raw}" ]; then
    return 1
  fi
  printf '%s' "${raw}" | base64 -d 2>/dev/null
}

current_cache_mode() {
  local decoded
  decoded=$(decode_secret_key cache 2>/dev/null || true)
  if [ -z "${decoded}" ]; then
    echo "unknown"
    return
  fi
  if printf '%s' "${decoded}" | grep -q 'ADAPTER=redis'; then
    echo "redis"
  elif printf '%s' "${decoded}" | grep -q 'ADAPTER=memory'; then
    echo "memory"
  else
    echo "other"
  fi
}

CACHE_MODE="$(current_cache_mode)"

if kubectl -n "${NAMESPACE}" get configmap "${SENTINEL_CM}" >/dev/null 2>&1; then
  if [ "${CACHE_MODE}" = "redis" ]; then
    log "sentinel ConfigMap ${SENTINEL_CM} exists; validating inline config still matches desired state"
  else
    log "sentinel ConfigMap ${SENTINEL_CM} exists but cache mode is ${CACHE_MODE}; continuing reconciliation"
  fi
fi

log "waiting for forgejo-valkey StatefulSet"
kubectl -n "${NAMESPACE}" rollout status statefulset/${VALKEY_MASTER} --timeout=600s
log "waiting for forgejo-valkey-sentinel StatefulSet"
kubectl -n "${NAMESPACE}" rollout status statefulset/${VALKEY_SENTINEL_STATEFULSET} --timeout=600s

log "fetching Valkey password"
VALKEY_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret valkey-auth -o jsonpath='{.data.password}' | base64 -d)
if [ -z "${VALKEY_PASSWORD}" ]; then
  log "failed to read Valkey password"
  exit 1
fi

urlencode() {
  # Passwords are base64-ish and often contain "/" and "+", which must be URL-encoded
  # for redis:// and redis+sentinel:// connection strings.
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

VALKEY_PASSWORD_URLENCODED="$(urlencode "${VALKEY_PASSWORD}")"

SENTINEL_HOSTS=""
SENTINEL_REPLICAS=$(kubectl -n "${NAMESPACE}" get statefulset "${VALKEY_SENTINEL_STATEFULSET}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
case "${SENTINEL_REPLICAS}" in
  ''|*[!0-9]*)
    SENTINEL_REPLICAS=1
    ;;
esac
sentinel_fqdn="${VALKEY_SENTINEL_HEADLESS}.${NAMESPACE}.svc.cluster.local"
ordinal=0
while [ "${ordinal}" -lt "${SENTINEL_REPLICAS}" ]; do
  host="${VALKEY_MASTER}-sentinel-${ordinal}.${sentinel_fqdn}:26379"
  if [ -n "${SENTINEL_HOSTS}" ]; then
    SENTINEL_HOSTS="${SENTINEL_HOSTS},${host}"
  else
    SENTINEL_HOSTS="${host}"
  fi
  ordinal=$((ordinal + 1))
done

gen_conn() {
  db="$1"
  printf 'redis+sentinel://:%s@%s/%s?mastername=%s' "${VALKEY_PASSWORD_URLENCODED}" "${SENTINEL_HOSTS}" "${db}" "${VALKEY_MASTER}"
}

cache_block=$(cat <<'EOF'
ADAPTER=redis
ENABLED=true
HOST=%s
EOF
)
queue_block=$(cat <<'EOF'
CONN_STR=%s
TYPE=redis
EOF
)
session_block=$(cat <<'EOF'
PROVIDER=redis
PROVIDER_CONFIG=%s
EOF
)

CACHE_DATA=$(printf "$cache_block" "$(gen_conn 0)")
QUEUE_DATA=$(printf "$queue_block" "$(gen_conn 1)")
SESSION_DATA=$(printf "$session_block" "$(gen_conn 0)")

current_cache="$(decode_secret_key cache 2>/dev/null || true)"
current_queue="$(decode_secret_key queue 2>/dev/null || true)"
current_session="$(decode_secret_key session 2>/dev/null || true)"

if [ -n "${current_cache}" ] && [ -n "${current_queue}" ] && [ -n "${current_session}" ]; then
  if [ "${current_cache}" = "${CACHE_DATA}" ] && [ "${current_queue}" = "${QUEUE_DATA}" ] && [ "${current_session}" = "${SESSION_DATA}" ]; then
    if kubectl -n "${NAMESPACE}" get configmap "${SENTINEL_CM}" >/dev/null 2>&1; then
      if kubectl -n "${NAMESPACE}" rollout status deployment "${DEPLOYMENT_NAME}" --timeout=5s >/dev/null 2>&1; then
        log "inline cache/queue/session config already matches desired sentinel topology and deployment is healthy; skipping"
        exit 0
      fi
      log "inline config matches desired sentinel topology but deployment is not healthy; forcing restart"
    fi
  fi
fi

tmp_patch=$(mktemp)
cat <<PATCH > "${tmp_patch}"
{
  "data": {
    "cache": "$(printf '%s' "${CACHE_DATA}" | base64 | tr -d '\n')",
    "queue": "$(printf '%s' "${QUEUE_DATA}" | base64 | tr -d '\n')",
    "session": "$(printf '%s' "${SESSION_DATA}" | base64 | tr -d '\n')"
  }
}
PATCH

log "patching secret ${SECRET_NAME}"
kubectl -n "${NAMESPACE}" patch secret "${SECRET_NAME}" --type merge --patch-file "${tmp_patch}"
rm -f "${tmp_patch}"

log "forcing Recreate rollout"
kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type=json -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}}]'
log "restarting deployment"
kubectl -n "${NAMESPACE}" rollout restart deployment "${DEPLOYMENT_NAME}"
kubectl -n "${NAMESPACE}" rollout status deployment "${DEPLOYMENT_NAME}" --timeout=600s

log "restoring RollingUpdate strategy"
kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type=json -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}]'

log "creating sentinel configmap"
kubectl -n "${NAMESPACE}" create configmap "${SENTINEL_CM}" \
  --from-literal=hosts="${SENTINEL_HOSTS}" \
  --dry-run=client -o yaml \
  | kubectl -n "${NAMESPACE}" apply -f -
log "cache switch complete"
