#!/usr/bin/env bash
set -euo pipefail

ISTIO_HELPER="/helpers/istio-native-exit.sh"
[ -f "${ISTIO_HELPER}" ] || { echo "missing istio-native-exit helper" >&2; exit 1; }
. "${ISTIO_HELPER}"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_API="${KEYCLOAK_INTERNAL_URL:-http://keycloak.keycloak.svc.cluster.local:8080}"
SNAPSHOT_NAME="${DEPLOYKUBE_CONFIG_SNAPSHOT_NAME:-deploykube-deployment-config}"
SNAPSHOT_KEY="${DEPLOYKUBE_CONFIG_SNAPSHOT_KEY:-deployment-config.yaml}"
STATUS_CM="${STATUS_CONFIGMAP:-keycloak-iam-sync-status}"
UPSTREAM_ALIAS_DEFAULT="${KEYCLOAK_IAM_UPSTREAM_ALIAS:-upstream}"
TMP_DIR="$(mktemp -d)"
DEPLOYMENT_CONFIG_FILE="${TMP_DIR}/deployment-config.yaml"
HEALTH_CA_CERT_FILE=""
HEALTH_HTTP_REASON=""

cleanup() {
  rm -rf "${TMP_DIR}"
  deploykube_istio_quit_sidecar >/dev/null 2>&1 || true
}
trap cleanup EXIT

status_get() {
  local key="$1"
  kubectl -n "${NAMESPACE}" get configmap "${STATUS_CM}" -o jsonpath="{.data.${key}}" 2>/dev/null || true
}

status_set() {
  local key="$1"
  local value="$2"
  local patch
  patch="$(jq -n --arg k "${key}" --arg v "${value}" '{data:{($k):$v}}')"
  kubectl -n "${NAMESPACE}" patch configmap "${STATUS_CM}" --type merge -p "${patch}" >/dev/null 2>&1 || \
    kubectl -n "${NAMESPACE}" create configmap "${STATUS_CM}" --from-literal "${key}=${value}" >/dev/null
}

status_write_common() {
  status_set "lastCheckedAt" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status_set "mode" "${IAM_MODE}"
  status_set "upstream.type" "${UPSTREAM_TYPE}"
  status_set "realm.primary" "${PRIMARY_REALM}"
  status_set "realm.targets" "${REALM_TARGETS_CSV}"
}

load_snapshot() {
  local cm_json raw
  cm_json="$(kubectl -n "${NAMESPACE}" get configmap "${SNAPSHOT_NAME}" -o json)"
  raw="$(echo "${cm_json}" | jq -r --arg key "${SNAPSHOT_KEY}" '.data[$key] // ""')"
  if [[ -z "${raw}" ]]; then
    log "snapshot ${NAMESPACE}/${SNAPSHOT_NAME} missing key ${SNAPSHOT_KEY}"
    exit 0
  fi
  printf '%s\n' "${raw}" > "${DEPLOYMENT_CONFIG_FILE}"
}

cfg() {
  local expr="$1"
  yq -r "${expr} // \"\"" "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true
}

cfg_int_default() {
  local expr="$1"
  local def="$2"
  local value
  value="$(yq -r "${expr} // ${def}" "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)"
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    value="${def}"
  fi
  echo "${value}"
}

secret_value_or_empty() {
  local namespace="$1"
  local name="$2"
  local key="$3"
  kubectl -n "${namespace}" get secret "${name}" -o json 2>/dev/null | jq -r --arg k "${key}" '.data[$k] // empty' | base64 -d 2>/dev/null || true
}

resolve_secret_ref_value() {
  local secret_name="$1"
  local secret_key="$2"
  local secret_ns="$3"
  local secret_json encoded
  [[ -n "${secret_name}" && -n "${secret_key}" ]] || return 1
  [[ -n "${secret_ns}" ]] || secret_ns="${NAMESPACE}"
  secret_json="$(kubectl -n "${secret_ns}" get secret "${secret_name}" -o json 2>/dev/null || true)"
  [[ -n "${secret_json}" ]] || return 1
  encoded="$(echo "${secret_json}" | jq -r --arg k "${secret_key}" '.data[$k] // empty')"
  [[ -n "${encoded}" ]] || return 1
  printf '%s' "${encoded}" | base64 -d
}

