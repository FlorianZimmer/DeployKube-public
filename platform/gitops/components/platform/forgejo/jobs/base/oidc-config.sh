#!/bin/sh
set -euo pipefail

SCRIPT_NAME="forgejo-oidc-config"
APP_INI="${GITEA_APP_INI:-/data/gitea/conf/app.ini}"
OIDC_NAME="${OIDC_NAME:-Keycloak}"
OIDC_PROVIDER="${OIDC_PROVIDER:-openidConnect}"
OIDC_DISCOVERY_URL="${OIDC_DISCOVERY_URL:?OIDC_DISCOVERY_URL required}"
OIDC_SCOPES="${OIDC_SCOPES:-openid profile email}"
OIDC_GROUP_CLAIM="${OIDC_GROUP_CLAIM:-realm_access.roles}"
OIDC_SECRET_DIR="${OIDC_SECRET_DIR:-/secrets/oidc}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

require_file() {
  local file="$1" attempt=0
  while [ "${attempt}" -lt "${WAIT_ATTEMPTS}" ]; do
    if [ -s "${file}" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for ${file} (${attempt}/${WAIT_ATTEMPTS})"
    sleep "${WAIT_INTERVAL}"
  done
  log "file ${file} not found or empty"
  return 1
}

fetch_auth_table() {
  local output
  output=$(gitea --config "${APP_INI}" admin auth list --vertical-bars 2>&1) || {
    printf '%s' "${output}" >&2
    return 1
  }
  printf '%s' "${output}" > /tmp/auth-list
}

get_auth_id() {
  awk -v name="${OIDC_NAME}" '
    BEGIN { capture=0; FS="|" }
    /^ID[[:space:]]+\|Name[[:space:]]+\|Type/ { capture=1; next }
    capture {
      if (NF < 3) { next }
      id=$1; name_field=$2; type_field=$3;
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name_field)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", type_field)
      if (tolower(type_field) == "oauth2" && name_field == name) {
        print id
        exit
      }
    }
  ' /tmp/auth-list
}

configure_oauth() {
  local attempt=0
  while [ "${attempt}" -lt "${WAIT_ATTEMPTS}" ]; do
    if fetch_auth_table; then
      break
    fi
    attempt=$((attempt + 1))
    log "waiting for gitea admin auth list (${attempt}/${WAIT_ATTEMPTS})"
    sleep "${WAIT_INTERVAL}"
  done
  if [ "${attempt}" -ge "${WAIT_ATTEMPTS}" ]; then
    log "unable to run gitea admin auth list"
    exit 1
  fi

  attempt=0
  while [ "${attempt}" -lt "${WAIT_ATTEMPTS}" ]; do
    local auth_id
    auth_id=$(get_auth_id || true)

    local output=""
    if [ -z "${auth_id}" ]; then
      log "creating oauth source ${OIDC_NAME}"
      output=$(
        gitea --config "${APP_INI}" admin auth add-oauth \
          --name "${OIDC_NAME}" \
          --provider "${OIDC_PROVIDER}" \
          --key "${OIDC_CLIENT_ID}" \
          --secret "${OIDC_CLIENT_SECRET}" \
          --auto-discover-url "${OIDC_DISCOVERY_URL}" \
          --scopes "${OIDC_SCOPES}" \
          --group-claim-name "${OIDC_GROUP_CLAIM}" 2>&1
      ) || {
        attempt=$((attempt + 1))
        printf '%s\n' "${output}" >&2
        log "waiting for OIDC discovery endpoint (${attempt}/${WAIT_ATTEMPTS})"
        sleep "${WAIT_INTERVAL}"
        fetch_auth_table || true
        continue
      }
    else
      log "updating oauth source ${OIDC_NAME} (id=${auth_id})"
      output=$(
        gitea --config "${APP_INI}" admin auth update-oauth \
          --id "${auth_id}" \
          --name "${OIDC_NAME}" \
          --provider "${OIDC_PROVIDER}" \
          --key "${OIDC_CLIENT_ID}" \
          --secret "${OIDC_CLIENT_SECRET}" \
          --auto-discover-url "${OIDC_DISCOVERY_URL}" \
          --scopes "${OIDC_SCOPES}" \
          --group-claim-name "${OIDC_GROUP_CLAIM}" 2>&1
      ) || {
        attempt=$((attempt + 1))
        printf '%s\n' "${output}" >&2
        log "waiting for OIDC discovery endpoint (${attempt}/${WAIT_ATTEMPTS})"
        sleep "${WAIT_INTERVAL}"
        fetch_auth_table || true
        continue
      }
    fi

    return 0
  done

  log "unable to configure oauth source ${OIDC_NAME} after ${WAIT_ATTEMPTS} attempts"
  return 1
}

main() {
  if [ -f /helpers/istio-native-exit.sh ]; then
    # shellcheck disable=SC1091
    . /helpers/istio-native-exit.sh
    trap deploykube_istio_quit_sidecar EXIT
  fi
  require_file "${APP_INI}"
  require_file "${OIDC_SECRET_DIR}/key"
  require_file "${OIDC_SECRET_DIR}/secret"
  if [ -n "${SSL_CERT_FILE:-}" ]; then
    require_file "${SSL_CERT_FILE}"
  fi
  OIDC_CLIENT_ID=$(cat "${OIDC_SECRET_DIR}/key")
  OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_DIR}/secret")
  if [ -z "${OIDC_CLIENT_ID}" ] || [ -z "${OIDC_CLIENT_SECRET}" ]; then
    log "client credentials missing"
    exit 1
  fi
  configure_oauth
  log "Forgejo OIDC source ${OIDC_NAME} configured"
}

main "$@"
