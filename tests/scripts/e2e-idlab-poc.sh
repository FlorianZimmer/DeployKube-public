#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/e2e-idlab-poc.sh [options]

Goal:
  Run the full IdP PoC proof sequence against a clean idlab namespace.
  In auto mode, the script prefers already-present platform-managed
  `proof-of-concepts-idlab*` Applications and only falls back to creating the
  opt-in `idlab-poc` wrapper app when those Applications are absent.

Options:
  --argocd-namespace <ns>   Argo CD namespace (default: argocd)
  --mode <auto|opt-in|existing>
                           Deployment mode (default: auto)
  --app-name <name>         Application name (default: idlab-poc)
  --cleanup <yes|no>        Delete the app/namespace after the run (default: yes)
  --timeout <seconds>       Per wait timeout in seconds (default: 1200)
  --help                    Show this help
EOF
}

need() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: ${bin} not found" >&2
    exit 1
  fi
}

wait_for_application() {
  local ns="$1" name="$2" timeout="$3"
  local start
  start="$(date +%s)"
  while true; do
    if kubectl -n "${ns}" get application "${name}" >/dev/null 2>&1; then
      local state
      state="$(kubectl -n "${ns}" get application "${name}" -o json | jq -r '.status.sync.status + " " + .status.health.status')"
      if [[ "${state}" == "Synced Healthy" ]]; then
        return 0
      fi
    fi
    if (( "$(date +%s)" - start > timeout )); then
      echo "FAIL: timed out waiting for ${ns}/Application/${name} to become Synced Healthy" >&2
      kubectl -n "${ns}" get application "${name}" -o yaml >&2 || true
      return 1
    fi
    sleep 5
  done
}

wait_for_namespace_absent() {
  local name="$1" timeout="$2"
  local start
  start="$(date +%s)"
  while kubectl get namespace "${name}" >/dev/null 2>&1; do
    if (( "$(date +%s)" - start > timeout )); then
      echo "FAIL: timed out waiting for namespace/${name} deletion" >&2
      kubectl get namespace "${name}" -o yaml >&2 || true
      return 1
    fi
    sleep 5
  done
}

wait_for_idlab_runtime_objects() {
  local timeout="$1"
  local start
  start="$(date +%s)"
  while true; do
    if kubectl get namespace idlab >/dev/null 2>&1 \
      && kubectl -n idlab get cluster.postgresql.cnpg.io/idlab-postgres >/dev/null 2>&1 \
      && kubectl -n idlab get deployment/upstream-scim-facade deployment/source-scim-ingest deployment/mkc-scim-facade deployment/btp-scim-facade deployment/sync-controller deployment/ukc-keycloak deployment/mkc-keycloak deployment/btp-keycloak >/dev/null 2>&1 \
      && kubectl -n idlab get job/idlab-seed-ukc >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start > timeout )); then
      echo "FAIL: timed out waiting for idlab runtime objects to be recreated" >&2
      kubectl get namespace idlab -o yaml >&2 || true
      kubectl -n idlab get deployment,job,cluster.postgresql.cnpg.io  >&2 || true
      return 1
    fi
    sleep 5
  done
}

application_exists() {
  local ns="$1" name="$2"
  kubectl -n "${ns}" get application "${name}" >/dev/null 2>&1
}

ensure_application_reconciling() {
  local ns="$1" name="$2"
  if ! application_exists "${ns}" "${name}"; then
    echo "FAIL: expected ${ns}/Application/${name} to exist" >&2
    return 1
  fi
  if kubectl -n "${ns}" get application "${name}" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}' 2>/dev/null | grep -qx 'true'; then
    kubectl -n "${ns}" patch application "${name}" --type=json \
      -p='[{"op":"remove","path":"/metadata/annotations/argocd.argoproj.io~1skip-reconcile"}]' >/dev/null || true
  fi
  kubectl -n "${ns}" patch application "${name}" --type=merge -p '{"operation":null}' >/dev/null || true
  kubectl -n "${ns}" annotate application "${name}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  kubectl -n "${ns}" patch application "${name}" --type=merge \
    -p '{"operation":{"initiatedBy":{"username":"codex"},"sync":{"prune":true,"syncStrategy":{"apply":{}}}}}' >/dev/null
}

pause_application_reconcile() {
  local ns="$1" name="$2"
  if ! application_exists "${ns}" "${name}"; then
    echo "FAIL: expected ${ns}/Application/${name} to exist" >&2
    return 1
  fi
  kubectl -n "${ns}" annotate application "${name}" argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
}

resume_application_reconcile() {
  local ns="$1" name="$2"
  if ! application_exists "${ns}" "${name}"; then
    return 0
  fi
  if kubectl -n "${ns}" get application "${name}" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}' 2>/dev/null | grep -qx 'true'; then
    kubectl -n "${ns}" patch application "${name}" --type=json \
      -p='[{"op":"remove","path":"/metadata/annotations/argocd.argoproj.io~1skip-reconcile"}]' >/dev/null || true
  fi
  kubectl -n "${ns}" patch application "${name}" --type=merge -p '{"operation":null}' >/dev/null || true
  kubectl -n "${ns}" annotate application "${name}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  kubectl -n "${ns}" patch application "${name}" --type=merge \
    -p '{"operation":{"initiatedBy":{"username":"codex"},"sync":{"prune":true,"syncStrategy":{"apply":{}}}}}' >/dev/null || true
}

