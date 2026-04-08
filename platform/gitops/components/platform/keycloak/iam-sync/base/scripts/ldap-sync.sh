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
STATUS_CM="${STATUS_CONFIGMAP:-keycloak-ldap-sync-status}"
TMP_DIR="$(mktemp -d)"
DEPLOYMENT_CONFIG_FILE="${TMP_DIR}/deployment-config.yaml"

cleanup() {
  rm -rf "${TMP_DIR}"
  deploykube_istio_quit_sidecar >/dev/null 2>&1 || true
}
trap cleanup EXIT

status_set() {
  local key="$1"
  local value="$2"
  local patch

  patch="$(jq -n --arg k "$key" --arg v "$value" '{data:{($k):$v}}')"
  kubectl -n "$NAMESPACE" patch configmap "$STATUS_CM" --type merge -p "$patch" >/dev/null 2>&1 || \
    kubectl -n "$NAMESPACE" create configmap "$STATUS_CM" --from-literal "$key=$value" >/dev/null
}

cfg() {
  local expr="$1"
  yq -r "${expr} // \"\"" "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || true
}

load_snapshot() {
  local cm_json raw
  cm_json="$(kubectl -n "$NAMESPACE" get configmap "$SNAPSHOT_NAME" -o json)"
  raw="$(echo "$cm_json" | jq -r --arg key "$SNAPSHOT_KEY" '.data[$key] // ""')"
  if [[ -z "$raw" ]]; then
    log "snapshot ${NAMESPACE}/${SNAPSHOT_NAME} missing key ${SNAPSHOT_KEY}"
    exit 0
  fi
  printf '%s\n' "$raw" > "$DEPLOYMENT_CONFIG_FILE"
}

keycloak_token() {
  local secret_json username password
  secret_json="$(kubectl -n "$NAMESPACE" get secret keycloak-admin-credentials -o json)"
  username="$(echo "$secret_json" | jq -r '.data.username // ""' | base64 -d)"
  password="$(echo "$secret_json" | jq -r '.data.password // ""' | base64 -d)"
  [[ -n "$username" && -n "$password" ]] || return 1

  curl -sSf -X POST "${KEYCLOAK_API%/}/realms/master/protocol/openid-connect/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" | jq -r '.access_token'
}

find_ldap_component_id() {
  local realm="$1"
  local token="$2"
  curl -sSf -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/components?providerType=org.keycloak.storage.UserStorageProvider" | \
    jq -r '.[] | select(.providerId=="ldap" and .name=="deploykube-upstream-ldap") | .id' | head -n 1
}

trigger_ldap_sync() {
  local realm="$1"
  local component_id="$2"
  local token="$3"
  local response

  response="$(curl -sSf -X POST -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/user-storage/${component_id}/sync?action=triggerFullSync")"
  echo "$response" | jq -r '.status // "started"'
}

main() {
  local iam_mode upstream_type ldap_mode primary_realm token total_synced
  local -a realms=()

  load_snapshot

  iam_mode="$(cfg '.spec.iam.mode')"
  [[ -n "$iam_mode" ]] || iam_mode="standalone"
  upstream_type="$(cfg '.spec.iam.upstream.type')"
  ldap_mode="$(cfg '.spec.iam.upstream.ldap.operationMode')"
  primary_realm="$(cfg '.spec.iam.primaryRealm')"
  [[ -n "$primary_realm" ]] || primary_realm="deploykube-admin"

  status_set "lastCheckedAt" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status_set "mode" "$iam_mode"
  status_set "upstream.type" "$upstream_type"
  status_set "ldap.operationMode" "$ldap_mode"

  if [[ "$upstream_type" != "ldap" ]]; then
    status_set "state" "skipped"
    status_set "reason" "upstream-not-ldap"
    exit 0
  fi

  if [[ "$ldap_mode" != "sync" ]]; then
    status_set "state" "skipped"
    status_set "reason" "ldap-operation-mode-not-sync"
    exit 0
  fi

  mapfile -t realms < <(
    {
      printf '%s\n' "$primary_realm"
      yq -r '.spec.iam.secondaryRealms[]?' "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || true
    } | awk 'NF>0 && !seen[$0]++'
  )
  if [[ "${#realms[@]}" -eq 0 ]]; then
    realms=("deploykube-admin")
  fi
  status_set "realm.targets" "$(IFS=,; echo "${realms[*]}")"

  token="$(keycloak_token)"
  if [[ -z "$token" || "$token" == "null" ]]; then
    status_set "state" "error"
    status_set "reason" "keycloak-admin-token-unavailable"
    exit 1
  fi

  total_synced=0
  local realm component_id sync_status
  for realm in "${realms[@]}"; do
    component_id="$(find_ldap_component_id "$realm" "$token")"
    if [[ -z "$component_id" ]]; then
      status_set "realm.${realm}.state" "skipped"
      status_set "realm.${realm}.reason" "ldap-component-not-found"
      continue
    fi

    sync_status="$(trigger_ldap_sync "$realm" "$component_id" "$token")"
    status_set "realm.${realm}.state" "synced"
    status_set "realm.${realm}.status" "$sync_status"
    status_set "realm.${realm}.componentId" "$component_id"
    total_synced=$((total_synced + 1))
  done

  status_set "realmsSynced" "$total_synced"
  status_set "state" "applied"
  status_set "reason" "ldap-full-sync-triggered"
}

main "$@"
