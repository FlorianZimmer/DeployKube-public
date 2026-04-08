#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE0_SCRIPT="${REPO_ROOT}/shared/scripts/bootstrap-mac-orbstack-stage0.sh"
STAGE1_SCRIPT="${REPO_ROOT}/shared/scripts/bootstrap-mac-orbstack-stage1.sh"
INIT_SCRIPT="${REPO_ROOT}/shared/scripts/init-vault-secrets.sh"
FORGEJO_REMOTE_SWITCH_SCRIPT="${REPO_ROOT}/shared/scripts/forgejo-switch-gitops-remote.sh"
KIND_REFRESH_KUBECONFIG_SCRIPT="${KIND_REFRESH_KUBECONFIG_SCRIPT:-${REPO_ROOT}/shared/scripts/kind-refresh-kubeconfig.sh}"
ROOT_APPLICATION="${ROOT_APPLICATION:-platform-apps}"
REQUIRED_VAULT_APPS="${REQUIRED_VAULT_APPS:-secrets-kms-shim secrets-vault}"
STAGE0_SENTINEL="${STAGE0_SENTINEL:-${REPO_ROOT}/tmp/stage0-complete}"
BOOTSTRAP_STATUS_CONFIGMAP="${BOOTSTRAP_STATUS_CONFIGMAP:-vault-bootstrap-status}"

BOOTSTRAP_SKIP_VAULT_INIT="${BOOTSTRAP_SKIP_VAULT_INIT:-false}"
BOOTSTRAP_WIPE_VAULT_DATA="${BOOTSTRAP_WIPE_VAULT_DATA:-false}"
BOOTSTRAP_REINIT_VAULT="${BOOTSTRAP_REINIT_VAULT:-false}"
BOOTSTRAP_FORCE_VAULT="${BOOTSTRAP_FORCE_VAULT:-false}"
BOOTSTRAP_WAIT_ROOT_APP="${BOOTSTRAP_WAIT_ROOT_APP:-true}"
BOOTSTRAP_WAIT_PLATFORM_CONVERGENCE="${BOOTSTRAP_WAIT_PLATFORM_CONVERGENCE:-true}"
BOOTSTRAP_PLATFORM_CONVERGENCE_TIMEOUT_SECONDS="${BOOTSTRAP_PLATFORM_CONVERGENCE_TIMEOUT_SECONDS:-1800}"
BOOTSTRAP_PLATFORM_CONVERGENCE_POLL_SECONDS="${BOOTSTRAP_PLATFORM_CONVERGENCE_POLL_SECONDS:-10}"
BOOTSTRAP_STABILIZE_EXTERNAL_SECRETS="${BOOTSTRAP_STABILIZE_EXTERNAL_SECRETS:-true}"
BOOTSTRAP_EXTERNAL_SECRET_WAIT_SECONDS="${BOOTSTRAP_EXTERNAL_SECRET_WAIT_SECONDS:-900}"
BOOTSTRAP_EXTERNAL_SECRET_STORE_WAIT_SECONDS="${BOOTSTRAP_EXTERNAL_SECRET_STORE_WAIT_SECONDS:-900}"
BOOTSTRAP_DEPENDENCY_WAIT_SECONDS="${BOOTSTRAP_DEPENDENCY_WAIT_SECONDS:-1800}"
BOOTSTRAP_EXTERNAL_SECRET_TARGETS="${BOOTSTRAP_EXTERNAL_SECRET_TARGETS:-external-secrets/eso-tenant-smoke access-guardrails-system/k8s-oidc-runtime-smoke-client}"
CLUSTER_NAME="${CLUSTER_NAME:-deploykube-dev}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-kind-${CLUSTER_NAME}}"
GITOPS_LOCAL_REPO="${REPO_ROOT}/platform/gitops"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
FORGEJO_ORG="${FORGEJO_ORG:-platform}"
FORGEJO_REPO="${FORGEJO_REPO:-cluster-config}"
FORGEJO_HTTPS_SENTINEL="${FORGEJO_HTTPS_SENTINEL:-forgejo-https-switch-complete}"
FORGEJO_REMOTE_SWITCH_TIMEOUT="${FORGEJO_REMOTE_SWITCH_TIMEOUT:-900}"
FORGEJO_REMOTE_SWITCH_POLL="${FORGEJO_REMOTE_SWITCH_POLL:-5}"
FORGEJO_SKIP_REMOTE_SWITCH="${FORGEJO_SKIP_REMOTE_SWITCH:-false}"
FORGEJO_REMOTE_SWITCH_REQUIRED="${FORGEJO_REMOTE_SWITCH_REQUIRED:-false}"
FORGEJO_CA_CERT="${FORGEJO_CA_CERT:-${REPO_ROOT}/shared/certs/deploykube-root-ca.crt}"
BOOTSTRAP_RECOVERY_RETRY_SECONDS="${BOOTSTRAP_RECOVERY_RETRY_SECONDS:-30}"
BOOTSTRAP_HARD_REFRESH_AFTER_FORGEJO_READY="${BOOTSTRAP_HARD_REFRESH_AFTER_FORGEJO_READY:-true}"
BOOTSTRAP_RECOVERY_STATE_DIR="${BOOTSTRAP_RECOVERY_STATE_DIR:-${REPO_ROOT}/tmp/bootstrap-recovery}"