keycloak_token() {
  local secret_json username password
  secret_json="$(kubectl -n "${NAMESPACE}" get secret keycloak-admin-credentials -o json)"
  username="$(echo "${secret_json}" | jq -r '.data.username // ""' | base64 -d)"
  password="$(echo "${secret_json}" | jq -r '.data.password // ""' | base64 -d)"
  [[ -n "${username}" && -n "${password}" ]] || return 1

  curl -sSf -X POST "${KEYCLOAK_API%/}/realms/master/protocol/openid-connect/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" | jq -r '.access_token'
}

browser_redirector_execution_id() {
  local realm="$1"
  local token="$2"
  local executions_json execution_id
  executions_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions")"
  execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector" and .level==0) | .id' | head -n 1)"
  if [[ -z "${execution_id}" ]]; then
    execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector") | .id' | head -n 1)"
  fi
  [[ -n "${execution_id}" ]] || return 1
  printf '%s' "${execution_id}"
}

ensure_browser_redirector_config() {
  local realm="$1"
  local upstream_alias="$2"
  local token="$3"
  local executions_json execution_id config_id config_json current_provider config_alias payload
  executions_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions")"
  execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector" and .level==0) | .id' | head -n 1)"
  if [[ -z "${execution_id}" ]]; then
    execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector") | .id' | head -n 1)"
  fi
  [[ -n "${execution_id}" ]] || return 1

  config_id="$(echo "${executions_json}" | jq -r --arg id "${execution_id}" '.[] | select(.id==$id) | .authenticationConfig // empty')"
  if [[ -n "${config_id}" ]]; then
    config_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
      "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/config/${config_id}")"
    current_provider="$(echo "${config_json}" | jq -r '.config.defaultProvider // empty')"
    if [[ "${current_provider}" != "${upstream_alias}" ]]; then
      config_alias="$(echo "${config_json}" | jq -r '.alias // "deploykube-upstream-redirect"')"
      payload="$(jq -n \
        --arg id "${config_id}" \
        --arg alias "${config_alias}" \
        --arg provider "${upstream_alias}" \
        '{id:$id,alias:$alias,config:{defaultProvider:$provider}}')"
      curl -sSf -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
        --data "${payload}" \
        "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/config/${config_id}" >/dev/null
    fi
  else
    payload="$(jq -n --arg alias "deploykube-upstream-redirect" --arg provider "${upstream_alias}" \
      '{alias:$alias,config:{defaultProvider:$provider}}')"
    curl -sSf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      --data "${payload}" \
      "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/executions/${execution_id}/config" >/dev/null
  fi
}

set_browser_redirector_requirement() {
  local realm="$1"
  local requirement="$2"
  local token="$3"
  local executions_json execution_id current_requirement payload
  executions_json="$(curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions")"
  execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector" and .level==0) | .id' | head -n 1)"
  if [[ -z "${execution_id}" ]]; then
    execution_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="identity-provider-redirector") | .id' | head -n 1)"
  fi
  [[ -n "${execution_id}" ]] || return 1
  current_requirement="$(echo "${executions_json}" | jq -r --arg id "${execution_id}" '.[] | select(.id==$id) | .requirement // empty')"

  if [[ "${current_requirement}" == "${requirement}" ]]; then
    return 0
  fi

  payload="$(jq -n --arg id "${execution_id}" --arg req "${requirement}" '{id:$id,requirement:$req}')"
  curl -sSf -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    --data "${payload}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/authentication/flows/browser/executions" >/dev/null
}

