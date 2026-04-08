#!/usr/bin/env bash
set -euo pipefail

# Non-interactive Argo CD token fetcher using Keycloak password grant.
# Usage:
#   KEYCLOAK_USERNAME=... KEYCLOAK_PASSWORD=... ./shared/scripts/argocd-token.sh
# Optional overrides:
#   KEYCLOAK_HOST (default: from DeploymentConfig)
#   KEYCLOAK_REALM (default: deploykube-admin)
#   KEYCLOAK_CLIENT_ID (default: argocd)
#   ARGOCD_SERVER (default: from DeploymentConfig)
#   ARGOCD_CRT (default: from DeploymentConfig trustRoots, or shared/certs/deploykube-root-ca.crt)
# The script prints an export line for ARGOCD_AUTH_TOKEN and runs a sample `argocd app list` to verify.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYKUBE_DEPLOYMENT_ID=${DEPLOYKUBE_DEPLOYMENT_ID:-mac-orbstack}
DEPLOYKUBE_CONFIG_FILE=${DEPLOYKUBE_CONFIG_FILE:-${REPO_ROOT}/platform/gitops/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/config.yaml}

resolve_repo_path() {
  local path="$1"
  if [[ -z "${path}" ]]; then
    return 0
  fi
  if [[ "${path}" == /* ]]; then
    printf '%s' "${path}"
    return 0
  fi
  printf '%s/%s' "${REPO_ROOT}" "${path}"
}

load_deployment_defaults() {
  if [[ -n "${KEYCLOAK_HOST:-}" && -n "${ARGOCD_SERVER:-}" ]]; then
    return 0
  fi
  if ! command -v yq >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f "${DEPLOYKUBE_CONFIG_FILE}" ]]; then
    return 0
  fi

  local host_keycloak host_argocd ca_path
  host_keycloak="$(yq -r '.spec.dns.hostnames.keycloak // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"
  host_argocd="$(yq -r '.spec.dns.hostnames.argocd // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"
  ca_path="$(yq -r '.spec.trustRoots.stepCaRootCertPath // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"

  if [[ -z "${KEYCLOAK_HOST:-}" && -n "${host_keycloak}" ]]; then
    KEYCLOAK_HOST="${host_keycloak}"
  fi
  if [[ -z "${ARGOCD_SERVER:-}" && -n "${host_argocd}" ]]; then
    ARGOCD_SERVER="${host_argocd}"
  fi
  if [[ -n "${ca_path}" ]]; then
    if [[ -z "${KEYCLOAK_CACERT:-}" ]]; then
      KEYCLOAK_CACERT="$(resolve_repo_path "${ca_path}")"
    fi
    if [[ -z "${ARGOCD_CRT:-}" ]]; then
      ARGOCD_CRT="$(resolve_repo_path "${ca_path}")"
    fi
  fi
}

KEYCLOAK_HOST=${KEYCLOAK_HOST:-}
KEYCLOAK_REALM=${KEYCLOAK_REALM:-deploykube-admin}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID:-argocd}
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET:-}
KEYCLOAK_USERNAME=${KEYCLOAK_USERNAME:-argocd-automation}
KEYCLOAK_VAULT_PATH=${KEYCLOAK_VAULT_PATH:-secret/keycloak/argocd-automation-user}
KEYCLOAK_CLIENT_VAULT_PATH=${KEYCLOAK_CLIENT_VAULT_PATH:-secret/keycloak/argocd-client}
KEYCLOAK_SCOPE=${KEYCLOAK_SCOPE:-openid profile email roles}
KEYCLOAK_CACERT=${KEYCLOAK_CACERT:-}
ARGOCD_SERVER=${ARGOCD_SERVER:-}
ARGOCD_CRT=${ARGOCD_CRT:-}
ARGOCD_SMOKE_CHECK=${ARGOCD_SMOKE_CHECK:-true}
ARGOCD_PORT_FORWARD=${ARGOCD_PORT_FORWARD:-false}
ARGOCD_PORT_FORWARD_NAMESPACE=${ARGOCD_PORT_FORWARD_NAMESPACE:-argocd}

load_deployment_defaults

KEYCLOAK_CACERT=${KEYCLOAK_CACERT:-$(resolve_repo_path 'shared/certs/deploykube-root-ca.crt')}
ARGOCD_CRT=${ARGOCD_CRT:-$(resolve_repo_path 'shared/certs/deploykube-root-ca.crt')}

: "${KEYCLOAK_HOST:?KEYCLOAK_HOST required (or set DEPLOYKUBE_DEPLOYMENT_ID/DEPLOYKUBE_CONFIG_FILE to load from DeploymentConfig)}"
: "${ARGOCD_SERVER:?ARGOCD_SERVER required (or set DEPLOYKUBE_DEPLOYMENT_ID/DEPLOYKUBE_CONFIG_FILE to load from DeploymentConfig)}"

if [[ -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  if command -v vault >/dev/null 2>&1 && [[ -n "${KEYCLOAK_VAULT_ADDR:-}" ]]; then
    echo "[argocd-token] fetching password from Vault path ${KEYCLOAK_VAULT_PATH}" >&2
    KEYCLOAK_PASSWORD=$(VAULT_ADDR="${KEYCLOAK_VAULT_ADDR}" vault kv get -field=password "${KEYCLOAK_VAULT_PATH}")
    KEYCLOAK_USERNAME=${KEYCLOAK_USERNAME:-$(VAULT_ADDR="${KEYCLOAK_VAULT_ADDR}" vault kv get -field=username "${KEYCLOAK_VAULT_PATH}")}
  else
    echo "[argocd-token] KEYCLOAK_PASSWORD required (or set KEYCLOAK_VAULT_ADDR + install vault CLI)" >&2
    exit 1
  fi
fi

if [[ -z "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
  if command -v vault >/dev/null 2>&1 && [[ -n "${KEYCLOAK_VAULT_ADDR:-}" ]]; then
    echo "[argocd-token] fetching client secret from Vault path ${KEYCLOAK_CLIENT_VAULT_PATH}" >&2
    KEYCLOAK_CLIENT_SECRET=$(VAULT_ADDR="${KEYCLOAK_VAULT_ADDR}" vault kv get -field=clientSecret "${KEYCLOAK_CLIENT_VAULT_PATH}")
  fi
fi

: "${KEYCLOAK_USERNAME:?KEYCLOAK_USERNAME required}"
: "${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD required}"

TOKEN_ENDPOINT="https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
CLIENT_SECRET_ARGS=()
if [[ -n "${KEYCLOAK_CLIENT_SECRET}" ]]; then
  CLIENT_SECRET_ARGS=(--data-urlencode "client_secret=${KEYCLOAK_CLIENT_SECRET}")
fi

CURL_CACERT_ARGS=()
if [[ -n "${KEYCLOAK_CACERT:-}" && -f "${KEYCLOAK_CACERT}" ]]; then
  CURL_CACERT_ARGS=(--cacert "${KEYCLOAK_CACERT}")
fi

echo "[argocd-token] requesting Keycloak access token via password grant..." >&2
ACCESS_TOKEN=$(curl "${CURL_CACERT_ARGS[@]}" -sSf -X POST "${TOKEN_ENDPOINT}" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}" \
  "${CLIENT_SECRET_ARGS[@]}" \
  --data-urlencode "username=${KEYCLOAK_USERNAME}" \
  --data-urlencode "password=${KEYCLOAK_PASSWORD}" \
  --data-urlencode "scope=${KEYCLOAK_SCOPE}" | jq -r '.id_token // .access_token')

if [[ -z "${ACCESS_TOKEN}" || "${ACCESS_TOKEN}" == "null" ]]; then
  echo "[argocd-token] failed to obtain access token" >&2
  exit 1
fi

echo "export ARGOCD_AUTH_TOKEN=${ACCESS_TOKEN}"

if command -v argocd >/dev/null 2>&1; then
  if [[ "${ARGOCD_SMOKE_CHECK}" == "true" ]]; then
    echo "[argocd-token] running smoke check: argocd app list" >&2
    if [[ "${ARGOCD_PORT_FORWARD}" == "true" ]]; then
      ARGOCD_AUTH_TOKEN=${ACCESS_TOKEN} argocd app list \
        --grpc-web \
        --port-forward \
        --port-forward-namespace "${ARGOCD_PORT_FORWARD_NAMESPACE}" \
        --plaintext \
        || { echo "[argocd-token] smoke check failed" >&2; exit 1; }
    else
      ARGOCD_AUTH_TOKEN=${ACCESS_TOKEN} argocd app list \
        --grpc-web \
        --server "${ARGOCD_SERVER}" \
        --server-crt "${ARGOCD_CRT}" \
        --plaintext=false \
        || { echo "[argocd-token] smoke check failed" >&2; exit 1; }
    fi
  fi
fi