wait_for_job() {
  local ns="$1" name="$2" timeout="$3"
  local start
  start="$(date +%s)"
  while true; do
    local json
    json="$(kubectl -n "${ns}" get job "${name}" -o json 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      if jq -e '.status.conditions[]? | select(.type=="Complete" and .status=="True")' >/dev/null <<<"${json}"; then
        return 0
      fi
      if jq -e '.status.conditions[]? | select(.type=="Failed" and .status=="True")' >/dev/null <<<"${json}"; then
        echo "FAIL: ${ns}/Job/${name}" >&2
        kubectl -n "${ns}" describe job "${name}" >&2 || true
        kubectl -n "${ns}" logs "job/${name}" --tail=200 >&2 || true
        return 1
      fi
    fi
    if (( "$(date +%s)" - start > timeout )); then
      echo "FAIL: timed out waiting for ${ns}/Job/${name}" >&2
      kubectl -n "${ns}" describe job "${name}" >&2 || true
      kubectl -n "${ns}" logs "job/${name}" --tail=200 >&2 || true
      return 1
    fi
    sleep 5
  done
}

run_job() {
  local ns="$1" name="$2" timeout="$3"
  echo "- ${ns}/Job/${name}"
  kubectl -n "${ns}" patch job "${name}" --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  wait_for_job "${ns}" "${name}" "${timeout}"
}

argocd_namespace="argocd"
mode="auto"
app_name="idlab-poc"
cleanup="yes"
timeout="1200"
active_mode=""
owns_opt_in_app="no"
existing_runtime_app="proof-of-concepts-idlab"
existing_tests_app="proof-of-concepts-idlab-tests"
runtime_apps=()

finalize() {
  local app
  for app in "${runtime_apps[@]}"; do
    resume_application_reconcile "${argocd_namespace}" "${app}"
  done
  if [[ "${cleanup}" == "yes" ]]; then
    teardown
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --argocd-namespace)
      argocd_namespace="${2:-}"
      shift 2
      ;;
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --app-name)
      app_name="${2:-}"
      shift 2
      ;;
    --cleanup)
      cleanup="${2:-}"
      shift 2
      ;;
    --timeout)
      timeout="${2:-}"
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

case "${mode}" in
  auto|opt-in|existing)
    ;;
  *)
    echo "error: unsupported mode '${mode}'" >&2
    usage >&2
    exit 2
    ;;
esac

app_manifest="platform/gitops/apps/opt-in/idlab-poc/applications/idlab-poc-prod.yaml"

teardown() {
  if [[ "${owns_opt_in_app}" == "yes" ]]; then
    kubectl -n "${argocd_namespace}" delete -f "${app_manifest}" --ignore-not-found >/dev/null 2>&1 || true
  fi
  kubectl delete namespace idlab --ignore-not-found >/dev/null 2>&1 || true
}

trap finalize EXIT

if [[ "${mode}" == "auto" ]]; then
  if application_exists "${argocd_namespace}" "${existing_runtime_app}" || application_exists "${argocd_namespace}" "${existing_tests_app}"; then
    active_mode="existing"
  else
    active_mode="opt-in"
  fi
else
  active_mode="${mode}"
fi

case "${active_mode}" in
  existing)
    runtime_apps=("${existing_runtime_app}" "${existing_tests_app}")
    ;;
  opt-in)
    runtime_apps=("${app_name}")
    owns_opt_in_app="yes"
    ;;
esac

echo "==> Resetting prior idlab PoC state"
teardown
wait_for_namespace_absent idlab "${timeout}"

case "${active_mode}" in
  existing)
    echo "==> Using existing Argo apps: ${existing_runtime_app}, ${existing_tests_app}"
    ensure_application_reconciling "${argocd_namespace}" "${existing_runtime_app}"
    ensure_application_reconciling "${argocd_namespace}" "${existing_tests_app}"
    wait_for_idlab_runtime_objects "${timeout}"
    wait_for_application "${argocd_namespace}" "${existing_runtime_app}" "${timeout}"
    wait_for_application "${argocd_namespace}" "${existing_tests_app}" "${timeout}"
    ;;
  opt-in)
    echo "==> Installing opt-in idlab Argo app"
    kubectl -n "${argocd_namespace}" apply -f "${app_manifest}" >/dev/null
    wait_for_idlab_runtime_objects "${timeout}"
    wait_for_application "${argocd_namespace}" "${app_name}" "${timeout}"
    ;;
esac

echo "==> Pausing Argo reconcile for proof execution"
for app in "${runtime_apps[@]}"; do
  pause_application_reconcile "${argocd_namespace}" "${app}"
done

echo "==> Running proof sequence"
jobs=(
  idlab-seed-ukc
  idlab-config-mkc
  idlab-config-btp
  idlab-smoke-provisioning
  idlab-smoke-provisioning-guardrail
  idlab-smoke-auth-online
  idlab-offline-enroll
  idlab-smoke-failover-manual
  idlab-smoke-auth-manual-offline
  idlab-smoke-auth-offline
  idlab-smoke-offline-write
  idlab-smoke-auth-offline-write
  idlab-smoke-failover-auto
  idlab-smoke-failover-auto-manual-return
  idlab-smoke-convergence
  idlab-smoke-negative-mkc-link-only
  idlab-smoke-negative-btp-link-only
)

for job in "${jobs[@]}"; do
  run_job idlab "${job}" "${timeout}"
done

echo "PASS: idlab IdP PoC E2E completed"