parse_host_port() {
  local input="$1"
  local host port

  if [[ "${input}" =~ ^https?:// ]]; then
    host="${input#*://}"
  else
    host="${input}"
  fi
  host="${host%%/*}"
  if [[ "${host}" == *:* ]]; then
    port="${host##*:}"
    host="${host%%:*}"
  else
    port=""
  fi

  printf '%s %s\n' "${host}" "${port}"
}

health_http() {
  local url="$1"
  local timeout_s="$2"
  local -a curl_args
  local cert_value=""
  HEALTH_HTTP_REASON="http-failed"
  curl_args=(-fsS --max-time "${timeout_s}")

  if [[ "${url}" == https://* ]]; then
    if [[ -n "${HEALTH_CA_CERT_FILE}" && -f "${HEALTH_CA_CERT_FILE}" ]]; then
      curl_args+=(--cacert "${HEALTH_CA_CERT_FILE}")
    else
      if [[ -n "${HEALTH_CA_SECRET_NAME}" || -n "${HEALTH_CA_SECRET_KEY}" ]]; then
        cert_value="$(resolve_secret_ref_value "${HEALTH_CA_SECRET_NAME}" "${HEALTH_CA_SECRET_KEY}" "${HEALTH_CA_SECRET_NS}" || true)"
        if [[ -z "${cert_value}" ]]; then
          status_set "health.tls" "ca-ref-missing"
          HEALTH_HTTP_REASON="http-ca-ref-missing"
          return 1
        fi
      elif [[ "${UPSTREAM_TYPE}" == "oidc" && ( -n "${OIDC_CA_SECRET_NAME}" || -n "${OIDC_CA_SECRET_KEY}" ) ]]; then
        cert_value="$(resolve_secret_ref_value "${OIDC_CA_SECRET_NAME}" "${OIDC_CA_SECRET_KEY}" "${OIDC_CA_SECRET_NS}" || true)"
        if [[ -z "${cert_value}" ]]; then
          status_set "health.tls" "ca-ref-missing"
          HEALTH_HTTP_REASON="http-ca-ref-missing"
          return 1
        fi
      elif [[ "${UPSTREAM_TYPE}" == "oidc" ]]; then
        cert_value="$(secret_value_or_empty "${NAMESPACE}" "keycloak-upstream-oidc" "ca.crt")"
      fi

      if [[ -n "${cert_value}" ]]; then
        HEALTH_CA_CERT_FILE="${TMP_DIR}/health-ca.crt"
        printf '%s\n' "${cert_value}" > "${HEALTH_CA_CERT_FILE}"
        curl_args+=(--cacert "${HEALTH_CA_CERT_FILE}")
        status_set "health.tls" "custom-ca"
      else
        status_set "health.tls" "system-ca"
      fi
    fi
  fi

  curl "${curl_args[@]}" "${url}" >/dev/null
}

health_tcp() {
  local host="$1"
  local port="$2"
  local timeout_s="$3"
  timeout "${timeout_s}" bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

check_upstream_health() {
  local check_type="${HEALTH_TYPE}"

  case "${UPSTREAM_TYPE}" in
    oidc)
      if [[ -z "${HEALTH_URL}" ]]; then
        HEALTH_URL="${OIDC_ISSUER%/}/.well-known/openid-configuration"
      fi
      check_type="${check_type:-http}"
      ;;
    saml)
      if [[ -z "${HEALTH_URL}" ]]; then
        HEALTH_URL="${SAML_SSO_URL}"
      fi
      check_type="${check_type:-http}"
      ;;
    ldap)
      if [[ -z "${HEALTH_HOST}" ]]; then
        read -r HEALTH_HOST parsed_port <<<"$(parse_host_port "${LDAP_URL}")"
        if [[ -z "${HEALTH_PORT}" && -n "${parsed_port}" ]]; then
          HEALTH_PORT="${parsed_port}"
        fi
      fi
      if [[ -z "${HEALTH_PORT}" ]]; then
        HEALTH_PORT="636"
      fi
      check_type="${check_type:-tcp}"
      ;;
    scim)
      # SCIM is provisioning-only; do not gate login preference on SCIM reachability.
      status_set "health.result" "ignored"
      status_set "health.reason" "scim-does-not-gate-login"
      return 0
      ;;
    *)
      status_set "health.result" "unknown"
      status_set "health.reason" "unsupported-upstream-type"
      return 1
      ;;
  esac

  if [[ "${check_type}" == "http" ]]; then
    [[ -n "${HEALTH_URL}" ]] || return 1
    if health_http "${HEALTH_URL}" "${TIMEOUT_SECONDS}"; then
      status_set "health.result" "healthy"
      status_set "health.reason" "http-ok"
      return 0
    fi
    status_set "health.result" "unhealthy"
    status_set "health.reason" "${HEALTH_HTTP_REASON:-http-failed}"
    return 1
  fi

  if [[ "${check_type}" == "tcp" ]]; then
    [[ -n "${HEALTH_HOST}" && -n "${HEALTH_PORT}" ]] || return 1
    if health_tcp "${HEALTH_HOST}" "${HEALTH_PORT}" "${TIMEOUT_SECONDS}"; then
      status_set "health.result" "healthy"
      status_set "health.reason" "tcp-ok"
      return 0
    fi
    status_set "health.result" "unhealthy"
    status_set "health.reason" "tcp-failed"
    return 1
  fi

  status_set "health.result" "unknown"
  status_set "health.reason" "invalid-check-type"
  return 1
}

