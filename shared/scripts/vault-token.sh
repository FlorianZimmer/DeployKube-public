#!/usr/bin/env bash
set -euo pipefail

# Non-interactive Vault token helper using Keycloak password grant + JWT auth.
# Usage:
#   KEYCLOAK_PASSWORD=... ./shared/scripts/vault-token.sh
#   (or set KEYCLOAK_VAULT_ADDR to auto-fetch the password/client secret from Vault)
# Defaults are derived from DeploymentConfig (or can be overridden explicitly via env vars).

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
  if [[ -n "${KEYCLOAK_HOST:-}" && -n "${VAULT_ADDR:-}" ]]; then
    return 0
  fi
  if ! command -v yq >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f "${DEPLOYKUBE_CONFIG_FILE}" ]]; then
    return 0
  fi

  local host_keycloak host_vault ca_path
  host_keycloak="$(yq -r '.spec.dns.hostnames.keycloak // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"
  host_vault="$(yq -r '.spec.dns.hostnames.vault // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"
  ca_path="$(yq -r '.spec.trustRoots.stepCaRootCertPath // ""' "${DEPLOYKUBE_CONFIG_FILE}" 2>/dev/null || true)"

  if [[ -z "${KEYCLOAK_HOST:-}" && -n "${host_keycloak}" ]]; then
    KEYCLOAK_HOST="${host_keycloak}"
  fi
  if [[ -z "${VAULT_ADDR:-}" && -n "${host_vault}" ]]; then
    VAULT_ADDR="https://${host_vault}"
  fi
  if [[ -n "${ca_path}" ]]; then
    if [[ -z "${KEYCLOAK_CACERT:-}" ]]; then
      KEYCLOAK_CACERT="$(resolve_repo_path "${ca_path}")"
    fi
    if [[ -z "${VAULT_CACERT:-}" ]]; then
      VAULT_CACERT="$(resolve_repo_path "${ca_path}")"
    fi
  fi
}

KEYCLOAK_HOST=${KEYCLOAK_HOST:-}
KEYCLOAK_REALM=${KEYCLOAK_REALM:-deploykube-admin}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID:-vault-cli}
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET:-}
KEYCLOAK_USERNAME=${KEYCLOAK_USERNAME:-vault-automation}
KEYCLOAK_SCOPE=${KEYCLOAK_SCOPE:-openid profile email roles}
KEYCLOAK_VAULT_PATH=${KEYCLOAK_VAULT_PATH:-secret/keycloak/vault-automation-user}
KEYCLOAK_CLIENT_VAULT_PATH=${KEYCLOAK_CLIENT_VAULT_PATH:-secret/keycloak/vault-client}
KEYCLOAK_CACERT=${KEYCLOAK_CACERT:-}

VAULT_ADDR=${VAULT_ADDR:-}
VAULT_CACERT=${VAULT_CACERT:-}
VAULT_JWT_MOUNT=${VAULT_JWT_MOUNT:-jwt}
VAULT_JWT_ROLE=${VAULT_JWT_ROLE:-vault-automation}

load_deployment_defaults

KEYCLOAK_CACERT=${KEYCLOAK_CACERT:-$(resolve_repo_path 'shared/certs/deploykube-root-ca.crt')}
VAULT_CACERT=${VAULT_CACERT:-$(resolve_repo_path 'shared/certs/deploykube-root-ca.crt')}

: "${KEYCLOAK_HOST:?KEYCLOAK_HOST required (or set DEPLOYKUBE_DEPLOYMENT_ID/DEPLOYKUBE_CONFIG_FILE to load from DeploymentConfig)}"
: "${VAULT_ADDR:?VAULT_ADDR required (or set DEPLOYKUBE_DEPLOYMENT_ID/DEPLOYKUBE_CONFIG_FILE to load from DeploymentConfig)}"

