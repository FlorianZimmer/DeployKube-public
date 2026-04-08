#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") audit
  $(basename "$0") provision-owner

Environment (optional):
  KEYCLOAK_NAMESPACE=keycloak
  DEPLOYKUBE_CONFIG_SNAPSHOT_NAME=deploykube-deployment-config
  DEPLOYKUBE_CONFIG_SNAPSHOT_KEY=deployment-config.yaml
  KEYCLOAK_INTERNAL_URL=http://keycloak.keycloak.svc.cluster.local:8080
  KEYCLOAK_URL=https://<keycloak-host>

Environment (required for provision-owner):
  IAM_OWNER_USERNAME=<username>
  IAM_OWNER_EMAIL=<email>
  IAM_OWNER_TEMP_PASSWORD=<temporary-password>
  IAM_OWNER_FIRST_NAME=<first-name>    # optional (default: IAM)
  IAM_OWNER_LAST_NAME=<last-name>      # optional (default: Owner)
USAGE
}

NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
SNAPSHOT_NAME="${DEPLOYKUBE_CONFIG_SNAPSHOT_NAME:-deploykube-deployment-config}"
SNAPSHOT_KEY="${DEPLOYKUBE_CONFIG_SNAPSHOT_KEY:-deployment-config.yaml}"
KEYCLOAK_API="${KEYCLOAK_INTERNAL_URL:-http://keycloak.keycloak.svc.cluster.local:8080}"
TMP_DIR="$(mktemp -d)"
DEPLOYMENT_CONFIG_FILE="${TMP_DIR}/deployment-config.yaml"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

cfg() {
  local expr="$1"
  yq -r "${expr} // \"\"" "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || true
}

load_snapshot() {
  local cm_json raw
  cm_json="$(kubectl -n "$NAMESPACE" get configmap "$SNAPSHOT_NAME" -o json)"
  raw="$(echo "$cm_json" | jq -r --arg key "$SNAPSHOT_KEY" '.data[$key] // ""')"
  [[ -n "$raw" ]] || {
    echo "snapshot ${NAMESPACE}/${SNAPSHOT_NAME} missing key ${SNAPSHOT_KEY}" >&2
    exit 1
  }
  printf '%s\n' "$raw" > "$DEPLOYMENT_CONFIG_FILE"
}

keycloak_token() {
  local secret_json username password
  secret_json="$(kubectl -n "$NAMESPACE" get secret keycloak-admin-credentials -o json)"
  username="$(echo "$secret_json" | jq -r '.data.username // ""' | base64 -d)"
  password="$(echo "$secret_json" | jq -r '.data.password // ""' | base64 -d)"
  [[ -n "$username" && -n "$password" ]] || {
    echo "keycloak-admin-credentials missing username/password" >&2
    exit 1
  }

  curl -sSf -X POST "${KEYCLOAK_API%/}/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" | jq -r '.access_token'
}

ensure_group() {
  local realm="$1"
  local group="$2"
  local token="$3"
  local group_id
  group_id="$(curl -sSf -H "Authorization: Bearer ${token}" "${KEYCLOAK_API%/}/admin/realms/${realm}/groups?search=${group}" | jq -r --arg g "$group" '.[] | select(.name==$g) | .id' | head -n 1)"
  if [[ -z "$group_id" ]]; then
    curl -sSf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      --data "$(jq -n --arg g "$group" '{name:$g}')" \
      "${KEYCLOAK_API%/}/admin/realms/${realm}/groups" >/dev/null
  fi
}