log() {
  printf '[bootstrap] %s\n' "$1"
}

validate_yaml_files() {
  if [[ "${BOOTSTRAP_SKIP_YAML_VALIDATE:-false}" == "true" ]]; then
    log "skipping YAML validation (BOOTSTRAP_SKIP_YAML_VALIDATE=true)"
    return
  fi

  if ! command -v ruby >/dev/null 2>&1; then
    log "ruby is required for YAML validation; install ruby or set BOOTSTRAP_SKIP_YAML_VALIDATE=true"
    exit 1
  fi

  local patch_file="${REPO_ROOT}/platform/gitops/components/secrets/vault/helm/patch-statefulset.yaml"
  if [[ ! -f "${patch_file}" ]]; then
    log "YAML validation failed: missing ${patch_file}"
    exit 1
  fi

  ruby -ryaml -e '
    f = ARGV.fetch(0)
    begin
      doc = YAML.safe_load(File.read(f), permitted_classes: [], permitted_symbols: [], aliases: true)
    rescue Exception => e
      warn("[bootstrap] YAML parse failed: #{f}: #{e.message}")
      exit 1
    end
    unless doc.is_a?(Hash) && doc.dig("spec", "template")
      warn("[bootstrap] YAML validation failed: #{f} must include spec.template (Kustomize patch)")
      exit 1
    end
  ' "${patch_file}"

  log "YAML validation OK (vault patch file)"
}

print_application_debug() {
  local app="$1"

  log "Argo application debug for ${app}:"

  local summary
  summary=$(
    kubectl -n argocd get applications.argoproj.io "${app}" \
      -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}' 2>/dev/null || true
  )
  if [[ -n "${summary}" ]]; then
    printf '%s\n' "${summary}" | sed 's/^/[bootstrap]   status: /'
  fi

  local source
  source=$(
    kubectl -n argocd get applications.argoproj.io "${app}" \
      -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision} {.spec.source.path}{"\n"}' 2>/dev/null || true
  )
  if [[ -n "${source}" ]]; then
    printf '%s\n' "${source}" | sed 's/^/[bootstrap]   source: /'
  fi

  local conditions
  conditions=$(
    kubectl -n argocd get applications.argoproj.io "${app}" \
      -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null || true
  )
  if [[ -n "${conditions}" ]]; then
    printf '%s\n' "${conditions}" | sed 's/^/[bootstrap]   condition: /'
  fi

  local op_message
  op_message=$(
    kubectl -n argocd get applications.argoproj.io "${app}" \
      -o jsonpath='{.status.operationState.message}{"\n"}' 2>/dev/null || true
  )
  if [[ -n "${op_message}" ]]; then
    printf '%s\n' "${op_message}" | sed 's/^/[bootstrap]   operation: /'
  fi
}

require_executable() {
  local path="$1"
  if [[ ! -x "${path}" ]]; then
    log "required script missing or not executable: ${path}"
    exit 1
  fi
}

ensure_scripts() {
  require_executable "${STAGE0_SCRIPT}"
  require_executable "${STAGE1_SCRIPT}"
  if [[ "${BOOTSTRAP_SKIP_VAULT_INIT}" != "true" ]]; then
    require_executable "${INIT_SCRIPT}"
  fi
}

run_stage0() {
  log "running Stage 0 bootstrap"
  STAGE0_SENTINEL="${STAGE0_SENTINEL}" "${STAGE0_SCRIPT}"
}

require_stage0_sentinel() {
  if [[ ! -f "${STAGE0_SENTINEL}" ]]; then
    log "Stage 0 sentinel ${STAGE0_SENTINEL} missing – rerun Stage 0"
    exit 1
  fi
  log "Stage 0 sentinel present ($(cat "${STAGE0_SENTINEL}" 2>/dev/null || echo 'unknown timestamp'))"
}

