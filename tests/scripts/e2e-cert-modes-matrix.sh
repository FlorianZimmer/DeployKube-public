#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/e2e-cert-modes-matrix.sh [options]

Goal:
  Run live E2E validation for certificate modes by mutating the singleton DeploymentConfig,
  then triggering the existing certificate smoke CronJobs.

Default modes:
  subCa,acme,wildcard

Important:
  - This script mutates DeploymentConfig.spec.certificates and restores it on exit.
  - You MUST acknowledge mutation explicitly:
      --ack-config-mutation yes
    or:
      DK_CERT_E2E_ACK_CONFIG_MUTATION=yes

Options:
  --modes <csv>                  Comma-separated list from {subCa,acme,wildcard}
  --timeout <duration>           Per-smoke-job wait timeout (default: 25m)
  --settle-seconds <n>           Sleep after each mode patch (default: 20)
  --deploymentconfig <name>      Target DeploymentConfig name (auto-detected when omitted)
  --smoke-namespace <ns>         Namespace for cert smoke CronJobs (default: cert-manager)
  --freeze-deployment-config-controller <yes|no>
                                 Temporarily scale deployment-config-controller to 0 during test (default: yes)
  --freeze-gitops-sync <yes|no>
                                 Temporarily disable Argo auto-sync for deployment-secrets-bundle during test (default: yes)
  --ack-config-mutation <yes|no> Explicitly allow DeploymentConfig mutation (required)
  --help                         Show this help

Environment for ACME mode (required when acme is selected):
  DK_CERT_E2E_ACME_SERVER
  DK_CERT_E2E_ACME_EMAIL
  DK_CERT_E2E_ACME_CA_BUNDLE                 (optional base64 PEM bundle for self-hosted ACME)
  DK_CERT_E2E_ACME_PROVIDER                  (default: rfc2136; allowed: rfc2136|cloudflare|route53)
  DK_CERT_E2E_ACME_CLUSTER_ISSUER_NAME       (optional, default: acme)
  DK_CERT_E2E_ACME_PRIVATE_KEY_SECRET_NAME   (optional)
  DK_CERT_E2E_ACME_CREDENTIALS_SECRET_NAME   (optional)
  DK_CERT_E2E_ACME_CREDENTIALS_EXTERNAL_SECRET_NAME (optional)
  DK_CERT_E2E_ACME_CREDENTIALS_VAULT_PATH    (required for rfc2136/cloudflare; optional for route53)
  DK_CERT_E2E_ACME_RFC2136_NAMESERVER        (required for provider=rfc2136)
  DK_CERT_E2E_ACME_RFC2136_TSIG_KEY_NAME     (required for provider=rfc2136)
  DK_CERT_E2E_ACME_RFC2136_TSIG_ALGORITHM    (optional)
  DK_CERT_E2E_ACME_TSIG_SECRET_PROPERTY      (optional)
  DK_CERT_E2E_ACME_CLOUDFLARE_EMAIL          (optional for provider=cloudflare)
  DK_CERT_E2E_ACME_CLOUDFLARE_API_TOKEN_PROPERTY (optional for provider=cloudflare)
  DK_CERT_E2E_ACME_ROUTE53_REGION            (required for provider=route53)
  DK_CERT_E2E_ACME_ROUTE53_HOSTED_ZONE_ID    (optional for provider=route53)
  DK_CERT_E2E_ACME_ROUTE53_ROLE              (optional for provider=route53)
  DK_CERT_E2E_ACME_ROUTE53_ACCESS_KEY_ID_PROPERTY (optional for provider=route53)
  DK_CERT_E2E_ACME_ROUTE53_SECRET_ACCESS_KEY_PROPERTY (optional for provider=route53)

