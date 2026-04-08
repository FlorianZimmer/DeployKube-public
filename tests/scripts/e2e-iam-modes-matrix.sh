#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/e2e-iam-modes-matrix.sh [options]

Goal:
  Run live IAM mode E2E validation by mutating singleton DeploymentConfig.spec.iam,
  then triggering existing Keycloak IAM CronJobs.

Profiles:
  quick  - hybrid happy-path sanity (fast PR signal)
  full   - standalone/downstream/hybrid matrix + fail-open/failback + ldap sync path

Important:
  - This script mutates DeploymentConfig.spec.iam and restores it on exit.
  - You MUST acknowledge mutation explicitly:
      --ack-config-mutation yes
    or:
      DK_IAM_E2E_ACK_CONFIG_MUTATION=yes

Options:
  --profile <quick|full>         Validation profile (default: full)
  --timeout <duration>           Per-job wait timeout (default: 25m)
  --settle-seconds <n>           Sleep after each config patch (default: 20)
  --deploymentconfig <name>      Target DeploymentConfig name (auto-detected when omitted)
  --iam-namespace <ns>           Namespace for keycloak-iam-sync/ldap-sync CronJobs (default: keycloak)
  --upstream-sim-namespace <ns>  Namespace for keycloak-upstream-sim-smoke (default: keycloak-upstream-sim)
  --run-upstream-sim <auto|yes|no>
                                 Whether full profile runs keycloak-upstream-sim smoke (default: auto)
  --freeze-deployment-config-controller <yes|no>
                                 Temporarily scale deployment-config-controller to 0 during test (default: no)
  --freeze-gitops-sync <yes|no>
                                 Temporarily disable Argo auto-sync for deployment-secrets-bundle during test (default: yes)
  --ack-config-mutation <yes|no> Explicitly allow DeploymentConfig mutation (required)
  --help                         Show this help

