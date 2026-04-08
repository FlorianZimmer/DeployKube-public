#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

NAMESPACE="${POD_NAMESPACE:-keycloak-upstream-sim}"
UPSTREAM_KEYCLOAK_URL="${UPSTREAM_KEYCLOAK_URL:-http://keycloak-upstream-sim.keycloak-upstream-sim.svc.cluster.local:8080}"
UPSTREAM_REALM="${UPSTREAM_REALM:-upstream-sim}"
DOWNSTREAM_REALM="${DOWNSTREAM_REALM:-deploykube-admin}"
UPSTREAM_ALIAS="${UPSTREAM_ALIAS:-upstream}"
UPSTREAM_CLIENT_ID="${UPSTREAM_CLIENT_ID:-deploykube-upstream-broker}"
DEPLOYMENT_CONFIG_NAMESPACE="${DEPLOYMENT_CONFIG_NAMESPACE:-argocd}"
DEPLOYMENT_CONFIG_NAME="${DEPLOYMENT_CONFIG_NAME:-}"
STATUS_CONFIGMAP="${STATUS_CONFIGMAP:-keycloak-upstream-sim-status}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SIM_USERNAME="${SIM_USERNAME:-sim-user}"
SIM_PASSWORD="${SIM_PASSWORD:-}"
SIM_GROUP="${SIM_GROUP:-dk-platform-admins}"

ACCESS_TOKEN=""
API_CODE=""
API_BODY=""

status_set() {
  local key="$1"
  local value="$2"
  local patch

  patch="$(jq -n --arg k "$key" --arg v "$value" '{data:{($k):$v}}')"
  kubectl -n "$NAMESPACE" patch configmap "$STATUS_CONFIGMAP" --type merge -p "$patch" >/dev/null 2>&1 || \
    kubectl -n "$NAMESPACE" create configmap "$STATUS_CONFIGMAP" --from-literal "$key=$value" >/dev/null
}

resolve_deployment_config_name() {
  if [[ -n "$DEPLOYMENT_CONFIG_NAME" ]]; then
    return 0
  fi

  DEPLOYMENT_CONFIG_NAME="$(kubectl -n "$DEPLOYMENT_CONFIG_NAMESPACE" get deploymentconfigs.platform.darksite.cloud -o json | jq -r '.items[0].metadata.name // empty')"
  [[ -n "$DEPLOYMENT_CONFIG_NAME" ]] || {
    echo "no DeploymentConfig found in namespace $DEPLOYMENT_CONFIG_NAMESPACE" >&2
    exit 1
  }
}

deployment_cfg() {
  local expr="$1"
  kubectl -n "$DEPLOYMENT_CONFIG_NAMESPACE" get deploymentconfigs.platform.darksite.cloud "$DEPLOYMENT_CONFIG_NAME" -o json | jq -r "$expr // \"\""
}

wait_for_keycloak() {
  local i

  for i in $(seq 1 120); do
    if curl -fsS "${UPSTREAM_KEYCLOAK_URL%/}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "upstream keycloak not ready: $UPSTREAM_KEYCLOAK_URL" >&2
  exit 1
}

get_admin_token() {
  ACCESS_TOKEN="$(curl -fsS -X POST "${UPSTREAM_KEYCLOAK_URL%/}/realms/master/protocol/openid-connect/token" \
    -d grant_type=password \
    -d client_id=admin-cli \
    -d username="$ADMIN_USERNAME" \
    -d password="$ADMIN_PASSWORD" | jq -r '.access_token // empty')"

  [[ -n "$ACCESS_TOKEN" ]] || {
    echo "failed to obtain admin token from upstream keycloak" >&2
    exit 1
  }
}

api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local tmp

  tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    API_CODE="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "${UPSTREAM_KEYCLOAK_URL%/}${path}" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H 'Content-Type: application/json' \
      --data "$body")"
  else
    API_CODE="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "${UPSTREAM_KEYCLOAK_URL%/}${path}" \
      -H "Authorization: Bearer $ACCESS_TOKEN")"
  fi

  API_BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