Environment for Wildcard mode (required when wildcard is selected):
  DK_CERT_E2E_WILDCARD_VAULT_PATH
  DK_CERT_E2E_WILDCARD_SECRET_NAME                 (optional)
  DK_CERT_E2E_WILDCARD_EXTERNAL_SECRET_NAME        (optional)
  DK_CERT_E2E_WILDCARD_TLS_CERT_PROPERTY           (optional)
  DK_CERT_E2E_WILDCARD_TLS_KEY_PROPERTY            (optional)
  DK_CERT_E2E_WILDCARD_CA_BUNDLE_SECRET_NAME       (optional)
  DK_CERT_E2E_WILDCARD_CA_BUNDLE_EXTERNAL_SECRET_NAME (optional)
  DK_CERT_E2E_WILDCARD_CA_BUNDLE_VAULT_PATH        (optional)
  DK_CERT_E2E_WILDCARD_CA_BUNDLE_PROPERTY          (optional)
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

require_nonempty() {
  local value="$1"
  local label="$2"
  if [ -z "${value}" ]; then
    echo "error: missing required value: ${label}" >&2
    exit 2
  fi
}

normalize_mode() {
  local raw="$1"
  case "${raw}" in
    subCa|subca|SUBCA) echo "subCa" ;;
    vault|VAULT) echo "vault" ;;
    acme|ACME) echo "acme" ;;
    wildcard|WILDCARD) echo "wildcard" ;;
    *)
      echo "error: unsupported mode '${raw}' (allowed: subCa|vault|acme|wildcard)" >&2
      exit 2
      ;;
  esac
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

modes_csv="subCa,acme,wildcard"
timeout="25m"
settle_seconds="20"
deploymentconfig_name=""
smoke_namespace="cert-manager"
ack_config_mutation="${DK_CERT_E2E_ACK_CONFIG_MUTATION:-no}"
freeze_deployment_config_controller="${DK_CERT_E2E_FREEZE_DEPLOYMENT_CONFIG_CONTROLLER:-yes}"
deployment_config_controller_namespace="argocd"
deployment_config_controller_name="deployment-config-controller"
dcc_original_replicas=""
dcc_frozen=0
freeze_gitops_sync="${DK_CERT_E2E_FREEZE_GITOPS_SYNC:-yes}"
gitops_app_namespace="argocd"
gitops_root_app_name="platform-apps"
gitops_root_original_automated_json=""
gitops_leaf_app_name="deployment-secrets-bundle"
gitops_leaf_original_automated_json=""
gitops_sync_paused=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modes)
      modes_csv="${2:-}"
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
    --smoke-namespace)
      smoke_namespace="${2:-}"
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

if [ "${ack_config_mutation}" != "yes" ]; then
  echo "error: refusing to mutate DeploymentConfig without explicit ack (--ack-config-mutation yes)" >&2
  exit 2
fi
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

timeout_seconds="$(duration_to_seconds "${timeout}")"
run_id="$(date -u +%Y%m%d%H%M%S)"

IFS=',' read -r -a requested_modes <<<"${modes_csv}"
modes=()
for m in "${requested_modes[@]}"; do
  trimmed="$(echo "${m}" | xargs)"
  [ -n "${trimmed}" ] || continue
  modes+=("$(normalize_mode "${trimmed}")")
done
if [ "${#modes[@]}" -eq 0 ]; then
  echo "error: no modes selected" >&2
  exit 2
fi

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
require_nonempty "${deploymentconfig_name}" "deploymentconfig name"

original_certificates_json="$(jq -c '.items[0].spec.certificates // {}' <<<"${dep_cfg_json}")"
if [ -z "${original_certificates_json}" ] || [ "${original_certificates_json}" = "null" ]; then
  original_certificates_json="{}"
fi

mutated=0
restore_original_certificates() {
  if [ "${mutated}" -eq 0 ]; then
    return 0
  fi
  echo ""
  echo "==> Restoring original spec.certificates on DeploymentConfig/${deploymentconfig_name}"
  patch_payload="$(jq -cn --argjson cert "${original_certificates_json}" '[{"op":"replace","path":"/spec/certificates","value":$cert}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    sleep "${settle_seconds}"
    echo "   restore complete"
    return 0
  fi

  patch_payload="$(jq -cn --argjson cert "${original_certificates_json}" '[{"op":"add","path":"/spec/certificates","value":$cert}]')"
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
  restore_original_certificates
  restore_deployment_config_controller_after_test
  restore_gitops_sync_after_test
}
trap cleanup EXIT