Environment knobs (optional):
  DK_IAM_E2E_ACK_CONFIG_MUTATION  Same as --ack-config-mutation
  DK_IAM_E2E_OIDC_ISSUER_URL      OIDC issuer URL used when missing in current config
  DK_IAM_E2E_HEALTHCHECK_URL      Healthy URL for hybrid checks
                                  (default: http://keycloak.keycloak.svc.cluster.local:8080/realms/master/.well-known/openid-configuration)
  DK_IAM_E2E_FAILOPEN_TEST_URL    Intentionally failing URL for fail-open check
                                  (default: http://127.0.0.1:9/.well-known/openid-configuration)
  DK_IAM_E2E_LDAP_URL             LDAP URL for ldap sync-mode assertion
                                  (default: ldaps://ldap.invalid:636)
  DK_IAM_E2E_RUN_UPSTREAM_SIM     Same as --run-upstream-sim
EOF
}

need() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: ${bin} not found" >&2
    exit 1
  fi
}

duration_to_seconds() {
  local d="$1"
  if [[ "${d}" =~ ^[0-9]+$ ]]; then
    echo "${d}"
    return 0
  fi
  if [[ "${d}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${d}" =~ ^([0-9]+)m$ ]]; then
    echo "$((BASH_REMATCH[1] * 60))"
    return 0
  fi
  if [[ "${d}" =~ ^([0-9]+)h$ ]]; then
    echo "$((BASH_REMATCH[1] * 3600))"
    return 0
  fi
  echo "error: unsupported duration '${d}' (use <n>, <n>s, <n>m, <n>h)" >&2
  exit 2
}

trunc_name() {
  local base="$1"
  local suffix="$2"
  local max=63
  local want="${base}-${suffix}"
  if [ "${#want}" -le "${max}" ]; then
    echo "${want}"
    return 0
  fi
  local keep=$((max - ${#suffix} - 1))
  if [ "${keep}" -lt 1 ]; then
    echo "error: suffix too long for k8s name: ${suffix}" >&2
    exit 1
  fi
  echo "${base:0:${keep}}-${suffix}"
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${context}: expected '${expected}', got '${actual}'" >&2
    return 1
  fi
}

assert_any_of() {
  local actual="$1"
  local context="$2"
  shift 2
  local expected
  for expected in "$@"; do
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
  done
  echo "FAIL: ${context}: unexpected value '${actual}' (allowed: $*)" >&2
  return 1
}

is_transient_job_failure() {
  local logs="$1"
  grep -Eiq \
    'The connection to the server .* was refused|i/o timeout|context deadline exceeded|TLS handshake timeout|timed out waiting|connect: connection refused|ServiceUnavailable|unexpected EOF' \
    <<<"${logs}"
}

wait_for_job_completion_or_failure() {
  local ns="$1"
  local job="$2"
  local timeout_seconds="$3"

  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi

  for _ in $(seq 1 "${loops}"); do
    local json
    json="$(kubectl -n "${ns}" get job "${job}" -o json 2>/dev/null || true)"
    if [ -z "${json}" ]; then
      sleep 2
      continue
    fi

    local complete failed
    complete="$(jq -r '.status.conditions[]? | select(.type=="Complete" and .status=="True") | .type' <<<"${json}")"
    failed="$(jq -r '.status.conditions[]? | select(.type=="Failed" and .status=="True") | .type' <<<"${json}")"

    if [ -n "${complete}" ]; then
      return 0
    fi
    if [ -n "${failed}" ]; then
      return 1
    fi

    sleep 2
  done

  return 1
}

read_configmap_data_key() {
  local ns="$1"
  local name="$2"
  local key="$3"
  kubectl -n "${ns}" get configmap "${name}" -o json 2>/dev/null | jq -r --arg k "${key}" '.data[$k] // ""'
}

profile="full"
timeout="25m"
settle_seconds="20"
deploymentconfig_name=""
iam_namespace="keycloak"
upstream_sim_namespace="keycloak-upstream-sim"
run_upstream_sim="${DK_IAM_E2E_RUN_UPSTREAM_SIM:-auto}"
ack_config_mutation="${DK_IAM_E2E_ACK_CONFIG_MUTATION:-no}"
freeze_deployment_config_controller="${DK_IAM_E2E_FREEZE_DEPLOYMENT_CONFIG_CONTROLLER:-no}"
deployment_config_controller_namespace="argocd"
deployment_config_controller_name="deployment-config-controller"
dcc_original_replicas=""
dcc_frozen=0
freeze_gitops_sync="${DK_IAM_E2E_FREEZE_GITOPS_SYNC:-yes}"
gitops_app_namespace="argocd"
gitops_root_app_name="platform-apps"
gitops_root_original_automated_json=""
gitops_leaf_app_name="deployment-secrets-bundle"
gitops_leaf_original_automated_json=""
gitops_sync_paused=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --timeout)
      timeout="${2:-}"
      shift 2
      ;;
    --settle-seconds)
      settle_seconds="${2:-}"
      shift 2
      ;;
    --deploymentconfig)
      deploymentconfig_name="${2:-}"
      shift 2
      ;;
    --iam-namespace)
      iam_namespace="${2:-}"
      shift 2
      ;;
    --upstream-sim-namespace)
      upstream_sim_namespace="${2:-}"
      shift 2
      ;;
    --run-upstream-sim)
      run_upstream_sim="${2:-}"
      shift 2
      ;;
    --ack-config-mutation)
      ack_config_mutation="${2:-}"
      shift 2
      ;;
    --freeze-deployment-config-controller)
      freeze_deployment_config_controller="${2:-}"
      shift 2
      ;;
    --freeze-gitops-sync)
      freeze_gitops_sync="${2:-}"
      shift 2
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

need kubectl
need jq

if [[ ! "${settle_seconds}" =~ ^[0-9]+$ ]]; then
  echo "error: --settle-seconds must be an integer (got '${settle_seconds}')" >&2
  exit 2
fi

case "${profile}" in
  quick|full) ;;
  *)
    echo "error: --profile must be quick|full (got '${profile}')" >&2
    exit 2
    ;;
esac

case "${run_upstream_sim}" in
  auto|yes|no) ;;
  *)
    echo "error: --run-upstream-sim must be auto|yes|no (got '${run_upstream_sim}')" >&2
    exit 2
    ;;