ensure_realm() {
  api_request GET "/admin/realms/${UPSTREAM_REALM}"
  case "$API_CODE" in
    200)
      return 0
      ;;
    404)
      api_request POST "/admin/realms" "$(jq -n --arg realm "$UPSTREAM_REALM" '{realm:$realm,enabled:true}')"
      [[ "$API_CODE" == "201" || "$API_CODE" == "204" ]] || {
        echo "failed creating realm ${UPSTREAM_REALM}: http=${API_CODE} body=${API_BODY}" >&2
        exit 1
      }
      ;;
    *)
      echo "failed reading realm ${UPSTREAM_REALM}: http=${API_CODE} body=${API_BODY}" >&2
      exit 1
      ;;
  esac
}

find_group_id() {
  api_request GET "/admin/realms/${UPSTREAM_REALM}/groups?search=${SIM_GROUP}"
  [[ "$API_CODE" == "200" ]] || {
    echo "failed listing groups: http=${API_CODE} body=${API_BODY}" >&2
    exit 1
  }

  printf '%s' "$API_BODY" | jq -r --arg n "$SIM_GROUP" '.[] | select(.name==$n) | .id' | head -n 1
}

ensure_group() {
  local group_id

  group_id="$(find_group_id)"
  if [[ -n "$group_id" ]]; then
    return 0
  fi

  api_request POST "/admin/realms/${UPSTREAM_REALM}/groups" "$(jq -n --arg n "$SIM_GROUP" '{name:$n}')"
  [[ "$API_CODE" == "201" || "$API_CODE" == "204" ]] || {
    echo "failed creating group ${SIM_GROUP}: http=${API_CODE} body=${API_BODY}" >&2
    exit 1
  }
}

find_user_id() {
  api_request GET "/admin/realms/${UPSTREAM_REALM}/users?username=${SIM_USERNAME}"
  [[ "$API_CODE" == "200" ]] || {
    echo "failed listing users: http=${API_CODE} body=${API_BODY}" >&2
    exit 1
  }

  printf '%s' "$API_BODY" | jq -r '.[0].id // empty'
}

ensure_user() {
  local user_id group_id

  user_id="$(find_user_id)"
  if [[ -z "$user_id" ]]; then
    api_request POST "/admin/realms/${UPSTREAM_REALM}/users" "$(jq -n \
      --arg username "$SIM_USERNAME" \
      --arg email "${SIM_USERNAME}@upstream-sim.internal" \
      '{username:$username,enabled:true,email:$email,firstName:"Upstream",lastName:"Sim"}')"
    [[ "$API_CODE" == "201" || "$API_CODE" == "204" ]] || {
      echo "failed creating user ${SIM_USERNAME}: http=${API_CODE} body=${API_BODY}" >&2
      exit 1
    }
    user_id="$(find_user_id)"
  fi

  [[ -n "$user_id" ]] || {
    echo "failed resolving user id for ${SIM_USERNAME}" >&2
    exit 1
  }

  api_request PUT "/admin/realms/${UPSTREAM_REALM}/users/${user_id}" "$(jq -n \
    --arg username "$SIM_USERNAME" \
    --arg email "${SIM_USERNAME}@upstream-sim.internal" \
    '{username:$username,enabled:true,email:$email,firstName:"Upstream",lastName:"Sim"}')"
  [[ "$API_CODE" == "204" ]] || {
    echo "failed updating user ${SIM_USERNAME}: http=${API_CODE} body=${API_BODY}" >&2
    exit 1
  }

  if [[ -n "$SIM_PASSWORD" ]]; then
    api_request PUT "/admin/realms/${UPSTREAM_REALM}/users/${user_id}/reset-password" "$(jq -n --arg p "$SIM_PASSWORD" '{type:"password",value:$p,temporary:false}')"
    [[ "$API_CODE" == "204" ]] || {
      echo "failed setting user password for ${SIM_USERNAME}: http=${API_CODE} body=${API_BODY}" >&2
      exit 1
    }
  fi

  group_id="$(find_group_id)"
  if [[ -n "$group_id" ]]; then
    api_request PUT "/admin/realms/${UPSTREAM_REALM}/users/${user_id}/groups/${group_id}"
    [[ "$API_CODE" == "204" ]] || {
      echo "failed adding user ${SIM_USERNAME} to group ${SIM_GROUP}: http=${API_CODE} body=${API_BODY}" >&2
      exit 1
    }
  fi
}