run_stage1() {
  log "running Stage 1 bootstrap"
  STAGE0_SENTINEL="${STAGE0_SENTINEL}" \
  WAIT_FOR_PLATFORM_APPS=false \
    "${STAGE1_SCRIPT}"
}

wait_for_root_application() {
  if [[ "${BOOTSTRAP_WAIT_ROOT_APP}" != "true" ]]; then
    log "skipping root Application wait (BOOTSTRAP_WAIT_ROOT_APP=false)"
    return
  fi
  log "waiting for Argo CD Application ${ROOT_APPLICATION} to be created"
  local attempts=0
  local max_attempts=120
  while (( attempts < max_attempts )); do
    if kubectl -n argocd get applications.argoproj.io "${ROOT_APPLICATION}" >/dev/null 2>&1; then
      log "root Application ${ROOT_APPLICATION} detected"
      return
    fi
    sleep 5
    attempts=$((attempts + 1))
  done
  log "timed out waiting for Argo Application ${ROOT_APPLICATION}; investigate Argo CD health"
  exit 1
}

wait_for_application() {
  local app="$1"
  for _ in {1..120}; do
    if kubectl -n argocd get applications.argoproj.io "${app}" >/dev/null 2>&1; then
      log "observed Argo CD Application ${app}"
      return
    fi
    sleep 5
  done
  log "timed out waiting for Argo Application ${app}; investigate Argo CD sync"
  exit 1
}