esac

case "${freeze_deployment_config_controller}" in
  yes|no) ;;
  *)
    echo "error: --freeze-deployment-config-controller must be yes|no (got '${freeze_deployment_config_controller}')" >&2
    exit 2
    ;;
esac
case "${freeze_gitops_sync}" in
  yes|no) ;;
  *)
    echo "error: --freeze-gitops-sync must be yes|no (got '${freeze_gitops_sync}')" >&2
    exit 2
    ;;
esac

if [ "${ack_config_mutation}" != "yes" ]; then
  echo "error: refusing to mutate DeploymentConfig without explicit ack (--ack-config-mutation yes)" >&2
  exit 2
fi

timeout_seconds="$(duration_to_seconds "${timeout}")"
run_id="$(date -u +%Y%m%d%H%M%S)"

dep_cfg_json="$(kubectl get deploymentconfigs.platform.darksite.cloud -o json 2>/dev/null || true)"
if [ -z "${dep_cfg_json}" ]; then
  echo "error: could not read deploymentconfigs.platform.darksite.cloud" >&2
  exit 1
fi
dep_cfg_count="$(jq -r '.items | length' <<<"${dep_cfg_json}")"
if [ "${dep_cfg_count}" -ne 1 ]; then
  echo "error: expected exactly one DeploymentConfig, found ${dep_cfg_count}" >&2
  exit 1
fi

if [ -z "${deploymentconfig_name}" ]; then
  deploymentconfig_name="$(jq -r '.items[0].metadata.name' <<<"${dep_cfg_json}")"
fi
if [ -z "${deploymentconfig_name}" ]; then
  echo "error: missing deploymentconfig name" >&2
  exit 2
fi

original_iam_json="$(jq -c '.items[0].spec.iam // {}' <<<"${dep_cfg_json}")"
if [ -z "${original_iam_json}" ] || [ "${original_iam_json}" = "null" ]; then
  original_iam_json="{}"
fi

detected_oidc_issuer="$(jq -r '.items[0].spec.iam.upstream.oidc.issuerUrl // ""' <<<"${dep_cfg_json}")"
oidc_issuer_url="${DK_IAM_E2E_OIDC_ISSUER_URL:-${detected_oidc_issuer:-}}"
if [ -z "${oidc_issuer_url}" ]; then
  oidc_issuer_url="http://keycloak.keycloak.svc.cluster.local:8080/realms/master"
fi

healthcheck_url="${DK_IAM_E2E_HEALTHCHECK_URL:-http://keycloak.keycloak.svc.cluster.local:8080/realms/master/.well-known/openid-configuration}"
failopen_test_url="${DK_IAM_E2E_FAILOPEN_TEST_URL:-http://127.0.0.1:9/.well-known/openid-configuration}"
ldap_url="${DK_IAM_E2E_LDAP_URL:-ldaps://ldap.invalid:636}"

mutated=0
restore_original_iam() {
  if [ "${mutated}" -eq 0 ]; then
    return 0
  fi
  echo ""
  echo "==> Restoring original spec.iam on DeploymentConfig/${deploymentconfig_name}"
  local patch_payload
  patch_payload="$(jq -cn --argjson iam "${original_iam_json}" '[{"op":"replace","path":"/spec/iam","value":$iam}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    sleep "${settle_seconds}"
    echo "   restore complete"
    return 0
  fi

  patch_payload="$(jq -cn --argjson iam "${original_iam_json}" '[{"op":"add","path":"/spec/iam","value":$iam}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  sleep "${settle_seconds}"
  echo "   restore complete"
}