if [[ -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  if command -v vault >/dev/null 2>&1 && [[ -n "${KEYCLOAK_VAULT_ADDR:-}" ]]; then
    echo "[vault-token] fetching automation password from Vault path ${KEYCLOAK_VAULT_PATH}" >&2
    KEYCLOAK_PASSWORD=$(VAULT_ADDR="${KEYCLOAK_VAULT_ADDR}" vault kv get -field=password "${KEYCLOAK_VAULT_PATH}")
    KEYCLOAK_USERNAME=${KEYCLOAK_USERNAME:-$(VAULT_ADDR="${KEYCLOAK_VAULT_ADDR}" vault kv get -field=username "${KEYCLOAK_VAULT_PATH}")}
  else
    echo "[vault-token] KEYCLOAK_PASSWORD required (or set KEYCLOAK_VAULT_ADDR + install vault CLI)" >&2
    exit 1
  fi
fi

if [[ -z "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
  if command -v vault >/dev/null 2>&1 && [[ -n "${KEYCLOAK_VAULT_ADDR:-}" ]]; then
    echo "[vault-token] fetching vault client secret from Vault path ${KEYCLOAK_CLIENT_VAULT_PATH}" >&2
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

echo "[vault-token] requesting Keycloak access token via password grant..." >&2
TOKEN_JSON_FILE="$(mktemp)"
TOKEN_HTTP="$(
  curl "${CURL_CACERT_ARGS[@]}" -sS -o "${TOKEN_JSON_FILE}" -w '%{http_code}' -X POST "${TOKEN_ENDPOINT}" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}" \
    "${CLIENT_SECRET_ARGS[@]}" \
    --data-urlencode "username=${KEYCLOAK_USERNAME}" \
    --data-urlencode "password=${KEYCLOAK_PASSWORD}" \
    --data-urlencode "scope=${KEYCLOAK_SCOPE}"
)"
if [[ "${TOKEN_HTTP}" != "200" ]]; then
  err="$(jq -r '.error // empty' "${TOKEN_JSON_FILE}" 2>/dev/null || true)"
  desc="$(jq -r '.error_description // empty' "${TOKEN_JSON_FILE}" 2>/dev/null || true)"
  rm -f "${TOKEN_JSON_FILE}"
  if [[ "${err}" == "invalid_grant" && "${desc}" == "Account is not fully set up" ]]; then
    echo "[vault-token] Keycloak rejected the password grant: ${err} (${desc})." >&2
    echo "[vault-token] Fix: run the 'keycloak-bootstrap' PostSync job (Argo app: platform-keycloak-bootstrap) or set profile fields (firstName/lastName/email) for the automation user." >&2
    exit 1
  fi
  echo "[vault-token] Keycloak token request failed (http=${TOKEN_HTTP}): ${err}${desc:+ - ${desc}}" >&2
  exit 1
fi
ACCESS_TOKEN="$(jq -r '.id_token // .access_token // empty' "${TOKEN_JSON_FILE}")"
rm -f "${TOKEN_JSON_FILE}"

if [[ -z "${ACCESS_TOKEN}" || "${ACCESS_TOKEN}" == "null" ]]; then
  echo "[vault-token] failed to obtain access token" >&2
  exit 1
fi

export VAULT_ADDR
export VAULT_CACERT

if ! command -v vault >/dev/null 2>&1; then
  echo "[vault-token] vault CLI missing; install hashicorp-vault and retry" >&2
  echo "export VAULT_TOKEN=<set once you login manually>" >&2
  exit 1
fi

echo "[vault-token] exchanging JWT for Vault token (mount=${VAULT_JWT_MOUNT}, role=${VAULT_JWT_ROLE})" >&2
LOGIN_JSON=$(vault write -format=json "auth/${VAULT_JWT_MOUNT}/login" role="${VAULT_JWT_ROLE}" jwt="${ACCESS_TOKEN}")
VAULT_TOKEN=$(echo "${LOGIN_JSON}" | jq -r '.auth.client_token // empty')

if [[ -z "${VAULT_TOKEN}" || "${VAULT_TOKEN}" == "null" ]]; then
  echo "[vault-token] login failed; response:\n${LOGIN_JSON}" >&2
  exit 1
fi

echo "export VAULT_TOKEN=${VAULT_TOKEN}"

echo "[vault-token] smoke check: vault kv get secret/bootstrap" >&2
VAULT_TOKEN="${VAULT_TOKEN}" vault kv get -field=message secret/bootstrap >/dev/null 2>&1 || \
  echo "[vault-token] warning: smoke check failed (secret/bootstrap missing?)" >&2
