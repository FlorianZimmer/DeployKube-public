#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://btp-keycloak:8080}"
ADMIN_USER="${BTP_ADMIN_USERNAME}"
ADMIN_PASSWORD="${BTP_ADMIN_PASSWORD}"
REALM="btp"

wait_for_kc() {
  until curl -fsS "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" >/dev/null; do
    sleep 2
  done
}

login() {
  kcadm.sh config credentials --server "${KEYCLOAK_URL}" --realm master --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}"
}

admin_token() {
  curl -fsS -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli \
    --data-urlencode username="${ADMIN_USER}" \
    --data-urlencode password="${ADMIN_PASSWORD}" | jq -r '.access_token'
}

client_uuid() {
  kcadm.sh get clients -r "${REALM}" -q clientId="$1" | jq -r '.[0].id // empty'
}

ensure_realm() {
  if ! kcadm.sh get "realms/${REALM}" >/dev/null 2>&1; then
    kcadm.sh create realms -s realm="${REALM}" -s enabled=true >/dev/null
  fi
  kcadm.sh update "realms/${REALM}" \
    -s enabled=true \
    -s registrationAllowed=false \
    -s loginWithEmailAllowed=true >/dev/null
}

ensure_public_client() {
  local client_id="$1"
  local uuid
  uuid="$(client_uuid "${client_id}")"
  if [ -z "${uuid}" ]; then
    kcadm.sh create clients -r "${REALM}" \
      -s clientId="${client_id}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=true \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=false \
      -s 'redirectUris=["http://127.0.0.1/callback*"]' \
      -s 'webOrigins=["*"]' >/dev/null
    uuid="$(client_uuid "${client_id}")"
  fi
  if ! kcadm.sh get "clients/${uuid}/protocol-mappers/models" -r "${REALM}" | jq -e '.[] | select(.name=="groups")' >/dev/null; then
    kcadm.sh create "clients/${uuid}/protocol-mappers/models" -r "${REALM}" \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"="false"' \
      -s 'config."id.token.claim"="true"' \
      -s 'config."access.token.claim"="true"' \
      -s 'config."userinfo.token.claim"="true"' \
      -s 'config."claim.name"="groups"' >/dev/null
  fi
}

ensure_service_client() {
  local client_id="$1" secret="$2"
  local uuid sa_user_id
  uuid="$(client_uuid "${client_id}")"
  if [ -z "${uuid}" ]; then
    kcadm.sh create clients -r "${REALM}" \
      -s clientId="${client_id}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s secret="${secret}" >/dev/null
    uuid="$(client_uuid "${client_id}")"
  fi
  sa_user_id="$(kcadm.sh get "clients/${uuid}/service-account-user" -r "${REALM}" | jq -r '.id')"
  for role in manage-users view-users query-users manage-clients view-clients query-groups manage-realm; do
    kcadm.sh add-roles -r "${REALM}" --uid "${sa_user_id}" --cclientid realm-management --rolename "${role}" >/dev/null 2>&1 || true
  done
}

ensure_oidc_idp() {
  if kcadm.sh get "identity-provider/instances/mkc" -r "${REALM}" >/dev/null 2>&1; then
    kcadm.sh delete "identity-provider/instances/mkc" -r "${REALM}" >/dev/null
  fi
  kcadm.sh create identity-provider/instances -r "${REALM}" \
    -s alias=mkc \
    -s providerId=oidc \
    -s enabled=true \
    -s linkOnly=false \
    -s 'firstBrokerLoginFlowAlias=first broker login' \
    -s config.issuer=http://mkc-keycloak:8080/realms/mkc \
    -s config.discoveryUrl=http://mkc-keycloak:8080/realms/mkc/.well-known/openid-configuration \
    -s config.authorizationUrl=http://mkc-keycloak:8080/realms/mkc/protocol/openid-connect/auth \
    -s config.tokenUrl=http://mkc-keycloak:8080/realms/mkc/protocol/openid-connect/token \
    -s config.logoutUrl=http://mkc-keycloak:8080/realms/mkc/protocol/openid-connect/logout \
    -s config.userInfoUrl=http://mkc-keycloak:8080/realms/mkc/protocol/openid-connect/userinfo \
    -s config.jwksUrl=http://mkc-keycloak:8080/realms/mkc/protocol/openid-connect/certs \
    -s config.clientId=btp-broker \
    -s config.clientSecret=BTP-Broker-123! \
    -s 'config.validateSignature="true"' \
    -s 'config.useJwksUrl="true"' \
    -s 'config.defaultScope="openid profile email"' \
    -s 'config.syncMode="FORCE"' >/dev/null
}

set_flow_requirement() {
  local token="$1" execution_id="$2" requirement="$3"
  local payload
  payload="$(jq -cn --arg id "${execution_id}" --arg req "${requirement}" '{id:$id,requirement:$req}')"
  curl -fsS -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/authentication/flows/first%20broker%20login/executions" \
    -H "authorization: Bearer ${token}" \
    -H 'content-type: application/json' \
    --data "${payload}" >/dev/null
}

ensure_existing_account_only_first_broker_login() {
  local token executions_json create_user_id create_user_req handle_existing_id handle_existing_req
  token="$(admin_token)"
  executions_json="$(curl -fsS "${KEYCLOAK_URL}/admin/realms/${REALM}/authentication/flows/first%20broker%20login/executions" \
    -H "authorization: Bearer ${token}")"
  create_user_id="$(echo "${executions_json}" | jq -r '.[] | select(.providerId=="idp-create-user-if-unique") | .id' | head -n1)"
  handle_existing_id="$(echo "${executions_json}" | jq -r '.[] | select(.displayName=="Handle Existing Account" and .level==1) | .id' | head -n1)"
  create_user_req="$(echo "${executions_json}" | jq -r --arg id "${create_user_id}" '.[] | select(.id==$id) | .requirement // empty')"
  handle_existing_req="$(echo "${executions_json}" | jq -r --arg id "${handle_existing_id}" '.[] | select(.id==$id) | .requirement // empty')"
  [[ -n "${create_user_id}" ]] || { echo "missing Create User If Unique execution in ${REALM}" >&2; exit 1; }
  [[ -n "${handle_existing_id}" ]] || { echo "missing Handle Existing Account execution in ${REALM}" >&2; exit 1; }
  if [[ "${create_user_req}" != "DISABLED" ]]; then
    set_flow_requirement "${token}" "${create_user_id}" "DISABLED"
  fi
  if [[ "${handle_existing_req}" != "REQUIRED" ]]; then
    set_flow_requirement "${token}" "${handle_existing_id}" "REQUIRED"
  fi
}

wait_for_kc
login
ensure_realm
ensure_public_client "smoke-app"
ensure_service_client "btp-scim-facade" "${BTP_CLIENT_SECRET}"
ensure_oidc_idp
ensure_existing_account_only_first_broker_login
echo "btp configured"