freeze_deployment_config_controller_for_test() {
  if [ "${freeze_deployment_config_controller}" != "yes" ]; then
    return 0
  fi
  if ! kubectl -n "${deployment_config_controller_namespace}" get deployment "${deployment_config_controller_name}" >/dev/null 2>&1; then
    echo "WARN: deployment ${deployment_config_controller_namespace}/${deployment_config_controller_name} not found; continuing without freeze" >&2
    return 0
  fi

  dcc_original_replicas="$(
    kubectl -n "${deployment_config_controller_namespace}" get deployment "${deployment_config_controller_name}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"
  if [ -z "${dcc_original_replicas}" ]; then
    dcc_original_replicas="1"
  fi

  if [ "${dcc_original_replicas}" = "0" ]; then
    echo "==> deployment-config-controller already scaled to 0; leaving as-is during matrix run"
    dcc_frozen=1
    return 0
  fi

  echo "==> Freezing ${deployment_config_controller_namespace}/${deployment_config_controller_name} (replicas ${dcc_original_replicas} -> 0) for mutation test"
  kubectl -n "${deployment_config_controller_namespace}" scale deployment "${deployment_config_controller_name}" --replicas=0 >/dev/null
  kubectl -n "${deployment_config_controller_namespace}" rollout status deployment "${deployment_config_controller_name}" --timeout=180s >/dev/null
  dcc_frozen=1
}

restore_deployment_config_controller_after_test() {
  if [ "${dcc_frozen}" -eq 0 ]; then
    return 0
  fi
  if [ "${freeze_deployment_config_controller}" != "yes" ]; then
    return 0
  fi
  if [ -z "${dcc_original_replicas}" ] || [ "${dcc_original_replicas}" = "0" ]; then
    return 0
  fi
  echo "==> Restoring ${deployment_config_controller_namespace}/${deployment_config_controller_name} replicas to ${dcc_original_replicas}"
  kubectl -n "${deployment_config_controller_namespace}" scale deployment "${deployment_config_controller_name}" --replicas="${dcc_original_replicas}" >/dev/null || true
  kubectl -n "${deployment_config_controller_namespace}" rollout status deployment "${deployment_config_controller_name}" --timeout=180s >/dev/null || true
}

pause_gitops_sync_for_test() {
  if [ "${freeze_gitops_sync}" != "yes" ]; then
    return 0
  fi

  if kubectl -n "${gitops_app_namespace}" get application "${gitops_root_app_name}" >/dev/null 2>&1; then
    gitops_root_original_automated_json="$(
      kubectl -n "${gitops_app_namespace}" get application "${gitops_root_app_name}" -o json | jq -c '.spec.syncPolicy.automated // null'
    )"
    if [ "${gitops_root_original_automated_json}" != "null" ]; then
      echo "==> Freezing Argo auto-sync on ${gitops_app_namespace}/${gitops_root_app_name}"
      kubectl -n "${gitops_app_namespace}" patch application "${gitops_root_app_name}" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      gitops_sync_paused=1
    else
      echo "==> Argo auto-sync already disabled on ${gitops_app_namespace}/${gitops_root_app_name}; leaving as-is"
    fi
  else
    echo "WARN: Argo Application ${gitops_app_namespace}/${gitops_root_app_name} not found; continuing without root sync freeze" >&2
  fi

  if kubectl -n "${gitops_app_namespace}" get application "${gitops_leaf_app_name}" >/dev/null 2>&1; then
    gitops_leaf_original_automated_json="$(
      kubectl -n "${gitops_app_namespace}" get application "${gitops_leaf_app_name}" -o json | jq -c '.spec.syncPolicy.automated // null'
    )"
    if [ "${gitops_leaf_original_automated_json}" != "null" ]; then
      echo "==> Freezing Argo auto-sync on ${gitops_app_namespace}/${gitops_leaf_app_name}"
      kubectl -n "${gitops_app_namespace}" patch application "${gitops_leaf_app_name}" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      gitops_sync_paused=1
    else
      echo "==> Argo auto-sync already disabled on ${gitops_app_namespace}/${gitops_leaf_app_name}; leaving as-is"
    fi
  else
    echo "WARN: Argo Application ${gitops_app_namespace}/${gitops_leaf_app_name} not found; continuing without leaf sync freeze" >&2
  fi
}