ensure_owner_user() {
  local realm="$1"
  local username="$2"
  local email="$3"
  local temp_password="$4"
  local first_name="$5"
  local last_name="$6"
  local token="$7"
  local user_id group_id

  user_id="$(curl -sSf -H "Authorization: Bearer ${token}" "${KEYCLOAK_API%/}/admin/realms/${realm}/users?username=${username}" | jq -r '.[0].id // empty')"
  if [[ -z "$user_id" ]]; then
    curl -sSf -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      --data "$(jq -n --arg u "$username" --arg e "$email" --arg fn "$first_name" --arg ln "$last_name" '{username:$u,enabled:true,email:$e,emailVerified:true,firstName:$fn,lastName:$ln}')" \
      "${KEYCLOAK_API%/}/admin/realms/${realm}/users" >/dev/null
    user_id="$(curl -sSf -H "Authorization: Bearer ${token}" "${KEYCLOAK_API%/}/admin/realms/${realm}/users?username=${username}" | jq -r '.[0].id // empty')"
  fi
  [[ -n "$user_id" ]] || {
    echo "failed to find/create user ${realm}/${username}" >&2
    exit 1
  }

  curl -sSf -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    --data "$(jq -n --arg e "$email" --arg fn "$first_name" --arg ln "$last_name" '{enabled:true,email:$e,emailVerified:true,firstName:$fn,lastName:$ln}')" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/users/${user_id}" >/dev/null

  curl -sSf -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    --data "$(jq -n --arg v "$temp_password" '{type:"password",value:$v,temporary:true}')" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/users/${user_id}/reset-password" >/dev/null

  group_id="$(curl -sSf -H "Authorization: Bearer ${token}" "${KEYCLOAK_API%/}/admin/realms/${realm}/groups?search=dk-iam-admins" | jq -r '.[] | select(.name=="dk-iam-admins") | .id' | head -n 1)"
  [[ -n "$group_id" ]] || {
    echo "group dk-iam-admins missing in realm ${realm}" >&2
    exit 1
  }

  curl -sSf -X PUT -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_API%/}/admin/realms/${realm}/users/${user_id}/groups/${group_id}" >/dev/null
}

mode_summary() {
  local mode upstream_type primary_realm issuer
  mode="$(cfg '.spec.iam.mode')"
  [[ -n "$mode" ]] || mode="standalone"
  upstream_type="$(cfg '.spec.iam.upstream.type')"
  primary_realm="$(cfg '.spec.iam.primaryRealm')"
  [[ -n "$primary_realm" ]] || primary_realm="deploykube-admin"
  issuer="${KEYCLOAK_URL:-$(cfg '.spec.dns.hostnames.keycloak')}"

  echo "mode=${mode}"
  echo "upstream.type=${upstream_type:-none}"
  echo "primaryRealm=${primary_realm}"
  if [[ -n "$issuer" ]]; then
    if [[ "$issuer" == http*://* ]]; then
      echo "issuerBase=${issuer}"
    else
      echo "issuerBase=https://${issuer}"
    fi
  fi
}

print_upstream_handover_hints() {
  local upstream_type
  upstream_type="$(cfg '.spec.iam.upstream.type')"

  if [[ "$upstream_type" != "oidc" && "$upstream_type" != "saml" ]]; then
    return 0
  fi

  local mapping_count iam_admin_mapping noncanonical_iam_admin_mapping
  if [[ "$upstream_type" == "oidc" ]]; then
    mapping_count="$(yq -r '(.spec.iam.upstream.oidc.groupMappings // []) | length' "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || echo 0)"
    iam_admin_mapping="$(yq -r '.spec.iam.upstream.oidc.groupMappings[]? | select(.target=="/dk-iam-admins") | .target' "$DEPLOYMENT_CONFIG_FILE" | head -n 1)"
    noncanonical_iam_admin_mapping="$(yq -r '.spec.iam.upstream.oidc.groupMappings[]? | select(.target=="dk-iam-admins") | .target' "$DEPLOYMENT_CONFIG_FILE" | head -n 1)"
  else
    mapping_count="$(yq -r '(.spec.iam.upstream.saml.groupMappings // []) | length' "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || echo 0)"
    iam_admin_mapping="$(yq -r '.spec.iam.upstream.saml.groupMappings[]? | select(.target=="/dk-iam-admins") | .target' "$DEPLOYMENT_CONFIG_FILE" | head -n 1)"
    noncanonical_iam_admin_mapping="$(yq -r '.spec.iam.upstream.saml.groupMappings[]? | select(.target=="dk-iam-admins") | .target' "$DEPLOYMENT_CONFIG_FILE" | head -n 1)"
  fi

  if [[ -n "${noncanonical_iam_admin_mapping:-}" && -z "${iam_admin_mapping:-}" ]]; then
    echo "Handover warning: found non-canonical upstream mapping target 'dk-iam-admins' (missing leading '/')."
    echo "Update DeploymentConfig groupMappings[].target to '/dk-iam-admins' (Keycloak group path) to match the repo contract."
  fi

  if [[ "$mapping_count" -eq 0 || (-z "$iam_admin_mapping" && -z "${noncanonical_iam_admin_mapping:-}") ]]; then
    echo "Handover warning: no upstream group mapping currently targets dk-iam-admins."
    echo "Add a mapping in DeploymentConfig so human IAM operators can administer users/groups via upstream login."
  fi
}

