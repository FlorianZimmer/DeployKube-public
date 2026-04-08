#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:?MODE is required}"
PROOFS_DIR="${PROOFS_DIR:-/proofs}"
mkdir -p "${PROOFS_DIR}"

controller_url="http://sync-controller:8080"
upstream_push_url="http://upstream-scim-facade:8080"

kc_token() {
  local base="$1" user="$2" pass="$3"
  curl -fsS -X POST "${base}/realms/master/protocol/openid-connect/token" \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=admin-cli' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}" | jq -r '.access_token'
}

kc_admin_get() {
  local base="$1" realm="$2" token="$3" path="$4"
  curl -fsS -H "Authorization: Bearer ${token}" "${base}/admin/realms/${realm}/${path}"
}

kc_admin_put() {
  local base="$1" realm="$2" token="$3" path="$4" payload="$5"
  curl -fsS -X PUT "${base}/admin/realms/${realm}/${path}" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "${payload}" >/dev/null
}

wait_ready() {
  local url="$1"
  until curl -fsS "${url}" >/dev/null; do
    sleep 2
  done
}

wait_deployment_ready_replicas() {
  local deployment="$1" expected="$2"
  while true; do
    local ready
    ready="$(kubectl -n idlab get deployment "${deployment}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "${ready:-0}" == "${expected}" ]]; then
      return 0
    fi
    sleep 2
  done
}

scale_deployment_and_wait() {
  local deployment="$1" replicas="$2"
  kubectl -n idlab scale "deployment/${deployment}" --replicas="${replicas}" >/dev/null
  if [[ "${replicas}" == "0" ]]; then
    wait_deployment_ready_replicas "${deployment}" "0"
    return 0
  fi
  kubectl -n idlab rollout status "deployment/${deployment}" --timeout=180s >/dev/null
}

controller_status() {
  curl -fsS "${controller_url}/status"
}

controller_reconcile() {
  curl -fsS -X POST "${controller_url}/reconcile"
}

trigger_upstream_push() {
  curl -fsS -X POST "${upstream_push_url}/push"
}

trigger_upstream_push_allow_failure() {
  curl -sS -X POST "${upstream_push_url}/push" || true
}

controller_failover() {
  local payload="$1"
  curl -fsS -X PUT "${controller_url}/admin/failover" \
    -H 'Content-Type: application/json' \
    -d "${payload}"
}

store_user_override() {
  local source_id="$1" username="$2" enabled="${3:-true}"
  curl -fsS -X PUT "${controller_url}/admin/users/${source_id}" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${username}\",\"enabled\":${enabled}}"
}

store_group_override() {
  local source_id="$1" authz_key="$2"
  curl -fsS -X PUT "${controller_url}/admin/groups/${source_id}" \
    -H 'Content-Type: application/json' \
    -d "{\"authz_group_key\":\"${authz_key}\",\"display_name\":\"${authz_key}\"}"
}

store_membership_override() {
  local source_user_id="$1" source_group_id="$2"
  curl -fsS -X PUT "${controller_url}/admin/memberships" \
    -H 'Content-Type: application/json' \
    -d "{\"memberships\":[{\"source_user_id\":\"${source_user_id}\",\"source_group_id\":\"${source_group_id}\"}]}"
}

assert_status() {
  local json="$1" expected_state="$2" expected_broker="$3"
  printf '%s\n' "${json}" | jq -e \
    --arg state "${expected_state}" \
    --argjson broker "${expected_broker}" \
    '.effective_state == $state and .broker_enabled == $broker' >/dev/null
}

assert_snapshot_equals() {
  local label="$1" expected_file="$2" actual_file="$3"
  local diff_file="${PROOFS_DIR}/${label}_snapshot_diff.json"
  if ! jq -e -n --slurpfile expected "${expected_file}" --slurpfile actual "${actual_file}" '$expected[0] == $actual[0]' >/dev/null; then
    jq -n --arg label "${label}" --slurpfile expected "${expected_file}" --slurpfile actual "${actual_file}" \
      '{label:$label,expected:$expected[0],actual:$actual[0]}' >"${diff_file}"
    echo "snapshot mismatch for ${label}; see ${diff_file}" >&2
    return 1
  fi
}

