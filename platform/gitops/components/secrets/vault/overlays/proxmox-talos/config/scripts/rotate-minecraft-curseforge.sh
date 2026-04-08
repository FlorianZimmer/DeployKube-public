#!/bin/sh
set -euo pipefail

ISTIO_HELPER="/helpers/istio-native-exit.sh"
if [ ! -f "$ISTIO_HELPER" ]; then
  echo "missing istio-native-exit helper" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$ISTIO_HELPER"

SCRIPT_NAME="minecraft-monifactory-curseforge-rotate"
NAMESPACE="${NAMESPACE:-vault-system}"
SENTINEL_CM="${SCRIPT_NAME}-complete"
SEED_SECRET_NAME="${SEED_SECRET_NAME:-minecraft-monifactory-seed}"
SEED_SECRET_KEY="${SEED_SECRET_KEY:-curseforgeApiKey}"
VAULT_PATH="${VAULT_PATH:-secret/apps/minecraft-monifactory}"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

is_placeholder() {
  case "$1" in
    ""|REPLACE_*|PLACEHOLDER*|CHANGEME*|changeme*|__* )
      return 0 ;;
    * )
      return 1 ;;
  esac
}

cleanup() {
  deploykube_istio_quit_sidecar
}

trap cleanup EXIT INT TERM

if kubectl -n "${NAMESPACE}" get configmap "${SENTINEL_CM}" >/dev/null 2>&1; then
  log "sentinel ${SENTINEL_CM} found; skipping"
  exit 0
fi

seed_key_b64="$(kubectl -n "${NAMESPACE}" get secret "${SEED_SECRET_NAME}" -o jsonpath="{.data.${SEED_SECRET_KEY}}" 2>/dev/null || true)"
if [ -z "${seed_key_b64}" ]; then
  log "seed secret ${SEED_SECRET_NAME} missing field ${SEED_SECRET_KEY}"
  exit 1
fi

seed_key="$(printf '%s' "${seed_key_b64}" | base64 -d)"
if is_placeholder "${seed_key}"; then
  log "seed key is placeholder; refusing to rotate"
  exit 1
fi

root_token_b64="$(kubectl -n "${NAMESPACE}" get secret vault-init -o jsonpath='{.data.root-token}' 2>/dev/null || true)"
if [ -z "${root_token_b64}" ]; then
  log "vault-init secret missing root-token"
  exit 1
fi

root_token="$(printf '%s' "${root_token_b64}" | base64 -d)"
if is_placeholder "${root_token}"; then
  log "vault root token looks like placeholder; refusing to rotate"
  exit 1
fi

log "waiting for vault pod"
for _ in $(seq 1 60); do
  pod="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    phase="$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "${phase}" = "Running" ]; then
      break
    fi
  fi
  pod=""
  sleep 5
  log "still waiting for vault pod"
done

if [ -z "${pod}" ]; then
  log "vault pod not found"
  exit 1
fi

log "rotating CurseForge API key in ${VAULT_PATH}"
kubectl -n "${NAMESPACE}" exec "${pod}" -- env \
  VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="${root_token}" \
  vault kv patch "${VAULT_PATH}" "curseforgeApiKey=${seed_key}" >/dev/null

kubectl -n "${NAMESPACE}" create configmap "${SENTINEL_CM}" \
  --from-literal=completedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=path="${VAULT_PATH}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "rotation complete"