patch_certificates_replace() {
  local cert_json="$1"
  local patch_payload
  patch_payload="$(jq -cn --argjson cert "${cert_json}" '[{"op":"replace","path":"/spec/certificates","value":$cert}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    mutated=1
    return 0
  fi

  patch_payload="$(jq -cn --argjson cert "${cert_json}" '[{"op":"add","path":"/spec/certificates","value":$cert}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  mutated=1
}

assert_log_contains() {
  local logs="$1"
  local pattern="$2"
  local context="$3"
  if ! grep -Fq -- "${pattern}" <<<"${logs}"; then
    echo "FAIL: expected log pattern not found (${context}): ${pattern}" >&2
    return 1
  fi
}

is_transient_smoke_failure() {
  local logs="$1"
  grep -Eiq \
    'The connection to the server .* was refused|i/o timeout|context deadline exceeded|TLS handshake timeout|timed out waiting|connect: connection refused|ServiceUnavailable|unexpected EOF' \
    <<<"${logs}"
}

run_smoke_cronjob() {
  local mode="$1"
  local cronjob="$2"
  local expectation="$3" # passed|stepca-skip|stepca-skip-or-pass
  local max_attempts="${4:-3}"

  local attempt
  for attempt in $(seq 1 "${max_attempts}"); do
    local mode_slug
    mode_slug="$(echo "${mode}" | tr '[:upper:]' '[:lower:]')"
    local job_name
    job_name="$(trunc_name "${cronjob}-${mode_slug}" "manual-${run_id}-a${attempt}")"

    echo "   - ${smoke_namespace}/CronJob/${cronjob} -> Job/${job_name} (attempt ${attempt}/${max_attempts})"
    kubectl -n "${smoke_namespace}" create job --from=cronjob/"${cronjob}" "${job_name}" >/dev/null

    local logs
    if ! wait_for_job_completion_or_failure "${smoke_namespace}" "${job_name}" "${timeout_seconds}"; then
      logs="$(kubectl -n "${smoke_namespace}" logs "job/${job_name}" --tail=2000 2>/dev/null || true)"
      if [ "${attempt}" -lt "${max_attempts}" ] && is_transient_smoke_failure "${logs}"; then
        sleep "$((attempt * 5))"
        continue
      fi
      echo "FAIL: smoke job did not complete successfully: ${smoke_namespace}/Job/${job_name}" >&2
      kubectl -n "${smoke_namespace}" describe job "${job_name}" >&2 || true
      printf '%s\n' "${logs}" >&2
      return 1
    fi

    logs="$(kubectl -n "${smoke_namespace}" logs "job/${job_name}" --tail=2000 2>/dev/null || true)"
    case "${expectation}" in
      passed)
        assert_log_contains "${logs}" "PASSED" "${cronjob}/${mode}" || return 1
        ;;
      stepca-skip)
        assert_log_contains "${logs}" "SKIP: Step CA issuance smoke is not required" "${cronjob}/${mode}" || return 1
        ;;
      stepca-skip-or-pass)
        if grep -Fq -- "SKIP: Step CA issuance smoke is not required" <<<"${logs}"; then
          :
        elif grep -Fq -- "PASSED" <<<"${logs}"; then
          echo "WARN: ${cronjob}/${mode} did not emit mode-aware SKIP, but completed successfully" >&2
        else
          echo "FAIL: expected skip-or-pass result for ${cronjob}/${mode}" >&2
          return 1
        fi
        ;;
      *)
        echo "error: unknown expectation '${expectation}'" >&2
        return 1
        ;;
    esac
    return 0
  done

  return 1
}

