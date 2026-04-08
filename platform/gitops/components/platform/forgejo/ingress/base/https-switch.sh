#!/bin/sh
set -euo pipefail

SCRIPT_NAME="forgejo-https-switch"
NAMESPACE="${NAMESPACE:-forgejo}"
SENTINEL="${SCRIPT_NAME}-complete"
FORGEJO_SECRET="${FORGEJO_SECRET:-forgejo-inline-config}"
DEPLOYMENT="${FORGEJO_DEPLOYMENT:-forgejo}"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

derive_forgejo_host() {
  # Prefer explicit env var, but treat placeholders as "unset" to allow safe bootstraps.
  if [ -n "${FORGEJO_HOST:-}" ]; then
    case "${FORGEJO_HOST}" in
      *placeholder.invalid|*.invalid) : ;;
      *)
        return
        ;;
    esac
  fi

  route_ns="${FORGEJO_HTTPROUTE_NAMESPACE:-forgejo}"
  route_name="${FORGEJO_HTTPROUTE_NAME:-forgejo}"

  log "deriving host from HTTPRoute/${route_name}"
  attempts=0
  while [ "${attempts}" -lt 60 ]; do
    host="$(kubectl -n "${route_ns}" get httproute "${route_name}" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)"
    if [ -n "${host}" ]; then
      case "${host}" in
        *placeholder.invalid|*.invalid) : ;;
        *)
          FORGEJO_HOST="${host}"
          export FORGEJO_HOST
          return
          ;;
      esac
    fi
    attempts=$((attempts + 1))
    sleep 5
  done

  log "unable to derive FORGEJO_HOST from HTTPRoute/${route_name} (still placeholder?)"
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  log "python3 missing from bootstrap tools image; add it to shared/images/bootstrap-tools/Dockerfile"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq missing from bootstrap tools image; add it to shared/images/bootstrap-tools/Dockerfile"
  exit 1
fi

if kubectl -n "${NAMESPACE}" get configmap "${SENTINEL}" >/dev/null 2>&1; then
  log "sentinel ${SENTINEL} already present; skipping"
  exit 0
fi

derive_forgejo_host

current_server=$(kubectl -n "${NAMESPACE}" get secret "${FORGEJO_SECRET}" -o jsonpath='{.data.server}' | base64 -d)
desired_protocol="PROTOCOL=http"
desired_root="ROOT_URL=https://${FORGEJO_HOST}/"
if echo "${current_server}" | grep -q "${desired_root}" && echo "${current_server}" | grep -q "${desired_protocol}"; then
  log "Forgejo already configured for HTTPS; creating sentinel"
  kubectl -n "${NAMESPACE}" create configmap "${SENTINEL}" --from-literal=host="${FORGEJO_HOST}"
  exit 0
fi

cat <<'PY' > /tmp/render_patch.py
import base64
import json
import os
host = os.environ['FORGEJO_HOST']
server_block = f"""APP_DATA_PATH=/data\nDISABLE_SSH=true\nDOMAIN={host}\nENABLE_PPROF=false\nHTTP_PORT=3000\nLANDING_PAGE=explore\nLFS_START_SERVER=true\nPROTOCOL=http\nROOT_URL=https://{host}/\nSSH_DOMAIN={host}\nSSH_LISTEN_PORT=2222\nSSH_PORT=22\nSTART_SSH_SERVER=true\n"""
security_block = "COOKIE_SECURE=true\nINSTALL_LOCK=true\nMIN_PASSWORD_LENGTH=12\n"
print(json.dumps({
    "data": {
        "server": base64.b64encode(server_block.encode()).decode(),
        "security": base64.b64encode(security_block.encode()).decode(),
    }
}))
PY
patch=$(FORGEJO_HOST="${FORGEJO_HOST}" python3 /tmp/render_patch.py)

echo "${patch}" > /tmp/patch.json
log "patching secret ${FORGEJO_SECRET}"
kubectl -n "${NAMESPACE}" patch secret "${FORGEJO_SECRET}" --type merge --patch-file /tmp/patch.json

original_strategy="$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o json | jq -c '.spec.strategy')"
if [ -z "${original_strategy}" ] || [ "${original_strategy}" = "null" ]; then
  log "unable to read deployment strategy (missing jq output)"
  exit 1
fi

original_type="$(printf '%s' "${original_strategy}" | jq -r '.type // empty')"
if [ "${original_type}" != "Recreate" ]; then
  log "forcing Recreate rollout (avoid LevelDB queue lock during overlap)"
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=json -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}}]'
fi

log "restarting deployment/${DEPLOYMENT}"
kubectl -n "${NAMESPACE}" rollout restart deployment "${DEPLOYMENT}"
kubectl -n "${NAMESPACE}" rollout status deployment "${DEPLOYMENT}" --timeout=300s

if [ "${original_type}" != "Recreate" ]; then
  log "restoring original deployment strategy"
  restore_patch="$(printf '%s' "${original_strategy}" | jq -c '{op:"replace",path:"/spec/strategy",value:.} | [.]')"
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=json -p "${restore_patch}"
fi

log "creating sentinel"
kubectl -n "${NAMESPACE}" create configmap "${SENTINEL}" --from-literal=host="${FORGEJO_HOST}"