wait_for_application_synced() {
  local app="$1"
  for _ in {1..240}; do
    local sync_status
    sync_status=$(kubectl -n argocd get applications.argoproj.io "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    if [[ "${sync_status}" == "Synced" ]]; then
      local health_status
      health_status=$(kubectl -n argocd get applications.argoproj.io "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
      log "Argo CD Application ${app} is Synced (${health_status:-unknown})"
      return
    fi

    # Fail fast for app/manifest errors that won't self-heal.
    local fatal_types
    fatal_types=$(
      kubectl -n argocd get applications.argoproj.io "${app}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{"\n"}{end}' 2>/dev/null \
        | grep -E '^(InvalidSpecError)$' || true
    )
    if [[ -n "${fatal_types}" ]]; then
      log "Argo CD Application ${app} has fatal conditions (${fatal_types//$'\n'/, }); refusing to wait"
      print_application_debug "${app}"
      kubectl -n argocd describe application "${app}" || true
      exit 1
    fi
    sleep 5
  done
  log "timed out waiting for Argo Application ${app} to reach Synced status"
  print_application_debug "${app}"
  kubectl -n argocd describe application "${app}" || true
  exit 1
}

wait_for_application_healthy() {
  local app="$1"
  local timeout_seconds="${2:-900}"
  local end_ts=$(( $(date +%s) + timeout_seconds ))
  while true; do
    local sync_status health_status
    sync_status=$(kubectl -n argocd get applications.argoproj.io "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health_status=$(kubectl -n argocd get applications.argoproj.io "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
      log "Argo CD Application ${app} is Synced + Healthy"
      return 0
    fi
    if app_has_fatal_conditions "${app}"; then
      return 1
    fi
    if (( $(date +%s) >= end_ts )); then
      log "timed out waiting for Argo CD Application ${app} to become Synced + Healthy"
      print_application_debug "${app}"
      kubectl -n argocd describe application "${app}" || true
      return 1
    fi
    sleep 5
  done
}

wait_for_required_vault_apps() {
  if [[ -z "${REQUIRED_VAULT_APPS}" ]]; then
    return
  fi
  log "waiting for Argo CD vault Applications: ${REQUIRED_VAULT_APPS}"
  # shellcheck disable=SC2086 # intentional word splitting
  for app in ${REQUIRED_VAULT_APPS}; do
    wait_for_application "${app}"
    wait_for_application_synced "${app}"
  done
}

ensure_bootstrap_status_when_skipping() {
  if [[ "${BOOTSTRAP_SKIP_VAULT_INIT}" != "true" ]]; then
    return
  fi
  if kubectl -n argocd get configmap "${BOOTSTRAP_STATUS_CONFIGMAP}" >/dev/null 2>&1; then
    return
  fi
  log "vault bootstrap sentinel missing; run shared/scripts/init-vault-secrets.sh at least once before skipping init"
  exit 1
}

run_vault_init() {
  if [[ "${BOOTSTRAP_SKIP_VAULT_INIT}" == "true" ]]; then
    log "skipping vault init (BOOTSTRAP_SKIP_VAULT_INIT=true)"
    return
  fi
  log "running init-vault-secrets.sh"
  local args=()
  if [[ "${BOOTSTRAP_WIPE_VAULT_DATA}" == "true" ]]; then
    args+=("--wipe-core-data")
  fi
  if [[ "${BOOTSTRAP_REINIT_VAULT}" == "true" ]]; then
    args+=("--reinit-core")
  fi
  if [[ "${BOOTSTRAP_FORCE_VAULT}" == "true" ]]; then
    args+=("--force")
  fi
  "${INIT_SCRIPT}" "${args[@]}"
}

is_allowed_health_status() {
  local status="$1"
  case "${status}" in
    Healthy|Suspended|Unknown)
      return 0
      ;;
  esac
  return 1
}

app_has_fatal_conditions() {
  local app="$1"
  local fatal_types
  fatal_types=$(
    kubectl -n argocd get applications.argoproj.io "${app}" \
      -o jsonpath='{range .status.conditions[*]}{.type}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(InvalidSpecError)$' || true
  )
  if [[ -z "${fatal_types}" ]]; then
    return 1
  fi
  log "Argo CD Application ${app} has fatal conditions (${fatal_types//$'\n'/, })"
  print_application_debug "${app}"
  kubectl -n argocd describe application "${app}" || true
  return 0
}

force_sync_externalsecret() {
  local namespace="$1"
  local name="$2"
  kubectl -n "${namespace}" annotate externalsecret "${name}" force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
}

force_sync_externalsecrets_for_store() {
  local store_name="$1"
  local rows
  rows=$(
    kubectl get externalsecret -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.secretStoreRef.kind}{"|"}{.spec.secretStoreRef.name}{"\n"}{end}' 2>/dev/null || true
  )
  [[ -z "${rows}" ]] && return

  local row ns name kind ref
  while IFS='|' read -r ns name kind ref; do
    [[ -z "${ns}" || -z "${name}" ]] && continue
    if [[ "${kind}" == "ClusterSecretStore" && "${ref}" == "${store_name}" ]]; then
      force_sync_externalsecret "${ns}" "${name}"
    fi
  done <<<"${rows}"
}

wait_for_clustersecretstore_ready() {
  local name="$1"
  local timeout_seconds="$2"
  local end_ts=$(( $(date +%s) + timeout_seconds ))
  local last_message=""
  local last_forced_reconcile=0
  while true; do
    local status reason message
    status=$(kubectl get clustersecretstore "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    reason=$(kubectl get clustersecretstore "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    message=$(kubectl get clustersecretstore "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)

    if [[ "${status}" == "True" ]]; then
      return 0
    fi

    if [[ -n "${message}" && "${message}" != "${last_message}" ]]; then
      log "ClusterSecretStore ${name} not ready (${reason:-unknown}): ${message}"
      last_message="${message}"
    fi

    if [[ "${reason}" == "InvalidProviderConfig" ]]; then
      local now
      now=$(date +%s)
      if (( now - last_forced_reconcile >= 30 )); then
        kubectl annotate clustersecretstore "${name}" "deploykube.io/force-reconcile=${now}" --overwrite >/dev/null 2>&1 || true
        last_forced_reconcile=$now
      fi
    fi

    if (( $(date +%s) >= end_ts )); then
      log "timed out waiting for ClusterSecretStore ${name} to become Ready=True"
      kubectl get clustersecretstore "${name}" -o yaml || true
      return 1
    fi
    sleep 5
  done
}

rerun_tenant_eso_job_once() {
  local ns="vault-system"
  local cronjob="vault-tenant-eso-config"
  if ! kubectl -n "${ns}" get cronjob "${cronjob}" >/dev/null 2>&1; then
    log "tenant ESO cronjob ${ns}/${cronjob} not found; skipping explicit tenant role reconcile"
    return 0
  fi

  local job_name="vault-tenant-eso-config-bootstrap-$(date +%s)"
  log "triggering tenant ESO reconcile job ${ns}/${job_name}"
  kubectl -n "${ns}" create job --from="cronjob/${cronjob}" "${job_name}" >/dev/null
  if ! kubectl -n "${ns}" wait --for=condition=complete "job/${job_name}" --timeout=600s >/dev/null 2>&1; then
    log "tenant ESO reconcile job ${job_name} failed"
    kubectl -n "${ns}" logs "job/${job_name}" || true
    return 1
  fi
  kubectl -n "${ns}" delete job "${job_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  return 0
}

wait_for_externalsecret_ready() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${3}"
  local end_ts=$(( $(date +%s) + timeout_seconds ))
  local last_conditions=""
  local last_forced_sync=0

  local store_kind store_name
  store_kind=$(kubectl -n "${namespace}" get externalsecret "${name}" -o jsonpath='{.spec.secretStoreRef.kind}' 2>/dev/null || true)
  store_name=$(kubectl -n "${namespace}" get externalsecret "${name}" -o jsonpath='{.spec.secretStoreRef.name}' 2>/dev/null || true)
  if [[ "${store_kind}" == "ClusterSecretStore" && -n "${store_name}" ]]; then
    wait_for_clustersecretstore_ready "${store_name}" "${BOOTSTRAP_EXTERNAL_SECRET_STORE_WAIT_SECONDS}" || return 1
  fi

  while true; do
    local conditions
    conditions=$(
      kubectl -n "${namespace}" get externalsecret "${name}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={"="}{.status}:{.reason}:{.message}{"\n"}{end}' 2>/dev/null || true
    )
    if printf '%s\n' "${conditions}" | grep -q '^Ready==True:'; then
      log "ExternalSecret ${namespace}/${name} is Ready=True"
      return 0
    fi
    if [[ -n "${conditions}" ]] && [[ "${conditions}" != "${last_conditions}" ]]; then
      log "ExternalSecret ${namespace}/${name} not ready yet:"
      printf '%s\n' "${conditions}" | sed 's/^/[bootstrap]   /'
      last_conditions="${conditions}"
    fi
    if (( $(date +%s) >= end_ts )); then
      log "timed out waiting for ExternalSecret ${namespace}/${name} to become Ready=True"
      kubectl -n "${namespace}" get externalsecret "${name}" -o yaml || true
      return 1
    fi
    local now
    now=$(date +%s)
    if (( now - last_forced_sync >= 30 )); then
      force_sync_externalsecret "${namespace}" "${name}"
      last_forced_sync=$now
    fi
    sleep 5
  done
}

trigger_argocd_app_sync() {
  local app="$1"
  if ! kubectl -n argocd get applications.argoproj.io "${app}" >/dev/null 2>&1; then
    return
  fi
  kubectl -n argocd annotate applications.argoproj.io "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  kubectl -n argocd patch applications.argoproj.io "${app}" --type merge -p '{"operation":{"sync":{"revision":"main","prune":true}}}' >/dev/null 2>&1 || true
}

refresh_all_argocd_apps_hard() {
  local apps
  apps=$(kubectl -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  [[ -z "${apps}" ]] && return
  local app
  while IFS= read -r app; do
    [[ -z "${app}" ]] && continue
    kubectl -n argocd annotate applications.argoproj.io "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done <<<"${apps}"
}

app_recovery_stamp_file() {
  local app="$1"
  mkdir -p "${BOOTSTRAP_RECOVERY_STATE_DIR}" >/dev/null 2>&1 || true
  printf '%s/%s.recovery' "${BOOTSTRAP_RECOVERY_STATE_DIR}" "${app//[^a-zA-Z0-9_.-]/_}"
}

should_attempt_app_recovery() {
  local app="$1"
  local stamp now last
  stamp="$(app_recovery_stamp_file "${app}")"
  now="$(date +%s)"
  if [[ -f "${stamp}" ]]; then
    last="$(cat "${stamp}" 2>/dev/null || echo 0)"
    if [[ "${last}" =~ ^[0-9]+$ ]] && (( now - last < BOOTSTRAP_RECOVERY_RETRY_SECONDS )); then
      return 1
    fi
  fi
  printf '%s' "${now}" >"${stamp}" 2>/dev/null || true
  return 0
}

app_has_transient_forgejo_repo_503() {
  local app_json="$1"
  local condition_messages
  condition_messages="$(jq -r '.status.conditions[]? | select(.type=="ComparisonError") | .message // ""' <<<"${app_json}" 2>/dev/null || true)"
  [[ -z "${condition_messages}" ]] && return 1
  if printf '%s\n' "${condition_messages}" | grep -Eq '(forgejo-http|cluster-config\.git).*status code: 503|no healthy upstream|Failed to fetch default'; then
    return 0
  fi
  return 1
}

extract_waiting_hook_job_name() {
  local message="$1"
  if [[ "${message}" =~ hook\ batch/Job/([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

resolve_waiting_hook_job_namespace() {
  local app_json="$1"
  local job_name="$2"
  local namespace
  namespace="$(
    jq -r --arg job "${job_name}" '
      first([
        (.status.operationState.syncResult.resources[]?
         | select(.kind=="Job" and .name==$job and (.namespace // "") != "")
         | .namespace),
        .spec.destination.namespace
      ] | map(select(. != null and . != "")) | .[])
    ' <<<"${app_json}" 2>/dev/null || true
  )"
  [[ -n "${namespace}" && "${namespace}" != "null" ]] && printf '%s' "${namespace}"
}

hook_job_has_only_sidecar_running() {
  local ns="$1"
  local job="$2"
  local pod_json
  pod_json="$(
    kubectl -n "${ns}" get pods -l "job-name=${job}" -o json 2>/dev/null || true
  )"
  [[ -n "${pod_json}" ]] || return 1

  local pod_count
  pod_count="$(jq -r '.items | length' <<<"${pod_json}" 2>/dev/null || echo 0)"
  (( pod_count > 0 )) || return 1

  local non_proxy_running non_proxy_terminated proxy_running
  non_proxy_running="$(jq -r '[.items[]?.status.containerStatuses[]? | select(.name!="istio-proxy") | select(.state.running!=null or .state.waiting!=null)] | length' <<<"${pod_json}" 2>/dev/null || echo 0)"
  non_proxy_terminated="$(jq -r '[.items[]?.status.containerStatuses[]? | select(.name!="istio-proxy") | select(.state.terminated!=null)] | length' <<<"${pod_json}" 2>/dev/null || echo 0)"
  proxy_running="$(jq -r '[.items[]?.status.containerStatuses[]? | select(.name=="istio-proxy") | select(.state.running!=null)] | length' <<<"${pod_json}" 2>/dev/null || echo 0)"
  if (( non_proxy_running == 0 && non_proxy_terminated > 0 && proxy_running > 0 )); then
    return 0
  fi
  return 1
}

cleanup_hook_job() {
  local ns="$1"
  local job="$2"
  kubectl -n "${ns}" patch job "${job}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

clear_stale_waiting_hook_operation() {
  local app="$1"
  local app_json="$2"
  local op_phase op_message job_name job_namespace
  op_phase="$(jq -r '.status.operationState.phase // ""' <<<"${app_json}" 2>/dev/null || true)"
  op_message="$(jq -r '.status.operationState.message // ""' <<<"${app_json}" 2>/dev/null || true)"
  [[ "${op_phase}" == "Running" ]] || return 1
  extract_waiting_hook_job_name "${op_message}" >/dev/null 2>&1 || return 1
  job_name="$(extract_waiting_hook_job_name "${op_message}")"
  [[ -n "${job_name}" ]] || return 1

  job_namespace="$(resolve_waiting_hook_job_namespace "${app_json}" "${job_name}")"
  [[ -n "${job_namespace}" ]] || job_namespace="default"
  local should_resync="true"
  if kubectl -n "${job_namespace}" get job "${job_name}" >/dev/null 2>&1; then
    if hook_job_has_only_sidecar_running "${job_namespace}" "${job_name}"; then
      log "hook job ${job_namespace}/${job_name} has completed workload containers but running sidecar; deleting hook job to unblock ${app}"
      cleanup_hook_job "${job_namespace}" "${job_name}"
      should_resync="false"
    else
      return 1
    fi
  fi

  log "clearing stale hook wait for ${app}: ${job_namespace}/${job_name} missing"
  kubectl -n argocd patch applications.argoproj.io "${app}" --type merge -p '{"operation":null}' >/dev/null 2>&1 || true
  kubectl -n argocd annotate applications.argoproj.io "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  if [[ "${should_resync}" == "true" ]]; then
    trigger_argocd_app_sync "${app}"
  fi
  return 0
}

attempt_recover_pending_application() {
  local app="$1"
  local app_json
  app_json="$(kubectl -n argocd get applications.argoproj.io "${app}" -o json 2>/dev/null || true)"
  [[ -n "${app_json}" ]] || return 1

  should_attempt_app_recovery "${app}" || return 1

  if app_has_transient_forgejo_repo_503 "${app_json}"; then
    log "recovering ${app}: transient Forgejo repository 503 detected, forcing hard refresh/sync"
    trigger_argocd_app_sync "${app}"
    return 0
  fi

  if clear_stale_waiting_hook_operation "${app}" "${app_json}"; then
    return 0
  fi
  return 1
}

stabilize_dependencies_for_externalsecret() {
  local ref="$1"
  case "${ref}" in
    external-secrets/eso-tenant-smoke)
      log "triggering secrets-vault-config sync and tenant ESO role reconciliation"
      if kubectl -n argocd get applications.argoproj.io "secrets-vault-config" >/dev/null 2>&1; then
        trigger_argocd_app_sync "secrets-vault-config"
      else
        log "Argo CD Application secrets-vault-config not found; skipping explicit dependency sync"
      fi
      rerun_tenant_eso_job_once || return 1
      if kubectl -n argocd get applications.argoproj.io "secrets-vault-config" >/dev/null 2>&1; then
        wait_for_application_healthy "secrets-vault-config" "${BOOTSTRAP_DEPENDENCY_WAIT_SECONDS}" || return 1
      fi
      ;;
    access-guardrails-system/k8s-oidc-runtime-smoke-client)
      log "triggering certificates-step-ca + keycloak sync to ensure OIDC runtime smoke client is published in Vault"
      trigger_argocd_app_sync "certificates-step-ca"
      trigger_argocd_app_sync "platform-keycloak-base"
      trigger_argocd_app_sync "platform-keycloak-ingress"
      trigger_argocd_app_sync "platform-keycloak-bootstrap"
      wait_for_application_healthy "certificates-step-ca" "${BOOTSTRAP_DEPENDENCY_WAIT_SECONDS}" || return 1
      wait_for_application_healthy "platform-keycloak-ingress" "${BOOTSTRAP_DEPENDENCY_WAIT_SECONDS}" || return 1
      wait_for_application_healthy "platform-keycloak-base" "${BOOTSTRAP_DEPENDENCY_WAIT_SECONDS}" || return 1
      wait_for_application_healthy "platform-keycloak-bootstrap" "${BOOTSTRAP_DEPENDENCY_WAIT_SECONDS}" || return 1
      force_sync_externalsecrets_for_store "vault-core"
      ;;
  esac
}

stabilize_bootstrap_external_secrets() {
  if [[ "${BOOTSTRAP_STABILIZE_EXTERNAL_SECRETS}" != "true" ]]; then
    log "skipping ExternalSecret stabilization (BOOTSTRAP_STABILIZE_EXTERNAL_SECRETS=false)"
    return
  fi
  if [[ -z "${BOOTSTRAP_EXTERNAL_SECRET_TARGETS}" ]]; then
    return
  fi
  if ! kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    log "ExternalSecret CRD not present; skipping ExternalSecret stabilization"
    return
  fi
  log "stabilizing bootstrap ExternalSecrets: ${BOOTSTRAP_EXTERNAL_SECRET_TARGETS}"
  local ref
  # shellcheck disable=SC2086 # intentional word splitting
  for ref in ${BOOTSTRAP_EXTERNAL_SECRET_TARGETS}; do
    local namespace name
    namespace="${ref%%/*}"
    name="${ref#*/}"
    if [[ -z "${namespace}" || -z "${name}" || "${namespace}" == "${name}" ]]; then
      log "skipping invalid ExternalSecret target '${ref}' (expected namespace/name)"
      continue
    fi
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log "namespace ${namespace} not found; skipping ExternalSecret ${ref}"
      continue
    fi
    if ! kubectl -n "${namespace}" get externalsecret "${name}" >/dev/null 2>&1; then
      log "ExternalSecret ${ref} not found; skipping"
      continue
    fi
    stabilize_dependencies_for_externalsecret "${ref}" || exit 1
    force_sync_externalsecret "${namespace}" "${name}"
    wait_for_externalsecret_ready "${namespace}" "${name}" "${BOOTSTRAP_EXTERNAL_SECRET_WAIT_SECONDS}"
  done
}

wait_for_platform_convergence() {
  if [[ "${BOOTSTRAP_WAIT_PLATFORM_CONVERGENCE}" != "true" ]]; then
    log "skipping full Argo convergence wait (BOOTSTRAP_WAIT_PLATFORM_CONVERGENCE=false)"
    return
  fi
  local end_ts=$(( $(date +%s) + BOOTSTRAP_PLATFORM_CONVERGENCE_TIMEOUT_SECONDS ))
  while true; do
    local app_rows
    app_rows=$(
      kubectl -n argocd get applications.argoproj.io \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"\n"}{end}' 2>/dev/null || true
    )
    if [[ -z "${app_rows}" ]]; then
      if (( $(date +%s) >= end_ts )); then
        log "timed out waiting for Argo applications list to become available"
        exit 1
      fi
      sleep "${BOOTSTRAP_PLATFORM_CONVERGENCE_POLL_SECONDS}"
      continue
    fi

    local -a pending=()
    local row app sync health phase
    while IFS='|' read -r app sync health phase; do
      [[ -z "${app}" ]] && continue
      if [[ "${sync}" != "Synced" ]] || ! is_allowed_health_status "${health}"; then
        pending+=("${app}|${sync}|${health}|${phase}")
      fi
    done <<<"${app_rows}"

    if (( ${#pending[@]} == 0 )); then
      log "all Argo CD Applications converged (Synced + Healthy/Suspended/Unknown)"
      return
    fi

    local item pending_app pending_sync pending_health pending_phase
    for item in "${pending[@]}"; do
      IFS='|' read -r pending_app pending_sync pending_health pending_phase <<<"${item}"
      if app_has_fatal_conditions "${pending_app}"; then
        exit 1
      fi
      attempt_recover_pending_application "${pending_app}" || true
    done

    if (( $(date +%s) >= end_ts )); then
      log "timed out waiting for full Argo CD convergence; remaining Applications:"
      for item in "${pending[@]}"; do
        IFS='|' read -r pending_app pending_sync pending_health pending_phase <<<"${item}"
        log "  ${pending_app}: sync=${pending_sync:-unknown} health=${pending_health:-unknown} phase=${pending_phase:-unknown}"
      done
      kubectl -n argocd get applications.argoproj.io -o wide || true
      exit 1
    fi

    log "waiting for Argo convergence: ${#pending[@]} Applications still pending"
    sleep "${BOOTSTRAP_PLATFORM_CONVERGENCE_POLL_SECONDS}"
  done
}

refresh_kind_kubeconfig_final() {
  if [[ -x "${KIND_REFRESH_KUBECONFIG_SCRIPT}" ]]; then
    CLUSTER_NAME="${CLUSTER_NAME}" "${KIND_REFRESH_KUBECONFIG_SCRIPT}" || true
    return 0
  fi
  kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
}

switch_gitops_remote_to_https() {
  if [[ "${FORGEJO_SKIP_REMOTE_SWITCH}" == "true" ]]; then
    log "skipping Forgejo HTTPS readiness check (FORGEJO_SKIP_REMOTE_SWITCH=true)"
    return
  fi
  if [[ ! -x "${FORGEJO_REMOTE_SWITCH_SCRIPT}" ]]; then
    log "missing helper ${FORGEJO_REMOTE_SWITCH_SCRIPT}"
    exit 1
  fi
  log "waiting for Forgejo HTTPS sentinel (${FORGEJO_HTTPS_SENTINEL}) before running GitOps HTTPS readiness check"
  if "${FORGEJO_REMOTE_SWITCH_SCRIPT}" \
    --context "${KUBECTL_CONTEXT}" \
    --namespace "${FORGEJO_NAMESPACE}" \
    --sentinel "${FORGEJO_HTTPS_SENTINEL}" \
    --gitops-path "${GITOPS_LOCAL_REPO}" \
    --remote-name origin \
    --org "${FORGEJO_ORG}" \
    --repo "${FORGEJO_REPO}" \
    --ca-file "${FORGEJO_CA_CERT}" \
    --wait-timeout "${FORGEJO_REMOTE_SWITCH_TIMEOUT}" \
    --poll-interval "${FORGEJO_REMOTE_SWITCH_POLL}"; then
    if [[ "${BOOTSTRAP_HARD_REFRESH_AFTER_FORGEJO_READY}" == "true" ]]; then
      log "Forgejo HTTPS verified; forcing Argo hard refresh on all Applications to clear transient bootstrap fetch errors"
      refresh_all_argocd_apps_hard
    fi
    return
  fi

  if [[ "${FORGEJO_REMOTE_SWITCH_REQUIRED}" == "true" ]]; then
    log "Forgejo HTTPS readiness check failed and FORGEJO_REMOTE_SWITCH_REQUIRED=true"
    exit 1
  fi
  log "Forgejo HTTPS readiness check failed; continuing bootstrap (set FORGEJO_REMOTE_SWITCH_REQUIRED=true to fail hard)"
}

main() {
  ensure_scripts
  validate_yaml_files
  run_stage0
  require_stage0_sentinel
  run_stage1
  wait_for_root_application
  wait_for_required_vault_apps
  ensure_bootstrap_status_when_skipping
  run_vault_init
  stabilize_bootstrap_external_secrets
  switch_gitops_remote_to_https
  refresh_kind_kubeconfig_final
  wait_for_platform_convergence
  log "Bootstrap sequence finished"
}

main "$@"