wait_for_clusterissuer_ready() {
  local name="$1"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi

  for _ in $(seq 1 "${loops}"); do
    ready="$(kubectl get clusterissuer "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "${ready}" = "True" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_effective_certificate_modes() {
  local expected_platform="$1"
  local expected_tenants="$2"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi

  for _ in $(seq 1 "${loops}"); do
    local platform_mode tenant_mode
    platform_mode="$(
      kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o json \
        | jq -r '.spec.certificates.platformIngress.mode // ""' 2>/dev/null || true
    )"
    tenant_mode="$(
      kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o json \
        | jq -r '.spec.certificates.tenants.mode // ""' 2>/dev/null || true
    )"
    if [[ "${platform_mode}" == "${expected_platform}" && "${tenant_mode}" == "${expected_tenants}" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "FAIL: DeploymentConfig/${deploymentconfig_name} certificates mode did not converge (platform='${expected_platform}', tenants='${expected_tenants}')" >&2
  kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o yaml >&2 || true
  return 1
}

build_subca_certificates_json() {
  jq -cn '
    {
      platformIngress: { mode: "subCa" },
      tenants: { mode: "subCa" }
    }
  '
}

build_vault_certificates_json() {
  jq -cn '
    {
      platformIngress: { mode: "vault" },
      tenants: { mode: "subCa" }
    }
  '
}

build_acme_certificates_json() {
  local acme_server="${DK_CERT_E2E_ACME_SERVER:-}"
  local acme_email="${DK_CERT_E2E_ACME_EMAIL:-}"
  local acme_ca_bundle="${DK_CERT_E2E_ACME_CA_BUNDLE:-}"
  local acme_provider="${DK_CERT_E2E_ACME_PROVIDER:-rfc2136}"
  local acme_cluster_issuer_name="${DK_CERT_E2E_ACME_CLUSTER_ISSUER_NAME:-}"
  local acme_private_key_secret_name="${DK_CERT_E2E_ACME_PRIVATE_KEY_SECRET_NAME:-}"
  local acme_credentials_secret_name="${DK_CERT_E2E_ACME_CREDENTIALS_SECRET_NAME:-}"
  local acme_credentials_external_secret_name="${DK_CERT_E2E_ACME_CREDENTIALS_EXTERNAL_SECRET_NAME:-}"
  local acme_credentials_vault_path="${DK_CERT_E2E_ACME_CREDENTIALS_VAULT_PATH:-}"
  local acme_tsig_secret_property="${DK_CERT_E2E_ACME_TSIG_SECRET_PROPERTY:-}"

  require_nonempty "${acme_server}" "DK_CERT_E2E_ACME_SERVER"
  require_nonempty "${acme_email}" "DK_CERT_E2E_ACME_EMAIL"

  case "${acme_provider}" in
    rfc2136|cloudflare|route53) ;;
    *)
      echo "error: DK_CERT_E2E_ACME_PROVIDER must be rfc2136|cloudflare|route53 (got '${acme_provider}')" >&2
      exit 2
      ;;
  esac

  local json
  case "${acme_provider}" in
    rfc2136)
      local ns="${DK_CERT_E2E_ACME_RFC2136_NAMESERVER:-}"
      local key_name="${DK_CERT_E2E_ACME_RFC2136_TSIG_KEY_NAME:-}"
      local algo="${DK_CERT_E2E_ACME_RFC2136_TSIG_ALGORITHM:-}"
      require_nonempty "${ns}" "DK_CERT_E2E_ACME_RFC2136_NAMESERVER"
      require_nonempty "${key_name}" "DK_CERT_E2E_ACME_RFC2136_TSIG_KEY_NAME"
      require_nonempty "${acme_credentials_vault_path}" "DK_CERT_E2E_ACME_CREDENTIALS_VAULT_PATH"
      json="$(
        jq -cn \
          --arg server "${acme_server}" \
          --arg email "${acme_email}" \
          --arg ca_bundle "${acme_ca_bundle}" \
          --arg ns "${ns}" \
          --arg key_name "${key_name}" \
          --arg algo "${algo}" \
          --arg cluster_issuer "${acme_cluster_issuer_name}" \
          --arg pk_secret "${acme_private_key_secret_name}" \
          --arg creds_secret "${acme_credentials_secret_name}" \
          --arg creds_external_secret "${acme_credentials_external_secret_name}" \
          --arg creds_vault "${acme_credentials_vault_path}" \
          --arg tsig_prop "${acme_tsig_secret_property}" \
          '
          {
            platformIngress: { mode: "acme" },
            tenants: { mode: "acme" },
            acme: {
              server: $server,
              email: $email,
              solver: {
                type: "dns01",
                provider: "rfc2136",
                rfc2136: {
                  nameServer: $ns,
                  tsigKeyName: $key_name
                }
              },
              credentials: {
                vaultPath: $creds_vault
              }
            }
          }
          | if $ca_bundle != "" then .acme.caBundle = $ca_bundle else . end
          | if $algo != "" then .acme.solver.rfc2136.tsigAlgorithm = $algo else . end
          | if $cluster_issuer != "" then .acme.clusterIssuerName = $cluster_issuer else . end
          | if $pk_secret != "" then .acme.privateKeySecretName = $pk_secret else . end
          | if $creds_secret != "" then .acme.credentials.secretName = $creds_secret else . end
          | if $creds_external_secret != "" then .acme.credentials.externalSecretName = $creds_external_secret else . end
          | if $tsig_prop != "" then .acme.credentials.tsigSecretProperty = $tsig_prop else . end
          '
      )"
      ;;
    cloudflare)
      local cf_email="${DK_CERT_E2E_ACME_CLOUDFLARE_EMAIL:-}"
      local cf_token_prop="${DK_CERT_E2E_ACME_CLOUDFLARE_API_TOKEN_PROPERTY:-}"
      require_nonempty "${acme_credentials_vault_path}" "DK_CERT_E2E_ACME_CREDENTIALS_VAULT_PATH"
      json="$(
        jq -cn \
          --arg server "${acme_server}" \
          --arg email "${acme_email}" \
          --arg ca_bundle "${acme_ca_bundle}" \
          --arg cf_email "${cf_email}" \
          --arg cluster_issuer "${acme_cluster_issuer_name}" \
          --arg pk_secret "${acme_private_key_secret_name}" \
          --arg creds_secret "${acme_credentials_secret_name}" \
          --arg creds_external_secret "${acme_credentials_external_secret_name}" \
          --arg creds_vault "${acme_credentials_vault_path}" \
          --arg cf_token_prop "${cf_token_prop}" \
          '
          {
            platformIngress: { mode: "acme" },
            tenants: { mode: "acme" },
            acme: {
              server: $server,
              email: $email,
              solver: {
                type: "dns01",
                provider: "cloudflare",
                cloudflare: {}
              },
              credentials: {
                vaultPath: $creds_vault
              }
            }
          }
          | if $ca_bundle != "" then .acme.caBundle = $ca_bundle else . end
          | if $cf_email != "" then .acme.solver.cloudflare.email = $cf_email else . end
          | if $cluster_issuer != "" then .acme.clusterIssuerName = $cluster_issuer else . end
          | if $pk_secret != "" then .acme.privateKeySecretName = $pk_secret else . end
          | if $creds_secret != "" then .acme.credentials.secretName = $creds_secret else . end
          | if $creds_external_secret != "" then .acme.credentials.externalSecretName = $creds_external_secret else . end
          | if $cf_token_prop != "" then .acme.credentials.cloudflareApiTokenProperty = $cf_token_prop else . end
          '
      )"
      ;;
    route53)
      local r53_region="${DK_CERT_E2E_ACME_ROUTE53_REGION:-}"
      local r53_hosted_zone_id="${DK_CERT_E2E_ACME_ROUTE53_HOSTED_ZONE_ID:-}"
      local r53_role="${DK_CERT_E2E_ACME_ROUTE53_ROLE:-}"
      local r53_access_key_prop="${DK_CERT_E2E_ACME_ROUTE53_ACCESS_KEY_ID_PROPERTY:-}"
      local r53_secret_key_prop="${DK_CERT_E2E_ACME_ROUTE53_SECRET_ACCESS_KEY_PROPERTY:-}"
      require_nonempty "${r53_region}" "DK_CERT_E2E_ACME_ROUTE53_REGION"
      json="$(
        jq -cn \
          --arg server "${acme_server}" \
          --arg email "${acme_email}" \
          --arg ca_bundle "${acme_ca_bundle}" \
          --arg region "${r53_region}" \
          --arg hosted_zone "${r53_hosted_zone_id}" \
          --arg role "${r53_role}" \
          --arg cluster_issuer "${acme_cluster_issuer_name}" \
          --arg pk_secret "${acme_private_key_secret_name}" \
          --arg creds_secret "${acme_credentials_secret_name}" \
          --arg creds_external_secret "${acme_credentials_external_secret_name}" \
          --arg creds_vault "${acme_credentials_vault_path}" \
          --arg access_key_prop "${r53_access_key_prop}" \
          --arg secret_key_prop "${r53_secret_key_prop}" \
          '
          {
            platformIngress: { mode: "acme" },
            tenants: { mode: "acme" },
            acme: {
              server: $server,
              email: $email,
              solver: {
                type: "dns01",
                provider: "route53",
                route53: {
                  region: $region
                }
              },
              credentials: {}
            }
          }
          | if $ca_bundle != "" then .acme.caBundle = $ca_bundle else . end
          | if $hosted_zone != "" then .acme.solver.route53.hostedZoneID = $hosted_zone else . end
          | if $role != "" then .acme.solver.route53.role = $role else . end
          | if $cluster_issuer != "" then .acme.clusterIssuerName = $cluster_issuer else . end
          | if $pk_secret != "" then .acme.privateKeySecretName = $pk_secret else . end
          | if $creds_secret != "" then .acme.credentials.secretName = $creds_secret else . end
          | if $creds_external_secret != "" then .acme.credentials.externalSecretName = $creds_external_secret else . end
          | if $creds_vault != "" then .acme.credentials.vaultPath = $creds_vault else . end
          | if $access_key_prop != "" then .acme.credentials.route53AccessKeyIdProperty = $access_key_prop else . end
          | if $secret_key_prop != "" then .acme.credentials.route53SecretAccessKeyProperty = $secret_key_prop else . end
          | if (.acme.credentials | keys | length) == 0 then del(.acme.credentials) else . end
          '
      )"
      ;;
  esac

  echo "${json}"
}