resolve_downstream_client_secret() {
  kubectl -n keycloak get secret keycloak-upstream-oidc -o json | jq -r '.data["clientSecret"] // empty' | base64 -d
}

find_client_id() {
  api_request GET "/admin/realms/${UPSTREAM_REALM}/clients?clientId=${UPSTREAM_CLIENT_ID}"
  [[ "$API_CODE" == "200" ]] || {
    echo "failed listing clients: http=${API_CODE} body=${API_BODY}" >&2
    exit 1
  }

  printf '%s' "$API_BODY" | jq -r '.[0].id // empty'
}

ensure_client() {
  local downstream_host redirect_uri secret existing_id

  downstream_host="$(deployment_cfg '.spec.dns.hostnames.keycloak')"
  [[ -n "$downstream_host" ]] || {
    echo "deployment config missing spec.dns.hostnames.keycloak" >&2
    exit 1
  }

  redirect_uri="https://${downstream_host}/realms/${DOWNSTREAM_REALM}/broker/${UPSTREAM_ALIAS}/endpoint"
  secret="$(resolve_downstream_client_secret)"
  [[ -n "$secret" ]] || {
    echo "missing keycloak/keycloak-upstream-oidc clientSecret" >&2
    exit 1
  }

  existing_id="$(find_client_id)"
  if [[ -n "$existing_id" ]]; then
    api_request DELETE "/admin/realms/${UPSTREAM_REALM}/clients/${existing_id}"
    [[ "$API_CODE" == "204" ]] || {
      echo "failed deleting existing client ${UPSTREAM_CLIENT_ID}: http=${API_CODE} body=${API_BODY}" >&2
      exit 1
    }
  fi

  api_request POST "/admin/realms/${UPSTREAM_REALM}/clients" "$(jq -n \
    --arg clientId "$UPSTREAM_CLIENT_ID" \
    --arg redirectUri "$redirect_uri" \
    --arg secret "$secret" \
    '{clientId:$clientId,protocol:"openid-connect",enabled:true,publicClient:false,standardFlowEnabled:true,directAccessGrantsEnabled:false,redirectUris:[$redirectUri],secret:$secret}')"
  [[ "$API_CODE" == "201" || "$API_CODE" == "204" ]] || {
    echo "failed creating client ${UPSTREAM_CLIENT_ID}: http=${API_CODE} body=${API_BODY}" >&2
    exit 1
  }
}

main() {
  [[ -n "$ADMIN_USERNAME" ]] || { echo "ADMIN_USERNAME must be set" >&2; exit 1; }
  [[ -n "$ADMIN_PASSWORD" ]] || { echo "ADMIN_PASSWORD must be set" >&2; exit 1; }

  status_set "status" "running"
  status_set "lastStartTime" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status_set "upstream.url" "$UPSTREAM_KEYCLOAK_URL"
  status_set "upstream.realm" "$UPSTREAM_REALM"

  resolve_deployment_config_name
  status_set "deploymentConfig.namespace" "$DEPLOYMENT_CONFIG_NAMESPACE"
  status_set "deploymentConfig.name" "$DEPLOYMENT_CONFIG_NAME"

  wait_for_keycloak
  get_admin_token
  ensure_realm
  ensure_group
  ensure_user
  ensure_client

  status_set "status" "ready"
  status_set "lastSuccessTime" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status_set "simUser.username" "$SIM_USERNAME"
  status_set "simUser.group" "$SIM_GROUP"
  log "upstream keycloak simulation bootstrap completed"
}

main "$@"