restore_gitops_sync_after_test() {
  if [ "${gitops_sync_paused}" -eq 0 ]; then
    return 0
  fi
  if [ "${freeze_gitops_sync}" != "yes" ]; then
    return 0
  fi
  if [ -n "${gitops_leaf_original_automated_json}" ] && [ "${gitops_leaf_original_automated_json}" != "null" ]; then
    echo "==> Restoring Argo auto-sync on ${gitops_app_namespace}/${gitops_leaf_app_name}"
    local leaf_patch_payload
    leaf_patch_payload="$(jq -cn --argjson automated "${gitops_leaf_original_automated_json}" '{"spec":{"syncPolicy":{"automated":$automated}}}')"
    kubectl -n "${gitops_app_namespace}" patch application "${gitops_leaf_app_name}" --type merge -p "${leaf_patch_payload}" >/dev/null || true
  fi

  if [ -n "${gitops_root_original_automated_json}" ] && [ "${gitops_root_original_automated_json}" != "null" ]; then
    echo "==> Restoring Argo auto-sync on ${gitops_app_namespace}/${gitops_root_app_name}"
    local root_patch_payload
    root_patch_payload="$(jq -cn --argjson automated "${gitops_root_original_automated_json}" '{"spec":{"syncPolicy":{"automated":$automated}}}')"
    kubectl -n "${gitops_app_namespace}" patch application "${gitops_root_app_name}" --type merge -p "${root_patch_payload}" >/dev/null || true
  fi
}

cleanup() {
  restore_original_iam
  restore_deployment_config_controller_after_test
  restore_gitops_sync_after_test
}
trap cleanup EXIT

patch_iam_replace() {
  local iam_json="$1"
  local patch_payload
  patch_payload="$(jq -cn --argjson iam "${iam_json}" '[{"op":"replace","path":"/spec/iam","value":$iam}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    mutated=1
    return 0
  fi
  patch_payload="$(jq -cn --argjson iam "${iam_json}" '[{"op":"add","path":"/spec/iam","value":$iam}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  mutated=1
}

run_cronjob_once() {
  local ns="$1"
  local cronjob="$2"
  local phase="$3"
  local expect_log_substr="${4:-}"
  local max_attempts="${5:-3}"

  local attempt
  for attempt in $(seq 1 "${max_attempts}"); do
    local ns_slug
    ns_slug="$(echo "${ns}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
    local suffix="${phase}-${run_id}-a${attempt}"
    local job_name
    job_name="$(trunc_name "${cronjob}-${ns_slug}" "${suffix}")"

    echo "   - ${ns}/CronJob/${cronjob} -> Job/${job_name} (attempt ${attempt}/${max_attempts})"
    kubectl -n "${ns}" create job --from=cronjob/"${cronjob}" "${job_name}" >/dev/null

    local logs
    if ! wait_for_job_completion_or_failure "${ns}" "${job_name}" "${timeout_seconds}"; then
      logs="$(kubectl -n "${ns}" logs "job/${job_name}" --tail=2000 2>/dev/null || true)"
      if [ "${attempt}" -lt "${max_attempts}" ] && is_transient_job_failure "${logs}"; then
        sleep "$((attempt * 5))"
        continue
      fi
      echo "FAIL: job did not complete successfully: ${ns}/Job/${job_name}" >&2
      kubectl -n "${ns}" describe job "${job_name}" >&2 || true
      printf '%s\n' "${logs}" >&2
      return 1
    fi

    logs="$(kubectl -n "${ns}" logs "job/${job_name}" --tail=2000 2>/dev/null || true)"
    if [ -n "${expect_log_substr}" ] && ! grep -Fq -- "${expect_log_substr}" <<<"${logs}"; then
      echo "FAIL: expected log pattern not found (${cronjob}/${phase}): ${expect_log_substr}" >&2
      return 1
    fi
    return 0
  done

  return 1
}