build_wildcard_certificates_json() {
  local wildcard_vault_path="${DK_CERT_E2E_WILDCARD_VAULT_PATH:-}"
  local wildcard_secret_name="${DK_CERT_E2E_WILDCARD_SECRET_NAME:-}"
  local wildcard_external_secret_name="${DK_CERT_E2E_WILDCARD_EXTERNAL_SECRET_NAME:-}"
  local wildcard_tls_cert_property="${DK_CERT_E2E_WILDCARD_TLS_CERT_PROPERTY:-}"
  local wildcard_tls_key_property="${DK_CERT_E2E_WILDCARD_TLS_KEY_PROPERTY:-}"
  local wildcard_ca_bundle_secret_name="${DK_CERT_E2E_WILDCARD_CA_BUNDLE_SECRET_NAME:-}"
  local wildcard_ca_bundle_external_secret_name="${DK_CERT_E2E_WILDCARD_CA_BUNDLE_EXTERNAL_SECRET_NAME:-}"
  local wildcard_ca_bundle_vault_path="${DK_CERT_E2E_WILDCARD_CA_BUNDLE_VAULT_PATH:-}"
  local wildcard_ca_bundle_property="${DK_CERT_E2E_WILDCARD_CA_BUNDLE_PROPERTY:-}"

  require_nonempty "${wildcard_vault_path}" "DK_CERT_E2E_WILDCARD_VAULT_PATH"

  jq -cn \
    --arg vault_path "${wildcard_vault_path}" \
    --arg secret_name "${wildcard_secret_name}" \
    --arg external_secret_name "${wildcard_external_secret_name}" \
    --arg tls_cert_property "${wildcard_tls_cert_property}" \
    --arg tls_key_property "${wildcard_tls_key_property}" \
    --arg ca_secret_name "${wildcard_ca_bundle_secret_name}" \
    --arg ca_external_secret_name "${wildcard_ca_bundle_external_secret_name}" \
    --arg ca_vault_path "${wildcard_ca_bundle_vault_path}" \
    --arg ca_property "${wildcard_ca_bundle_property}" \
    '
    {
      platformIngress: {
        mode: "wildcard",
        wildcard: {
          vaultPath: $vault_path
        }
      },
      tenants: {
        mode: "subCa"
      }
    }
    | if $secret_name != "" then .platformIngress.wildcard.secretName = $secret_name else . end
    | if $external_secret_name != "" then .platformIngress.wildcard.externalSecretName = $external_secret_name else . end
    | if $tls_cert_property != "" then .platformIngress.wildcard.tlsCertProperty = $tls_cert_property else . end
    | if $tls_key_property != "" then .platformIngress.wildcard.tlsKeyProperty = $tls_key_property else . end
    | if $ca_secret_name != "" then .platformIngress.wildcard.caBundleSecretName = $ca_secret_name else . end
    | if $ca_external_secret_name != "" then .platformIngress.wildcard.caBundleExternalSecretName = $ca_external_secret_name else . end
    | if $ca_vault_path != "" then .platformIngress.wildcard.caBundleVaultPath = $ca_vault_path else . end
    | if $ca_property != "" then .platformIngress.wildcard.caBundleProperty = $ca_property else . end
    '
}