lookup_group_id_by_name() {
  local base="$1" realm="$2" token="$3" name="$4"
  kc_admin_get "${base}" "${realm}" "${token}" "groups?search=$(printf '%s' "${name}" | jq -sRr @uri)" \
    | jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' | head -n1
}

lookup_user_id_by_username() {
  local base="$1" realm="$2" token="$3" username="$4"
  kc_admin_get "${base}" "${realm}" "${token}" "users?username=$(printf '%s' "${username}" | jq -sRr @uri)" | jq -r '.[0].id'
}

group_member_count_by_username() {
  local base="$1" realm="$2" token="$3" group_name="$4" username="$5"
  local group_id
  group_id="$(lookup_group_id_by_name "${base}" "${realm}" "${token}" "${group_name}")"
  if [[ -z "${group_id}" ]]; then
    echo "0"
    return 0
  fi
  kc_admin_get "${base}" "${realm}" "${token}" "groups/${group_id}/members?max=200" | jq --arg username "${username}" '[.[] | select(.username == $username)] | length'
}

resolve_source_user_id() {
  local base="$1" realm="$2" token="$3" user_id="$4"
  local user_json source_user_id mkc_user_id
  case "${realm}" in
    ukc)
      printf '%s\n' "${user_id}"
      ;;
    mkc)
      user_json="$(kc_admin_get "${base}" "${realm}" "${token}" "users/${user_id}")"
      source_user_id="$(jq -r '([.federatedIdentities[]? | select(.identityProvider=="ukc") | .userId][0] // .attributes.source_user_id[0] // "")' <<<"${user_json}")"
      printf '%s\n' "${source_user_id}"
      ;;
    btp)
      user_json="$(kc_admin_get "${base}" "${realm}" "${token}" "users/${user_id}")"
      source_user_id="$(jq -r '(.attributes.externalId[0] // "")' <<<"${user_json}")"
      if [[ -n "${source_user_id}" ]]; then
        printf '%s\n' "${source_user_id}"
        return 0
      fi
      mkc_user_id="$(jq -r '([.federatedIdentities[]? | select(.identityProvider=="mkc") | .userId][0] // "")' <<<"${user_json}")"
      if [[ -z "${mkc_user_id}" || -z "${CANONICAL_MKC_BASE:-}" || -z "${CANONICAL_MKC_TOKEN:-}" ]]; then
        printf '\n'
        return 0
      fi
      user_json="$(kc_admin_get "${CANONICAL_MKC_BASE}" mkc "${CANONICAL_MKC_TOKEN}" "users/${mkc_user_id}")"
      source_user_id="$(jq -r '([.federatedIdentities[]? | select(.identityProvider=="ukc") | .userId][0] // .attributes.source_user_id[0] // "")' <<<"${user_json}")"
      printf '%s\n' "${source_user_id}"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