run_audit() {
  local token primary_realm
  token="$(keycloak_token)"
  primary_realm="$(cfg '.spec.iam.primaryRealm')"
  [[ -n "$primary_realm" ]] || primary_realm="deploykube-admin"

  echo "=== DeployKube IAM handover audit ==="
  mode_summary

  local realm
  while IFS= read -r realm; do
    [[ -n "$realm" ]] || continue
    ensure_group "$realm" "dk-iam-admins" "$token"
    echo "realm ${realm}: dk-iam-admins present"
  done < <({
    printf '%s\n' "$primary_realm"
    yq -r '.spec.iam.secondaryRealms[]?' "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || true
  } | awk 'NF>0 && !seen[$0]++')

  print_upstream_handover_hints

  echo "Next steps:"
  echo "1. Run provision-owner to create the first human IAM owner local breakglass account."
  echo "2. Validate login and group admin permissions in each configured realm."
  echo "3. For upstream modes, validate IdP group mapping to dk-iam-admins before removing bootstrap-era human access."
}

run_provision_owner() {
  local username email temp_password first_name last_name token primary_realm
  username="${IAM_OWNER_USERNAME:-}"
  email="${IAM_OWNER_EMAIL:-}"
  temp_password="${IAM_OWNER_TEMP_PASSWORD:-}"
  first_name="${IAM_OWNER_FIRST_NAME:-IAM}"
  last_name="${IAM_OWNER_LAST_NAME:-Owner}"

  [[ -n "$username" && -n "$email" && -n "$temp_password" ]] || {
    echo "IAM_OWNER_USERNAME, IAM_OWNER_EMAIL, IAM_OWNER_TEMP_PASSWORD are required" >&2
    exit 1
  }

  token="$(keycloak_token)"
  primary_realm="$(cfg '.spec.iam.primaryRealm')"
  [[ -n "$primary_realm" ]] || primary_realm="deploykube-admin"

  local realm
  while IFS= read -r realm; do
    [[ -n "$realm" ]] || continue
    ensure_group "$realm" "dk-iam-admins" "$token"
    ensure_owner_user "$realm" "$username" "$email" "$temp_password" "$first_name" "$last_name" "$token"
    log "provisioned IAM owner ${realm}/${username} (temporary password set; user must rotate on first login)"
  done < <({
    printf '%s\n' "$primary_realm"
    yq -r '.spec.iam.secondaryRealms[]?' "$DEPLOYMENT_CONFIG_FILE" 2>/dev/null || true
  } | awk 'NF>0 && !seen[$0]++')

  echo "Provisioned ${username} into dk-iam-admins for configured realms."
  echo "Ensure the owner signs in immediately and sets a new credential."
}

main() {
  local cmd="${1:-audit}"
  if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then
    usage
    exit 0
  fi

  load_snapshot

  case "$cmd" in
    audit)
      run_audit
      ;;
    provision-owner)
      run_provision_owner
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