update_counters() {
  local healthy="$1"
  local prev_success prev_failure

  prev_success="$(status_get consecutiveSuccesses)"
  prev_failure="$(status_get consecutiveFailures)"
  [[ -n "${prev_success}" ]] || prev_success=0
  [[ -n "${prev_failure}" ]] || prev_failure=0

  if [[ "${healthy}" == "true" ]]; then
    CONSEC_SUCCESS=$((prev_success + 1))
    CONSEC_FAILURE=0
  else
    CONSEC_SUCCESS=0
    CONSEC_FAILURE=$((prev_failure + 1))
  fi

  status_set "consecutiveSuccesses" "${CONSEC_SUCCESS}"
  status_set "consecutiveFailures" "${CONSEC_FAILURE}"
}

apply_redirect_state_for_realm() {
  local realm="$1"
  local desired_state="$2"
  local token="$3"

  if [[ "${desired_state}" == "upstream" ]]; then
    ensure_browser_redirector_config "${realm}" "${UPSTREAM_ALIAS}" "${token}" || return 1
    set_browser_redirector_requirement "${realm}" "REQUIRED" "${token}" || return 1
    status_set "realm.${realm}.redirectState" "upstream"
    return 0
  fi

  set_browser_redirector_requirement "${realm}" "DISABLED" "${token}" || return 1
  status_set "realm.${realm}.redirectState" "local"
}