run_mode_smokes() {
  local mode="$1"

  echo ""
  echo "==> Running certificate smokes for mode=${mode}"
  case "${mode}" in
    acme)
      run_smoke_cronjob "${mode}" "cert-smoke-step-ca-issuance" "stepca-skip-or-pass"
      ;;
    *)
      run_smoke_cronjob "${mode}" "cert-smoke-step-ca-issuance" "passed"
      ;;
  esac
  case "${mode}" in
    vault)
      run_smoke_cronjob "${mode}" "cert-smoke-vault-external-issuance" "passed"
      ;;
    *)
      run_smoke_cronjob "${mode}" "cert-smoke-vault-external-issuance" "stepca-skip-or-pass"
      ;;
  esac
  run_smoke_cronjob "${mode}" "cert-smoke-ingress-readiness" "passed"
  run_smoke_cronjob "${mode}" "cert-smoke-gateway-sni" "passed"
}

echo "==> Certificate mode E2E matrix"
echo "DeploymentConfig: ${deploymentconfig_name}"
echo "Modes: ${modes[*]}"
echo "Smoke namespace: ${smoke_namespace}"
echo "Freeze deployment-config-controller: ${freeze_deployment_config_controller}"
echo "Freeze GitOps sync: ${freeze_gitops_sync}"
echo "Timeout/job: ${timeout}"

