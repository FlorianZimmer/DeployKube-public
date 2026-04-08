#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./shared/scripts/generate-oidc-kubeconfig.sh --from-context <kubectl-context> --out <path> [--from-kubeconfig <path>] [--issuer-url <url>] [--grant-type <type>] [--token-cache-storage <storage>] [--force-refresh]

Defaults:
  --issuer-url: derived from DeploymentConfig (keycloak hostname + realm)
  client id:    kubernetes-api
  listen port:  18000
  grant type:   authcode
  token cache:  disk

Notes:
  - Requires the kubectl exec plugin: `kubectl oidc-login` (install via krew).
  - Keycloak redirect URIs are intentionally fixed to port 18000 for tighter security.
  - For remote/headless workflows where a localhost callback is inconvenient, consider `--grant-type=device-code`.
  - The generated kubeconfig sets `--skip-open-browser` so the auth URL is printed to the terminal.
EOF
}

require() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${cmd}" >&2
    exit 1
  fi
}

FROM_CONTEXT=""
OUT=""
FROM_KUBECONFIG=""
ISSUER_URL=""
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-mac-orbstack}"
DEPLOYKUBE_CONFIG_FILE="${DEPLOYKUBE_CONFIG_FILE:-${REPO_ROOT}/platform/gitops/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/config.yaml}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-deploykube-admin}"
CLIENT_ID="kubernetes-api"
GRANT_TYPE="authcode"
TOKEN_CACHE_STORAGE="disk"
FORCE_REFRESH="false"
LISTEN_ADDRESS="127.0.0.1"
LISTEN_PORT="18000"
AUTHENTICATION_TIMEOUT_SEC="${AUTHENTICATION_TIMEOUT_SEC:-600}"
OIDC_CA_FILE="${REPO_ROOT}/shared/certs/deploykube-root-ca.crt"

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --from-context)
      FROM_CONTEXT="${2:-}"; shift 2;;
    --out)
      OUT="${2:-}"; shift 2;;
    --from-kubeconfig)
      FROM_KUBECONFIG="${2:-}"; shift 2;;
    --issuer-url)
      ISSUER_URL="${2:-}"; shift 2;;
    --grant-type)
      GRANT_TYPE="${2:-}"; shift 2;;
    --token-cache-storage)
      TOKEN_CACHE_STORAGE="${2:-}"; shift 2;;
    --force-refresh)
      FORCE_REFRESH="true"; shift 1;;
    --client-id)
      CLIENT_ID="${2:-}"; shift 2;;
    --listen-address)
      LISTEN_ADDRESS="${2:-}"; shift 2;;
    --listen-port)
      LISTEN_PORT="${2:-}"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1;;
  esac
done

if [[ -z "${FROM_CONTEXT}" || -z "${OUT}" ]]; then
  usage
  exit 1
fi

require kubectl
require jq

case "${GRANT_TYPE}" in
  authcode|authcode-keyboard|password|device-code|client-credentials)
    ;;
  *)
    echo "error: unsupported --grant-type '${GRANT_TYPE}' (expected one of: authcode, authcode-keyboard, password, device-code, client-credentials)" >&2
    exit 1
    ;;
esac

case "${TOKEN_CACHE_STORAGE}" in
  disk|keyring|none)
    ;;
  *)
    echo "error: unsupported --token-cache-storage '${TOKEN_CACHE_STORAGE}' (expected one of: disk, keyring, none)" >&2
    exit 1
    ;;
esac

if [[ -z "${ISSUER_URL}" ]]; then
  if command -v yq >/dev/null 2>&1 && [[ -f "${DEPLOYKUBE_CONFIG_FILE}" ]]; then
    keycloak_host="$(yq -r '.spec.dns.hostnames.keycloak // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"
    if [[ -n "${keycloak_host}" ]]; then
      ISSUER_URL="https://${keycloak_host}/realms/${KEYCLOAK_REALM}"
    fi
  fi
fi

: "${ISSUER_URL:?ISSUER_URL required (set --issuer-url or set DEPLOYKUBE_DEPLOYMENT_ID/DEPLOYKUBE_CONFIG_FILE)}"

if [[ ! -f "${OIDC_CA_FILE}" ]]; then
  echo "error: OIDC CA file not found at ${OIDC_CA_FILE}" >&2
  echo "hint: ensure shared/certs/deploykube-root-ca.crt exists (repo-tracked)" >&2
  exit 1
fi

kubectl_cfg_args=()
if [[ -n "${FROM_KUBECONFIG}" ]]; then
  kubectl_cfg_args+=(--kubeconfig "${FROM_KUBECONFIG}")
fi

raw_json="$(kubectl "${kubectl_cfg_args[@]}" config view --raw -o json --context "${FROM_CONTEXT}")"
cluster_name="$(printf '%s' "${raw_json}" | jq -r '.contexts[0].context.cluster')"
cluster_server="$(printf '%s' "${raw_json}" | jq -r --arg cluster_name "${cluster_name}" '.clusters[] | select(.name == $cluster_name).cluster.server')"
cluster_ca_data="$(printf '%s' "${raw_json}" | jq -r --arg cluster_name "${cluster_name}" '.clusters[] | select(.name == $cluster_name).cluster["certificate-authority-data"]')"

if [[ -z "${cluster_server}" || "${cluster_server}" == "null" ]]; then
  echo "error: failed to read cluster server for context ${FROM_CONTEXT}" >&2
  exit 1
fi

if [[ -z "${cluster_ca_data}" || "${cluster_ca_data}" == "null" ]]; then
  echo "error: failed to read cluster certificate-authority-data for context ${FROM_CONTEXT}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT}")"

exec_args=(
  "oidc-login"
  "get-token"
  "--oidc-issuer-url=${ISSUER_URL}"
  "--oidc-client-id=${CLIENT_ID}"
  "--certificate-authority=${OIDC_CA_FILE}"
  "--grant-type=${GRANT_TYPE}"
  "--token-cache-storage=${TOKEN_CACHE_STORAGE}"
)

if [[ "${FORCE_REFRESH}" == "true" ]]; then
  exec_args+=("--force-refresh")
fi

case "${GRANT_TYPE}" in
  authcode|authcode-keyboard)
    exec_args+=(
      "--authentication-timeout-sec=${AUTHENTICATION_TIMEOUT_SEC}"
      # kubelogin's local callback handler is served at "/" (not "/callback").
      "--oidc-redirect-url=http://${LISTEN_ADDRESS}:${LISTEN_PORT}/"
      "--listen-address=${LISTEN_ADDRESS}:${LISTEN_PORT}"
      "--skip-open-browser"
    )
    ;;
  device-code|password|client-credentials)
    # No localhost callback required.
    ;;
esac

cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${cluster_name}
  cluster:
    server: ${cluster_server}
    certificate-authority-data: ${cluster_ca_data}
users:
- name: oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      interactiveMode: IfAvailable
      command: kubectl
      args:
$(printf '      - %s\n' "${exec_args[@]}")
contexts:
- name: oidc@${cluster_name}
  context:
    cluster: ${cluster_name}
    user: oidc
current-context: oidc@${cluster_name}
EOF

echo "wrote ${OUT}"
echo "next:"
echo "  export KUBECONFIG='${OUT}'"