main() {
  load_snapshot

  IAM_MODE="$(cfg '.spec.iam.mode')"
  [[ -n "${IAM_MODE}" ]] || IAM_MODE="standalone"
  UPSTREAM_TYPE="$(cfg '.spec.iam.upstream.type')"
  PRIMARY_REALM="$(cfg '.spec.iam.primaryRealm')"
  [[ -n "${PRIMARY_REALM}" ]] || PRIMARY_REALM="deploykube-admin"
  mapfile -t TARGET_REALMS < <(
    {
      printf '%s\n' "${PRIMARY_REALM}"
      yq -r '.spec.iam.secondaryRealms[]?' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true
    } | awk 'NF>0 && !seen[$0]++'
  )
  if [[ "${#TARGET_REALMS[@]}" -eq 0 ]]; then
    TARGET_REALMS=("${PRIMARY_REALM}")
  fi
  REALM_TARGETS_CSV="$(IFS=,; echo "${TARGET_REALMS[*]}")"
  UPSTREAM_ALIAS="$(cfg '.spec.iam.upstream.alias')"
  [[ -n "${UPSTREAM_ALIAS}" ]] || UPSTREAM_ALIAS="${UPSTREAM_ALIAS_DEFAULT}"

  OIDC_ISSUER="$(cfg '.spec.iam.upstream.oidc.issuerUrl')"
  SAML_SSO_URL="$(cfg '.spec.iam.upstream.saml.ssoUrl')"
  LDAP_URL="$(cfg '.spec.iam.upstream.ldap.url')"

  HEALTH_TYPE="$(cfg '.spec.iam.hybrid.healthCheck.type')"
  HEALTH_URL="$(cfg '.spec.iam.hybrid.healthCheck.url')"
  HEALTH_HOST="$(cfg '.spec.iam.hybrid.healthCheck.host')"
  HEALTH_PORT="$(cfg '.spec.iam.hybrid.healthCheck.port')"
  HEALTH_CA_SECRET_NAME="$(cfg '.spec.iam.hybrid.healthCheck.caRef.secretName')"
  HEALTH_CA_SECRET_KEY="$(cfg '.spec.iam.hybrid.healthCheck.caRef.secretKey')"
  HEALTH_CA_SECRET_NS="$(cfg '.spec.iam.hybrid.healthCheck.caRef.namespace')"
  OIDC_CA_SECRET_NAME="$(cfg '.spec.iam.upstream.oidc.caRef.secretName')"
  OIDC_CA_SECRET_KEY="$(cfg '.spec.iam.upstream.oidc.caRef.secretKey')"
  OIDC_CA_SECRET_NS="$(cfg '.spec.iam.upstream.oidc.caRef.namespace')"
  TIMEOUT_SECONDS="$(cfg_int_default '.spec.iam.hybrid.healthCheck.timeoutSeconds' 5)"
  SUCCESS_THRESHOLD="$(cfg_int_default '.spec.iam.hybrid.healthCheck.successThreshold' 2)"
  FAILURE_THRESHOLD="$(cfg_int_default '.spec.iam.hybrid.healthCheck.failureThreshold' 1)"
  FAIL_OPEN="$(cfg '.spec.iam.hybrid.failOpen')"
  [[ -n "${FAIL_OPEN}" ]] || FAIL_OPEN="true"

  status_write_common

  if [[ "${IAM_MODE}" != "hybrid" ]]; then
    status_set "state" "skipped"
    status_set "reason" "iam-mode-not-hybrid"
    exit 0
  fi

  if [[ -z "${UPSTREAM_TYPE}" ]]; then
    status_set "state" "skipped"
    status_set "reason" "hybrid-without-upstream"
    exit 0
  fi

  local healthy="false"
  if check_upstream_health; then
    healthy="true"
  elif [[ "${FAIL_OPEN}" != "true" ]]; then
    # Keep explicit visibility in status when fail-open is disabled.
    status_set "health.failOpen" "false"
  fi

  update_counters "${healthy}"

  local desired_state current_state
  current_state="$(status_get redirectState)"
  [[ -n "${current_state}" ]] || current_state="local"
  desired_state="${current_state}"

  if [[ "${healthy}" == "true" && "${CONSEC_SUCCESS}" -ge "${SUCCESS_THRESHOLD}" ]]; then
    desired_state="upstream"
  fi
  if [[ "${healthy}" != "true" && "${CONSEC_FAILURE}" -ge "${FAILURE_THRESHOLD}" ]]; then
    desired_state="local"
  fi

  local token
  token="$(keycloak_token)"
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    status_set "state" "error"
    status_set "reason" "keycloak-admin-token-unavailable"
    exit 1
  fi

  if [[ "${UPSTREAM_TYPE}" != "oidc" && "${UPSTREAM_TYPE}" != "saml" ]]; then
    desired_state="local"
    status_set "reason" "upstream-type-does-not-use-browser-redirect"
  fi

  local realm
  if [[ "${desired_state}" == "upstream" ]]; then
    for realm in "${TARGET_REALMS[@]}"; do
      apply_redirect_state_for_realm "${realm}" "upstream" "${token}" || {
        status_set "state" "error"
        status_set "reason" "redirector-config-missing"
        status_set "realm.error" "${realm}"
        exit 1
      }
    done
    status_set "redirectState" "upstream"
    status_set "state" "applied"
    status_set "reason" "upstream-preferred"
  else
    for realm in "${TARGET_REALMS[@]}"; do
      apply_redirect_state_for_realm "${realm}" "local" "${token}" || {
        status_set "state" "error"
        status_set "reason" "redirector-requirement-update-failed"
        status_set "realm.error" "${realm}"
        exit 1
      }
    done
    status_set "redirectState" "local"
    status_set "state" "applied"
    if [[ "${UPSTREAM_TYPE}" == "oidc" || "${UPSTREAM_TYPE}" == "saml" ]]; then
      status_set "reason" "local-visible"
    fi
  fi
}

main "$@"