pause_gitops_sync_for_test
freeze_deployment_config_controller_for_test

for mode in "${modes[@]}"; do
  echo ""
  echo "==> Patching DeploymentConfig/${deploymentconfig_name} certificates for mode=${mode}"

  case "${mode}" in
    subCa)
      cert_json="$(build_subca_certificates_json)"
      ;;
    vault)
      cert_json="$(build_vault_certificates_json)"
      ;;
    acme)
      cert_json="$(build_acme_certificates_json)"
      ;;
    wildcard)
      cert_json="$(build_wildcard_certificates_json)"
      ;;
    *)
      echo "error: internal unsupported mode '${mode}'" >&2
      exit 2
      ;;
  esac

  patch_certificates_replace "${cert_json}"
  sleep "${settle_seconds}"

  expected_platform_mode="${mode}"
  expected_tenants_mode="${mode}"
  if [ "${mode}" = "wildcard" ]; then
    expected_tenants_mode="subCa"
  fi
  if [ "${mode}" = "vault" ]; then
    expected_tenants_mode="subCa"
  fi

  wait_for_effective_certificate_modes "${expected_platform_mode}" "${expected_tenants_mode}"

  if [ "${mode}" = "acme" ]; then
    acme_issuer_name="${DK_CERT_E2E_ACME_CLUSTER_ISSUER_NAME:-acme}"
    echo "   waiting for ClusterIssuer/${acme_issuer_name} Ready=True..."
    if ! wait_for_clusterissuer_ready "${acme_issuer_name}"; then
      echo "FAIL: ClusterIssuer/${acme_issuer_name} did not become Ready=True" >&2
      kubectl get clusterissuer "${acme_issuer_name}" -o yaml >&2 || true
      exit 1
    fi
  fi

  run_mode_smokes "${mode}"
done

echo ""
echo "Certificate mode E2E matrix PASSED"