canonical_snapshot() {
  local base="$1" realm="$2" token="$3"
  local users groups memberships group_rows
  case "${realm}" in
    ukc)
      users="$(kc_admin_get "${base}" "${realm}" "${token}" 'users?max=200' | jq '[.[] | select(.username!="admin" and (.username|startswith("service-account-")|not)) | {source_user_id:.id,username,enabled}] | sort_by(.source_user_id)')"
      groups="$(kc_admin_get "${base}" "${realm}" "${token}" 'groups?briefRepresentation=false&max=200' | jq '[.[] | {source_group_id:.id,authz_group_key:("grp_"+.id)}] | sort_by(.source_group_id)')"
      group_rows="$(kc_admin_get "${base}" "${realm}" "${token}" 'groups?briefRepresentation=false&max=200' | jq -c '.[] | {group_id:.id,source_group_id:.id}')"
      ;;
    mkc)
      users="$(
        while IFS= read -r row; do
          [[ -n "${row}" ]] || continue
          local_user_id="$(jq -r '.id' <<<"${row}")"
          local_source_user_id="$(resolve_source_user_id "${base}" "${realm}" "${token}" "${local_user_id}")"
          [[ -n "${local_source_user_id}" ]] || continue
          jq -n --arg source_user_id "${local_source_user_id}" --argjson row "${row}" \
            '{source_user_id:$source_user_id,username:$row.username,enabled:$row.enabled}'
        done < <(kc_admin_get "${base}" "${realm}" "${token}" 'users?max=200' | jq -c '.[] | select(.username!="admin" and (.username|startswith("service-account-")|not))') | jq -s 'sort_by(.source_user_id)'
      )"
      groups="$(kc_admin_get "${base}" "${realm}" "${token}" 'groups?briefRepresentation=false&max=200' | jq '[.[] | {source_group_id:(.attributes.source_group_id[0] // ""),authz_group_key:.name} | select(.source_group_id != "")] | sort_by(.source_group_id)')"
      group_rows="$(kc_admin_get "${base}" "${realm}" "${token}" 'groups?briefRepresentation=false&max=200' | jq -c '.[] | {group_id:.id,source_group_id:(.attributes.source_group_id[0] // "")} | select(.source_group_id != "")')"
      ;;
    btp)
      users="$(
        while IFS= read -r row; do
          [[ -n "${row}" ]] || continue
          local_user_id="$(jq -r '.id' <<<"${row}")"
          local_source_user_id="$(resolve_source_user_id "${base}" "${realm}" "${token}" "${local_user_id}")"
          [[ -n "${local_source_user_id}" ]] || continue
          jq -n --arg source_user_id "${local_source_user_id}" --argjson row "${row}" \
            '{source_user_id:$source_user_id,username:$row.username,enabled:$row.enabled}'
        done < <(kc_admin_get "${base}" "${realm}" "${token}" 'users?max=200' | jq -c '.[] | select(.username!="admin" and (.username|startswith("service-account-")|not))') | jq -s 'sort_by(.source_user_id)'
      )"
      groups="$(kc_admin_get "${base}" "${realm}" "${token}" 'groups?briefRepresentation=false&max=200' | jq '[.[] | {source_group_id:(.attributes.externalId[0] // ""),authz_group_key:.name} | select(.source_group_id != "")] | sort_by(.source_group_id)')"
      group_rows="$(kc_admin_get "${base}" "${realm}" "${token}" 'groups?briefRepresentation=false&max=200' | jq -c '.[] | {group_id:.id,source_group_id:(.attributes.externalId[0] // "")} | select(.source_group_id != "")')"
      ;;
    *)
      echo "unsupported realm ${realm} for canonical snapshot" >&2
      exit 1
      ;;
  esac
  memberships="$(
    while IFS= read -r row; do
      [[ -n "${row}" ]] || continue
      local_group_id="$(jq -r '.group_id' <<<"${row}")"
      local_source_group_id="$(jq -r '.source_group_id' <<<"${row}")"
      while IFS= read -r member_row; do
        [[ -n "${member_row}" ]] || continue
        local_member_id="$(jq -r '.id' <<<"${member_row}")"
        local_source_user_id="$(resolve_source_user_id "${base}" "${realm}" "${token}" "${local_member_id}")"
        [[ -n "${local_source_user_id}" ]] || continue
        jq -n --arg source_group_id "${local_source_group_id}" --arg source_user_id "${local_source_user_id}" \
          '{source_user_id:$source_user_id,source_group_id:$source_group_id}'
      done < <(kc_admin_get "${base}" "${realm}" "${token}" "groups/${local_group_id}/members?max=200" \
        | jq -c '.[] | select(.username!="admin" and (.username|startswith("service-account-")|not))')
    done <<<"${group_rows}" | jq -s 'sort_by(.source_group_id,.source_user_id)'
  )"
  jq -n --argjson users "${users}" --argjson groups "${groups}" --argjson memberships "${memberships}" '{users:$users,groups:$groups,memberships:$memberships}'
}

wait_stack() {
  wait_ready http://ukc-keycloak:8080/realms/master/.well-known/openid-configuration
  wait_stack_offline
  trigger_upstream_push >/dev/null
}

wait_stack_offline() {
  wait_ready http://mkc-keycloak:8080/realms/master/.well-known/openid-configuration
  wait_ready http://btp-keycloak:8080/realms/master/.well-known/openid-configuration
  wait_ready http://source-scim-ingest:8080/healthz
  wait_ready http://upstream-scim-facade:8080/healthz
  wait_ready http://sync-controller:8080/healthz
}