base_realms_json() {
  jq -cn --argjson base "${original_iam_json}" '
    ($base // {}) as $b
    | {
        primaryRealm: ($b.primaryRealm // "deploykube-admin")
      }
    | if (($b.secondaryRealms // []) | length) > 0 then
        .secondaryRealms = $b.secondaryRealms
      else
        .
      end
  '
}

build_standalone_iam_json() {
  local realms
  realms="$(base_realms_json)"
  jq -cn --argjson realms "${realms}" '
    $realms + {mode: "standalone"}
  '
}

build_oidc_mode_iam_json() {
  local mode="$1"
  local health_url="$2"
  local realms
  realms="$(base_realms_json)"

  jq -cn \
    --argjson base "${original_iam_json}" \
    --argjson realms "${realms}" \
    --arg mode "${mode}" \
    --arg issuer "${oidc_issuer_url}" \
    --arg health_url "${health_url}" '
    ($base // {}) as $b
    | ($b.upstream // {}) as $upstream
    | ($b.hybrid // {}) as $hybrid
    | ($upstream.oidc // {}) as $oidc
    | ($hybrid.offlineCredential // {}) as $offline
    | ($realms + {mode: $mode}) as $root
    | $root
    | .upstream = (
        $upstream
        + {
            type: "oidc",
            alias: ($upstream.alias // "upstream"),
            displayName: ($upstream.displayName // "Upstream OIDC")
          }
      )
    | .upstream.oidc = (
        $oidc
        + {
            issuerUrl: ($oidc.issuerUrl // $issuer),
            clientId: ($oidc.clientId // "deploykube-upstream-broker")
          }
      )
    | if $mode == "hybrid" then
        .hybrid = (
          $hybrid
          + {
              failOpen: true,
              healthCheck: {
                type: "http",
                url: $health_url,
                timeoutSeconds: 5,
                intervalSeconds: 60,
                successThreshold: 1,
                failureThreshold: 1
              }
            }
        )
        | if ($offline | length) > 0 then .hybrid.offlineCredential = $offline else . end
      else
        del(.hybrid)
      end
    | if (.upstream.alias // "") == "" then .upstream.alias = "upstream" else . end
    | if (.upstream.displayName // "") == "" then .upstream.displayName = "Upstream OIDC" else . end
    | if (.upstream.oidc.issuerUrl // "") == "" then .upstream.oidc.issuerUrl = $issuer else . end
    | if (.upstream.oidc.clientId // "") == "" then .upstream.oidc.clientId = "deploykube-upstream-broker" else . end
  '
}

build_ldap_sync_iam_json() {
  local realms
  realms="$(base_realms_json)"

  jq -cn \
    --argjson base "${original_iam_json}" \
    --argjson realms "${realms}" \
    --arg ldap_url "${ldap_url}" '
    ($base // {}) as $b
    | ($b.upstream // {}) as $upstream
    | ($upstream.ldap // {}) as $ldap
    | ($realms + {mode: "downstream"}) as $root
    | $root
    | .upstream = (
        $upstream
        + {
            type: "ldap",
            alias: ($upstream.alias // "upstream"),
            displayName: ($upstream.displayName // "Upstream LDAP")
          }
      )
    | .upstream.ldap = (
        $ldap
        + {
            url: ($ldap.url // $ldap_url),
            operationMode: "sync"
          }
      )
    | del(.hybrid)
    | if (.upstream.alias // "") == "" then .upstream.alias = "upstream" else . end
    | if (.upstream.displayName // "") == "" then .upstream.displayName = "Upstream LDAP" else . end
    | if (.upstream.ldap.url // "") == "" then .upstream.ldap.url = $ldap_url else . end
  '
}

assert_iam_sync_status() {
  local expected_mode="$1"
  local expected_state="$2"
  local expected_reason="$3"
  local expected_redirect_state="${4:-}"
  local expected_health_result="${5:-}"

  local mode state reason redirect_state health_result
  mode="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "mode")"
  state="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "state")"
  reason="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "reason")"

  assert_equals "${mode}" "${expected_mode}" "iam-sync status.mode"
  assert_equals "${state}" "${expected_state}" "iam-sync status.state"
  assert_equals "${reason}" "${expected_reason}" "iam-sync status.reason"

  if [ -n "${expected_redirect_state}" ]; then
    redirect_state="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "redirectState")"
    assert_equals "${redirect_state}" "${expected_redirect_state}" "iam-sync status.redirectState"
  fi
  if [ -n "${expected_health_result}" ]; then
    health_result="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "health.result")"
    assert_equals "${health_result}" "${expected_health_result}" "iam-sync status.health.result"
  fi
}

assert_ldap_sync_status() {
  local expected_mode="$1"
  local expected_upstream_type="$2"
  local expected_state="$3"
  local expected_reason="$4"
  local expected_ldap_mode="${5:-}"

  local mode upstream_type state reason ldap_mode
  mode="$(read_configmap_data_key "${iam_namespace}" "keycloak-ldap-sync-status" "mode")"
  upstream_type="$(read_configmap_data_key "${iam_namespace}" "keycloak-ldap-sync-status" "upstream.type")"
  state="$(read_configmap_data_key "${iam_namespace}" "keycloak-ldap-sync-status" "state")"
  reason="$(read_configmap_data_key "${iam_namespace}" "keycloak-ldap-sync-status" "reason")"

  assert_equals "${mode}" "${expected_mode}" "ldap-sync status.mode"
  assert_equals "${upstream_type}" "${expected_upstream_type}" "ldap-sync status.upstream.type"
  assert_equals "${state}" "${expected_state}" "ldap-sync status.state"
  assert_equals "${reason}" "${expected_reason}" "ldap-sync status.reason"

  if [ -n "${expected_ldap_mode}" ]; then
    ldap_mode="$(read_configmap_data_key "${iam_namespace}" "keycloak-ldap-sync-status" "ldap.operationMode")"
    assert_equals "${ldap_mode}" "${expected_ldap_mode}" "ldap-sync status.ldap.operationMode"
  fi
}

run_iam_sync_for_expected_mode() {
  local expected_mode="$1"
  local phase="$2"
  local attempts="${3:-4}"
  local attempt mode
  for attempt in $(seq 1 "${attempts}"); do
    run_cronjob_once "${iam_namespace}" "keycloak-iam-sync" "${phase}-m${attempt}"
    mode="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "mode")"
    if [[ "${mode}" == "${expected_mode}" ]]; then
      return 0
    fi
    if [ "${attempt}" -lt "${attempts}" ]; then
      sleep "${settle_seconds}"
    fi
  done
  echo "FAIL: keycloak-iam-sync status.mode did not converge to '${expected_mode}'" >&2
  kubectl -n "${iam_namespace}" get configmap keycloak-iam-sync-status -o yaml >&2 || true
  return 1
}

run_ldap_sync_for_expected_mode() {
  local expected_mode="$1"
  local phase="$2"
  local attempts="${3:-4}"
  local attempt mode
  for attempt in $(seq 1 "${attempts}"); do
    run_cronjob_once "${iam_namespace}" "keycloak-ldap-sync" "${phase}-m${attempt}"
    mode="$(read_configmap_data_key "${iam_namespace}" "keycloak-ldap-sync-status" "mode")"
    if [[ "${mode}" == "${expected_mode}" ]]; then
      return 0
    fi
    if [ "${attempt}" -lt "${attempts}" ]; then
      sleep "${settle_seconds}"
    fi
  done
  echo "FAIL: keycloak-ldap-sync status.mode did not converge to '${expected_mode}'" >&2
  kubectl -n "${iam_namespace}" get configmap keycloak-ldap-sync-status -o yaml >&2 || true
  return 1
}

run_quick_profile() {
  local iam_json
  echo ""
  echo "==> quick profile: hybrid happy-path sanity"
  iam_json="$(build_oidc_mode_iam_json "hybrid" "${healthcheck_url}")"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"

  run_cronjob_once "${iam_namespace}" "keycloak-iam-sync" "quick-hybrid"

  local mode state reason redirect_state
  mode="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "mode")"
  state="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "state")"
  reason="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "reason")"
  redirect_state="$(read_configmap_data_key "${iam_namespace}" "keycloak-iam-sync-status" "redirectState")"

  assert_equals "${mode}" "hybrid" "iam-sync status.mode (quick)"
  assert_equals "${state}" "applied" "iam-sync status.state (quick)"
  assert_any_of "${reason}" "iam-sync status.reason (quick)" "upstream-preferred" "local-visible"
  assert_any_of "${redirect_state}" "iam-sync status.redirectState (quick)" "upstream" "local"
}

run_full_profile() {
  local iam_json
  local run_upstream_sim_now="no"

  echo ""
  echo "==> full profile: standalone/downstream/hybrid + fail-open/failback + ldap sync"

  iam_json="$(build_standalone_iam_json)"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"
  run_iam_sync_for_expected_mode "standalone" "full-standalone-iam"
  assert_iam_sync_status "standalone" "skipped" "iam-mode-not-hybrid"
  run_ldap_sync_for_expected_mode "standalone" "full-standalone-ldap"
  assert_ldap_sync_status "standalone" "" "skipped" "upstream-not-ldap"

  iam_json="$(build_oidc_mode_iam_json "downstream" "${healthcheck_url}")"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"
  run_iam_sync_for_expected_mode "downstream" "full-downstream-iam"
  assert_iam_sync_status "downstream" "skipped" "iam-mode-not-hybrid"

  iam_json="$(build_oidc_mode_iam_json "hybrid" "${healthcheck_url}")"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"
  run_iam_sync_for_expected_mode "hybrid" "full-hybrid-healthy"
  assert_iam_sync_status "hybrid" "applied" "upstream-preferred" "upstream" "healthy"

  case "${run_upstream_sim}" in
    yes) run_upstream_sim_now="yes" ;;
    no) run_upstream_sim_now="no" ;;
    auto)
      if kubectl -n "${upstream_sim_namespace}" get cronjob keycloak-upstream-sim-smoke >/dev/null 2>&1; then
        run_upstream_sim_now="yes"
      else
        run_upstream_sim_now="no"
      fi
      ;;
  esac

  if [[ "${run_upstream_sim_now}" == "yes" ]]; then
    run_cronjob_once "${upstream_sim_namespace}" "keycloak-upstream-sim-smoke" "full-upstream-sim" "upstream simulation smoke check completed"
    local sim_status
    sim_status="$(read_configmap_data_key "${upstream_sim_namespace}" "keycloak-upstream-sim-smoke-status" "status")"
    assert_equals "${sim_status}" "ready" "upstream-sim smoke status"
  else
    echo "   - skipping upstream-sim smoke (mode=${run_upstream_sim})"
  fi

  iam_json="$(build_oidc_mode_iam_json "hybrid" "${failopen_test_url}")"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"
  run_iam_sync_for_expected_mode "hybrid" "full-hybrid-failopen"
  assert_iam_sync_status "hybrid" "applied" "local-visible" "local" "unhealthy"

  iam_json="$(build_oidc_mode_iam_json "hybrid" "${healthcheck_url}")"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"
  run_iam_sync_for_expected_mode "hybrid" "full-hybrid-failback"
  assert_iam_sync_status "hybrid" "applied" "upstream-preferred" "upstream" "healthy"

  iam_json="$(build_ldap_sync_iam_json)"
  patch_iam_replace "${iam_json}"
  sleep "${settle_seconds}"
  run_ldap_sync_for_expected_mode "downstream" "full-ldap-sync"
  assert_ldap_sync_status "downstream" "ldap" "applied" "ldap-full-sync-triggered" "sync"
}

echo "==> IAM mode E2E matrix"
echo "Profile: ${profile}"
echo "DeploymentConfig: ${deploymentconfig_name}"
echo "IAM namespace: ${iam_namespace}"
echo "Upstream-sim namespace: ${upstream_sim_namespace}"
echo "Run upstream-sim: ${run_upstream_sim}"
echo "Freeze deployment-config-controller: ${freeze_deployment_config_controller}"
echo "Freeze GitOps sync: ${freeze_gitops_sync}"
echo "Timeout/job: ${timeout}"

pause_gitops_sync_for_test
freeze_deployment_config_controller_for_test

case "${profile}" in
  quick) run_quick_profile ;;
  full) run_full_profile ;;
esac

echo ""
echo "IAM mode E2E matrix PASSED (${profile})"
