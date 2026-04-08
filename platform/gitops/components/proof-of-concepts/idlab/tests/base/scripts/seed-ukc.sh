#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://ukc-keycloak:8080}"
ADMIN_USER="${UKC_ADMIN_USERNAME}"
ADMIN_PASSWORD="${UKC_ADMIN_PASSWORD}"
REALM="ukc"

wait_for_kc() {
  until curl -fsS "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" >/dev/null; do
    sleep 2
  done
}

login() {
  kcadm.sh config credentials --server "${KEYCLOAK_URL}" --realm master --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}"
}

ensure_realm() {
  if ! kcadm.sh get "realms/${REALM}" >/dev/null 2>&1; then
    kcadm.sh create realms -s realm="${REALM}" -s enabled=true >/dev/null
  fi
  kcadm.sh update "realms/${REALM}" -s registrationAllowed=false -s loginWithEmailAllowed=true -s eventsEnabled=true >/dev/null
}

ensure_confidential_client() {
  local client_id="$1"
  local secret="$2"
  local redirect_uri="$3"
  local uuid
  uuid="$(kcadm.sh get clients -r "${REALM}" -q clientId="${client_id}" | jq -r '.[0].id // empty')"
  if [ -z "${uuid}" ]; then
    kcadm.sh create clients -r "${REALM}" \
      -s clientId="${client_id}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s secret="${secret}" \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=false \
      -s 'redirectUris=["'"${redirect_uri}"'"]' >/dev/null
    uuid="$(kcadm.sh get clients -r "${REALM}" -q clientId="${client_id}" | jq -r '.[0].id // empty')"
  fi
  kcadm.sh update "clients/${uuid}" -r "${REALM}" \
    -s enabled=true \
    -s secret="${secret}" \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s 'redirectUris=["'"${redirect_uri}"'"]' >/dev/null
}

ensure_service_client() {
  local client_id="$1"
  local secret="$2"
  local uuid sa_user_id
  uuid="$(kcadm.sh get clients -r "${REALM}" -q clientId="${client_id}" | jq -r '.[0].id // empty')"
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
    uuid="$(kcadm.sh get clients -r "${REALM}" -q clientId="${client_id}" | jq -r '.[0].id // empty')"
  fi
  sa_user_id="$(kcadm.sh get "clients/${uuid}/service-account-user" -r "${REALM}" | jq -r '.id')"
  for role in view-users query-users query-groups view-realm; do
    kcadm.sh add-roles -r "${REALM}" --uusername "service-account-${client_id}" --cclientid realm-management --rolename "${role}" >/dev/null 2>&1 || true
    kcadm.sh add-roles -r "${REALM}" --uid "${sa_user_id}" --cclientid realm-management --rolename "${role}" >/dev/null 2>&1 || true
  done
}

ensure_user() {
  local username="$1"
  local password="$2"
  local email="$3"
  local first_name="$4"
  local last_name="$5"
  local user_id
  user_id="$(kcadm.sh get users -r "${REALM}" -q username="${username}" | jq -r '.[0].id // empty')"
  if [ -z "${user_id}" ]; then
    kcadm.sh create users -r "${REALM}" \
      -s username="${username}" \
      -s enabled=true \
      -s email="${email}" \
      -s firstName="${first_name}" \
      -s lastName="${last_name}" >/dev/null
    user_id="$(kcadm.sh get users -r "${REALM}" -q username="${username}" | jq -r '.[0].id // empty')"
  fi
  kcadm.sh update "users/${user_id}" -r "${REALM}" \
    -s enabled=true \
    -s email="${email}" \
    -s firstName="${first_name}" \
    -s lastName="${last_name}" >/dev/null
  kcadm.sh set-password -r "${REALM}" --userid "${user_id}" --new-password "${password}" >/dev/null
}

ensure_group() {
  local name="$1"
  kcadm.sh create groups -r "${REALM}" -s name="${name}" >/dev/null 2>&1 || true
  kcadm.sh get groups -r "${REALM}" | jq -r --arg name "${name}" '.[] | select(.name==$name) | .id' | head -n1
}

ensure_membership() {
  local username="$1"
  local group_id="$2"
  local user_id
  user_id="$(kcadm.sh get users -r "${REALM}" -q username="${username}" | jq -r '.[0].id // empty')"
  kcadm.sh update "users/${user_id}/groups/${group_id}" -r "${REALM}" >/dev/null 2>&1 || true
}

wait_for_kc
login
ensure_realm
ensure_confidential_client "mkc-broker" "MKC-Broker-123!" "http://mkc-keycloak:8080/realms/mkc/broker/ukc/endpoint"
ensure_service_client "sync-controller" "${UKC_SYNC_CLIENT_SECRET}"
ensure_user "alice" "Alice-UKC-123!" "alice@idlab.example" "Alice" "Anderson"
ensure_user "bob" "Bob-UKC-123!" "bob@idlab.example" "Bob" "Brown"
engineering_id="$(ensure_group engineering)"
finance_id="$(ensure_group finance)"
ensure_membership "alice" "${engineering_id}"
ensure_membership "bob" "${finance_id}"
echo "ukc seeded"