case "${MODE}" in
  provisioning)
    wait_stack
    reconcile="$(controller_reconcile)"
    printf '%s\n' "${reconcile}" | jq '.' | tee "${PROOFS_DIR}/reconcile_provisioning.json"
    ukc_token="$(kc_token http://ukc-keycloak:8080 "${UKC_ADMIN_USERNAME}" "${UKC_ADMIN_PASSWORD}")"
    mkc_token="$(kc_token http://mkc-keycloak:8080 "${MKC_ADMIN_USERNAME}" "${MKC_ADMIN_PASSWORD}")"
    btp_token="$(kc_token http://btp-keycloak:8080 "${BTP_ADMIN_USERNAME}" "${BTP_ADMIN_PASSWORD}")"
    CANONICAL_MKC_BASE="http://mkc-keycloak:8080"
    CANONICAL_MKC_TOKEN="${mkc_token}"
    canonical_snapshot http://ukc-keycloak:8080 ukc "${ukc_token}" | tee "${PROOFS_DIR}/ukc_snapshot.json"
    canonical_snapshot http://mkc-keycloak:8080 mkc "${mkc_token}" | tee "${PROOFS_DIR}/mkc_snapshot.json"
    canonical_snapshot http://btp-keycloak:8080 btp "${btp_token}" | tee "${PROOFS_DIR}/btp_snapshot.json"
    printf '%s\n' "${reconcile}" | jq '.mapping_summary' | tee "${PROOFS_DIR}/mapping_summary.json"
    assert_snapshot_equals "mkc" "${PROOFS_DIR}/ukc_snapshot.json" "${PROOFS_DIR}/mkc_snapshot.json"
    assert_snapshot_equals "btp" "${PROOFS_DIR}/ukc_snapshot.json" "${PROOFS_DIR}/btp_snapshot.json"
    ukc_hash="$(jq -cS '.' "${PROOFS_DIR}/ukc_snapshot.json" | sha256sum | awk '{print $1}')"
    mkc_hash="$(jq -cS '.' "${PROOFS_DIR}/mkc_snapshot.json" | sha256sum | awk '{print $1}')"
    btp_hash="$(jq -cS '.' "${PROOFS_DIR}/btp_snapshot.json" | sha256sum | awk '{print $1}')"
    jq -n \
      --arg ukc_hash "${ukc_hash}" \
      --arg mkc_hash "${mkc_hash}" \
      --arg btp_hash "${btp_hash}" \
      '{ukc_hash:$ukc_hash,mkc_hash:$mkc_hash,btp_hash:$btp_hash,validated:true}' \
      | tee "${PROOFS_DIR}/provisioning_validation.json"
    ;;
  provisioning-guardrail)
    set +e
    response="$(curl -sS -o /tmp/idlab-guardrail.out -w '%{http_code}' -X POST http://mkc-scim-facade:8080/scim/v2/Users \
      -H "Authorization: Bearer ${SCIM_BEARER_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:User"],"userName":"forbidden","externalId":"forbidden-password","active":true,"password":"Forbidden-123!"}')"
    rc=$?
    set -e
    body="$(cat /tmp/idlab-guardrail.out)"
    jq -n --arg status "${response}" --arg body "${body}" --arg rc "${rc}" \
      '{http_status:$status, curl_rc:$rc, body:$body}' | tee "${PROOFS_DIR}/provisioning_guardrail.json"
    [[ "${rc}" -eq 0 ]]
    [[ "${response}" == "400" ]]
    grep -qi 'credential fields are forbidden' <<<"${body}"
    ;;
  offline-enroll)
    mkc_token="$(kc_token http://mkc-keycloak:8080 "${MKC_ADMIN_USERNAME}" "${MKC_ADMIN_PASSWORD}")"
    user_id="$(kc_admin_get http://mkc-keycloak:8080 mkc "${mkc_token}" 'users?username=alice' | jq -r '.[0].id')"
    [ -f "${PROOFS_DIR}/online_debug.json" ] || { echo "missing online auth proof at ${PROOFS_DIR}/online_debug.json" >&2; exit 1; }
    [ -f "${PROOFS_DIR}/online_token_payload.json" ] || { echo "missing online token proof at ${PROOFS_DIR}/online_token_payload.json" >&2; exit 1; }
    online_debug="$(jq -c '.' "${PROOFS_DIR}/online_debug.json")"
    printf '%s\n' "${online_debug}" | jq -e '
      any(.[]; (.step == "follow:/broker/ukc/login") or (.step == "transition:/broker/ukc/login")) and
      any(.[]; .step == "ukc-login-form")
    ' >/dev/null || {
      echo "online auth proof does not show MKC -> UKC broker path" >&2
      exit 1
    }
    online_payload="$(jq -c '.' "${PROOFS_DIR}/online_token_payload.json")"
    kc_admin_put http://mkc-keycloak:8080 mkc "${mkc_token}" "users/${user_id}/reset-password" "{\"type\":\"password\",\"temporary\":false,\"value\":\"${ALICE_OFFLINE_PASSWORD}\"}"
    credentials="$(kc_admin_get http://mkc-keycloak:8080 mkc "${mkc_token}" "users/${user_id}/credentials")"
    printf '%s\n' "${credentials}" | jq -e 'any(.[]; .type == "password")' >/dev/null || {
      echo "alice password credential not visible after reset" >&2
      exit 1
    }
    jq -n \
      --arg user_id "${user_id}" \
      --argjson broker_trace "${online_debug}" \
      --argjson online_payload "${online_payload}" \
      --argjson credentials "${credentials}" \
      '{
        upstream_verification: {
          source: "proofs-pvc online auth artifacts",
          broker_trace: $broker_trace,
          online_token_payload: $online_payload
        },
        password_set_for_user_id: $user_id,
        mkc_credentials: $credentials
      }' | tee "${PROOFS_DIR}/offline_enroll_proof.json"
    ;;
  failover-manual)
    wait_stack
    controller_failover '{"failover_mode":"manual","manual_state":"offline","offline_writeable":false,"clear_return_latch":true}' >/dev/null
    reconcile="$(controller_reconcile)"
    status="$(controller_status)"
    assert_status "${status}" offline false
    printf '%s\n' "${reconcile}" | jq '.' | tee "${PROOFS_DIR}/manual_offline_reconcile.json"
    printf '%s\n' "${status}" | jq '.' | tee "${PROOFS_DIR}/manual_offline_status.json"
    ;;
  offline-write)
    wait_stack_offline
    controller_failover '{"failover_mode":"manual","manual_state":"offline","offline_writeable":true,"clear_return_latch":true}' >/dev/null
    controller_reconcile >/dev/null
    store_user_override "local-carol" "carol" >/dev/null
    store_group_override "local-ops" "grp_local_ops" >/dev/null
    store_membership_override "local-carol" "local-ops" >/dev/null
    reconcile="$(controller_reconcile)"
    status="$(controller_status)"
    assert_status "${status}" offline false
    mkc_token="$(kc_token http://mkc-keycloak:8080 "${MKC_ADMIN_USERNAME}" "${MKC_ADMIN_PASSWORD}")"
    btp_token="$(kc_token http://btp-keycloak:8080 "${BTP_ADMIN_USERNAME}" "${BTP_ADMIN_PASSWORD}")"
    carol_mkc_id="$(kc_admin_get http://mkc-keycloak:8080 mkc "${mkc_token}" 'users?username=carol' | jq -r '.[0].id')"
    [ -n "${carol_mkc_id}" ] && [ "${carol_mkc_id}" != "null" ]
    kc_admin_put http://mkc-keycloak:8080 mkc "${mkc_token}" "users/${carol_mkc_id}/reset-password" "{\"type\":\"password\",\"temporary\":false,\"value\":\"${CAROL_OFFLINE_PASSWORD}\"}"
    carol_btp_id="$(kc_admin_get http://btp-keycloak:8080 btp "${btp_token}" 'users?username=carol' | jq -r '.[0].id')"
    [ -n "${carol_btp_id}" ] && [ "${carol_btp_id}" != "null" ]
    group_btp_id="$(lookup_group_id_by_name http://btp-keycloak:8080 btp "${btp_token}" 'grp_local_ops')"
    [ -n "${group_btp_id}" ]
    mkc_membership_count="$(group_member_count_by_username http://mkc-keycloak:8080 mkc "${mkc_token}" 'grp_local_ops' 'carol')"
    btp_membership_count="$(group_member_count_by_username http://btp-keycloak:8080 btp "${btp_token}" 'grp_local_ops' 'carol')"
    [[ "${mkc_membership_count}" == "1" ]]
    [[ "${btp_membership_count}" == "1" ]]
    jq -n \
      --argjson reconcile "${reconcile}" \
      --argjson status "${status}" \
      --arg carol_mkc_id "${carol_mkc_id}" \
      --arg carol_btp_id "${carol_btp_id}" \
      --arg group_btp_id "${group_btp_id}" \
      --arg mkc_membership_count "${mkc_membership_count}" \
      --arg btp_membership_count "${btp_membership_count}" \
      '{reconcile:$reconcile,status:$status,carol_mkc_id:$carol_mkc_id,carol_btp_id:$carol_btp_id,group_btp_id:$group_btp_id,mkc_membership_count:$mkc_membership_count,btp_membership_count:$btp_membership_count}' \
      | tee "${PROOFS_DIR}/offline_write_proof.json"
    ;;
  failover-auto)
    scale_deployment_and_wait ukc-keycloak 1
    wait_stack
    controller_failover '{"failover_mode":"automatic","manual_state":"online","offline_writeable":false,"clear_return_latch":true}' >/dev/null
    before="$(controller_reconcile)"
    scale_deployment_and_wait ukc-keycloak 0
    trigger_upstream_push_allow_failure >/dev/null
    during="$(controller_reconcile)"
    during_status="$(controller_status)"
    assert_status "${during_status}" offline false
    scale_deployment_and_wait ukc-keycloak 1
    wait_ready http://ukc-keycloak:8080/realms/master/.well-known/openid-configuration
    trigger_upstream_push >/dev/null
    after="$(controller_reconcile)"
    after_status="$(controller_status)"
    assert_status "${after_status}" online true
    jq -n \
      --argjson before "${before}" \
      --argjson during "${during}" \
      --argjson during_status "${during_status}" \
      --argjson after "${after}" \
      --argjson after_status "${after_status}" \
      '{before:$before,during:$during,during_status:$during_status,after:$after,after_status:$after_status}' \
      | tee "${PROOFS_DIR}/auto_failover_proof.json"
    ;;
  failover-auto-manual-return)
    scale_deployment_and_wait ukc-keycloak 1
    wait_stack
    controller_failover '{"failover_mode":"automatic-manual-return","manual_state":"online","offline_writeable":true,"clear_return_latch":true}' >/dev/null
    controller_reconcile >/dev/null
    scale_deployment_and_wait ukc-keycloak 0
    trigger_upstream_push_allow_failure >/dev/null
    offline="$(controller_reconcile)"
    store_user_override "local-dora" "dora" >/dev/null
    store_group_override "local-latched" "grp_local_latched" >/dev/null
    store_membership_override "local-dora" "local-latched" >/dev/null
    latched="$(controller_reconcile)"
    scale_deployment_and_wait ukc-keycloak 1
    wait_ready http://ukc-keycloak:8080/realms/master/.well-known/openid-configuration
    trigger_upstream_push >/dev/null
    before_clear="$(controller_reconcile)"
    before_clear_status="$(controller_status)"
    assert_status "${before_clear_status}" offline false
    controller_failover '{"clear_return_latch":true}' >/dev/null
    after_clear="$(controller_reconcile)"
    after_clear_status="$(controller_status)"
    assert_status "${after_clear_status}" online true
    mkc_token="$(kc_token http://mkc-keycloak:8080 "${MKC_ADMIN_USERNAME}" "${MKC_ADMIN_PASSWORD}")"
    btp_token="$(kc_token http://btp-keycloak:8080 "${BTP_ADMIN_USERNAME}" "${BTP_ADMIN_PASSWORD}")"
    dora_mkc="$(kc_admin_get http://mkc-keycloak:8080 mkc "${mkc_token}" 'users?username=dora' | jq 'length')"
    dora_btp="$(kc_admin_get http://btp-keycloak:8080 btp "${btp_token}" 'users?username=dora' | jq 'length')"
    [ "${dora_mkc}" = "0" ]
    [ "${dora_btp}" = "0" ]
    jq -n \
      --argjson offline "${offline}" \
      --argjson latched "${latched}" \
      --argjson before_clear "${before_clear}" \
      --argjson before_clear_status "${before_clear_status}" \
      --argjson after_clear "${after_clear}" \
      --argjson after_clear_status "${after_clear_status}" \
      --arg dora_mkc "${dora_mkc}" \
      --arg dora_btp "${dora_btp}" \
      '{offline:$offline,latched:$latched,before_clear:$before_clear,before_clear_status:$before_clear_status,after_clear:$after_clear,after_clear_status:$after_clear_status,dora_mkc_count:$dora_mkc,dora_btp_count:$dora_btp}' \
      | tee "${PROOFS_DIR}/auto_manual_return_proof.json"
    ;;
  convergence)
    wait_stack
    controller_failover '{"failover_mode":"automatic","manual_state":"online","offline_writeable":false,"clear_return_latch":true}' >/dev/null
    controller_reconcile >/dev/null
    ukc_token="$(kc_token http://ukc-keycloak:8080 "${UKC_ADMIN_USERNAME}" "${UKC_ADMIN_PASSWORD}")"
    mkc_token="$(kc_token http://mkc-keycloak:8080 "${MKC_ADMIN_USERNAME}" "${MKC_ADMIN_PASSWORD}")"
    btp_token="$(kc_token http://btp-keycloak:8080 "${BTP_ADMIN_USERNAME}" "${BTP_ADMIN_PASSWORD}")"
    finance_id="$(lookup_group_id_by_name http://ukc-keycloak:8080 ukc "${ukc_token}" 'finance')"
    alice_id="$(lookup_user_id_by_username http://ukc-keycloak:8080 ukc "${ukc_token}" 'alice')"
    [[ -n "${finance_id}" && "${finance_id}" != "null" ]]
    [[ -n "${alice_id}" && "${alice_id}" != "null" ]]
    target_group_name="grp_${finance_id}"
    curl -fsS -X DELETE "http://ukc-keycloak:8080/admin/realms/ukc/users/${alice_id}/groups/${finance_id}" -H "Authorization: Bearer ${ukc_token}" >/dev/null || true
    trigger_upstream_push >/dev/null
    baseline="$(controller_reconcile)"
    before_mkc_count="$(group_member_count_by_username http://mkc-keycloak:8080 mkc "${mkc_token}" "${target_group_name}" 'alice')"
    before_btp_count="$(group_member_count_by_username http://btp-keycloak:8080 btp "${btp_token}" "${target_group_name}" 'alice')"
    [[ "${before_mkc_count}" == "0" ]]
    [[ "${before_btp_count}" == "0" ]]
    scale_deployment_and_wait sync-controller 0
    curl -fsS -X PUT "http://ukc-keycloak:8080/admin/realms/ukc/users/${alice_id}/groups/${finance_id}" -H "Authorization: Bearer ${ukc_token}" >/dev/null
    trigger_upstream_push >/dev/null
    frozen_mkc_count="$(group_member_count_by_username http://mkc-keycloak:8080 mkc "${mkc_token}" "${target_group_name}" 'alice')"
    frozen_btp_count="$(group_member_count_by_username http://btp-keycloak:8080 btp "${btp_token}" "${target_group_name}" 'alice')"
    [[ "${frozen_mkc_count}" == "0" ]]
    [[ "${frozen_btp_count}" == "0" ]]
    scale_deployment_and_wait sync-controller 1
    wait_ready http://sync-controller:8080/healthz
    after="$(controller_reconcile)"
    after_mkc_count="$(group_member_count_by_username http://mkc-keycloak:8080 mkc "${mkc_token}" "${target_group_name}" 'alice')"
    after_btp_count="$(group_member_count_by_username http://btp-keycloak:8080 btp "${btp_token}" "${target_group_name}" 'alice')"
    [[ "${after_mkc_count}" == "1" ]]
    [[ "${after_btp_count}" == "1" ]]
    reset_status="$(controller_status)"
    assert_status "${reset_status}" online true
    jq -n \
      --arg target_group_name "${target_group_name}" \
      --argjson baseline "${baseline}" \
      --arg frozen_mkc_count "${frozen_mkc_count}" \
      --arg frozen_btp_count "${frozen_btp_count}" \
      --argjson after "${after}" \
      --arg after_mkc_count "${after_mkc_count}" \
      --arg after_btp_count "${after_btp_count}" \
      --argjson reset_status "${reset_status}" \
      '{target_group_name:$target_group_name,baseline:$baseline,frozen:{mkc_membership_count:$frozen_mkc_count,btp_membership_count:$frozen_btp_count},after:$after,after_membership:{mkc_membership_count:$after_mkc_count,btp_membership_count:$after_btp_count},reset_status:$reset_status}' \
      | tee "${PROOFS_DIR}/convergence_proof.json"
    ;;
  *)
    echo "unsupported MODE=${MODE}" >&2
    exit 1
    ;;
esac
