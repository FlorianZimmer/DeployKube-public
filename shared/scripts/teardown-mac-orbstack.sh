#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE0_SENTINEL="${STAGE0_SENTINEL:-${REPO_ROOT}/tmp/stage0-complete}"
CLUSTER_NAME="${CLUSTER_NAME:-deploykube-dev}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-5s}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CONTROLLER_DEPLOYMENT="${ARGOCD_CONTROLLER_DEPLOYMENT:-argo-cd-argocd-application-controller}"
ARGOCD_PAUSE_STRATEGY="${ARGOCD_PAUSE_STRATEGY:-scale}"
ARGO_ROOT_APPLICATION="${ARGO_ROOT_APPLICATION:-platform-apps}"
GITOPS_DATA_NAMESPACES="${GITOPS_DATA_NAMESPACES:-vault-system external-secrets forgejo}"
EXTERNAL_SECRETS_NAMESPACE="${EXTERNAL_SECRETS_NAMESPACE:-external-secrets}"
NAMESPACE_DELETE_TIMEOUT_SECONDS="${NAMESPACE_DELETE_TIMEOUT_SECONDS:-600}"
ENABLE_SHARED_STORAGE="${ENABLE_SHARED_STORAGE:-1}"
SHARED_STORAGE_NAMESPACE="${SHARED_STORAGE_NAMESPACE:-storage-system}"
HOST_NFS_SCRIPT="${HOST_NFS_SCRIPT:-${REPO_ROOT}/shared/scripts/orb-nfs-host.sh}"
NFS_EXPORT_VOLUME="${NFS_EXPORT_VOLUME:-deploykube-nfs-data}"
NFS_USE_DOCKER_VOLUME="${NFS_USE_DOCKER_VOLUME:-1}"
if [[ "${NFS_USE_DOCKER_VOLUME}" == "0" ]]; then
  NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-${REPO_ROOT}/nfs-data}"
else
  NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-}"
fi
NFS_DOCKER_CONTEXT="${NFS_DOCKER_CONTEXT:-orbstack}"
WIPE_NFS_DATA="${WIPE_NFS_DATA:-0}"
ROOT_APP_AUTOSYNC_DISABLED=0

log() {
  printf '[+] %s\n' "$1"
}

run_command_with_timeout() {
  local timeout_seconds="$1"
  shift
  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
args = sys.argv[2:]

try:
    completed = subprocess.run(args, timeout=timeout, check=False)
except subprocess.TimeoutExpired:
    sys.exit(124)

sys.exit(completed.returncode)
PY
}

cluster_exists() {
  python3 - "${CLUSTER_NAME}" <<'PY'
import subprocess
import sys

cluster_name = sys.argv[1]
try:
    proc = subprocess.run(
        ["kind", "get", "clusters"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
except Exception:
    sys.exit(1)

clusters = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
sys.exit(0 if cluster_name in clusters else 1)
PY
}

kubectl_ctx() {
  kubectl --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" --context "${KIND_CONTEXT}" "$@"
}

cluster_reachable() {
  kubectl_ctx get --raw='/readyz' >/dev/null 2>&1
}

namespace_exists() {
  kubectl_ctx get namespace "$1" >/dev/null 2>&1
}

remove_external_secrets_finalizers() {
  local namespace="$1"
  if [[ "${namespace}" == "${EXTERNAL_SECRETS_NAMESPACE}" ]]; then
    local dep
    for dep in external-secrets external-secrets-cert-controller external-secrets-webhook; do
      kubectl_ctx -n "${namespace}" scale deployment "${dep}" --replicas=0 >/dev/null 2>&1 || true
    done
    # Prevent the controller from re-adding finalizers while teardown is in progress.
    for _ in {1..30}; do
      local pending=0
      for dep in external-secrets external-secrets-cert-controller external-secrets-webhook; do
        if ! kubectl_ctx -n "${namespace}" get deployment "${dep}" >/dev/null 2>&1; then
          continue
        fi
        local ready
        ready="$(kubectl_ctx -n "${namespace}" get deployment "${dep}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
        [[ -z "${ready}" ]] && ready=0
        if [[ "${ready}" != "0" ]]; then
          pending=1
        fi
      done
      if [[ "${pending}" == "0" ]]; then
        break
      fi
      sleep 1
    done
  fi
  if ! kubectl_ctx get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    return 0
  fi
  local -a resources=()
  mapfile -t resources < <(kubectl_ctx -n "${namespace}" get externalsecrets.external-secrets.io -o name 2>/dev/null || true)
  if (( ${#resources[@]} == 0 )); then
    return 0
  fi
  log "removing ExternalSecret finalizers in ${namespace} (avoid stuck namespace termination)"
  local r
  for r in "${resources[@]}"; do
    kubectl_ctx -n "${namespace}" delete "${r}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl_ctx -n "${namespace}" patch "${r}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kubectl_ctx -n "${namespace}" patch "${r}" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  done
}

remove_finalizers_for_resource_instances() {
  local namespace="$1"
  local resource="$2"
  local -a instances=()
  mapfile -t instances < <(kubectl_ctx -n "${namespace}" get "${resource}" -o name 2>/dev/null || true)
  if (( ${#instances[@]} == 0 )); then
    return 0
  fi
  local instance
  for instance in "${instances[@]}"; do
    local finalizers
    finalizers="$(kubectl_ctx -n "${namespace}" get "${instance}" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
    if [[ -z "${finalizers}" ]] || [[ "${finalizers}" == "[]" ]]; then
      continue
    fi
    kubectl_ctx -n "${namespace}" patch "${instance}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kubectl_ctx -n "${namespace}" patch "${instance}" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  done
}

remove_known_namespace_finalizers() {
  local namespace="$1"
  local -a resources=(
    "externalsecrets.external-secrets.io"
    "jobs.batch"
    "pods"
    "persistentvolumeclaims"
  )
  local resource
  for resource in "${resources[@]}"; do
    remove_finalizers_for_resource_instances "${namespace}" "${resource}"
  done
}

force_finalize_namespace() {
  local namespace="$1"
  log "forcing namespace finalizer removal for ${namespace}"
  kubectl_ctx patch namespace "${namespace}" --type=merge -p '{"spec":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl_ctx patch namespace "${namespace}" --type=json -p='[{"op":"remove","path":"/spec/finalizers"}]' >/dev/null 2>&1 || true
}

wait_namespace_deleted() {
  local namespace="$1"
  local timeout_seconds="$2"
  local end_ts=$(( $(date +%s) + timeout_seconds ))
  while (( $(date +%s) < end_ts )); do
    if ! namespace_exists "${namespace}"; then
      return 0
    fi
    sleep 2
  done
  if ! namespace_exists "${namespace}"; then
    return 0
  fi
  return 1
}

wait_argocd_controller_scaled_down() {
  local controller_kind="$1"
  local controller_name="$2"
  local readiness_jsonpath="$3"
  local attempts=120
  local i
  for ((i=0; i<attempts; i++)); do
    if ! kubectl_ctx -n "${ARGOCD_NAMESPACE}" get "${controller_kind}" "${controller_name}" >/dev/null 2>&1; then
      return 0
    fi
    local desired actual
    desired="$(kubectl_ctx -n "${ARGOCD_NAMESPACE}" get "${controller_kind}" "${controller_name}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    actual="$(kubectl_ctx -n "${ARGOCD_NAMESPACE}" get "${controller_kind}" "${controller_name}" -o jsonpath="${readiness_jsonpath}" 2>/dev/null || true)"
    [[ -z "${desired}" ]] && desired="1"
    [[ -z "${actual}" ]] && actual="0"
    if [[ "${desired}" == "0" && "${actual}" == "0" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

application_exists() {
  kubectl_ctx -n "${ARGOCD_NAMESPACE}" get application "$1" >/dev/null 2>&1
}

disable_root_application_autosync() {
  if [[ -z "${ARGO_ROOT_APPLICATION}" ]] || [[ "${ROOT_APP_AUTOSYNC_DISABLED}" == "1" ]]; then
    return
  fi
  if ! cluster_exists || ! cluster_reachable || ! namespace_exists "${ARGOCD_NAMESPACE}"; then
    return
  fi
  if ! application_exists "${ARGO_ROOT_APPLICATION}"; then
    log "root Argo Application ${ARGO_ROOT_APPLICATION} not found; skipping auto-sync pause"
    ARGO_ROOT_APPLICATION=""
    return
  fi
  log "disabling auto-sync on Argo Application ${ARGO_ROOT_APPLICATION}"
  if kubectl_ctx -n "${ARGOCD_NAMESPACE}" patch application "${ARGO_ROOT_APPLICATION}" \
    --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":false}}}}' >/dev/null 2>&1; then
    ROOT_APP_AUTOSYNC_DISABLED=1
  else
    log "failed to disable auto-sync on ${ARGO_ROOT_APPLICATION}; continuing teardown"
  fi
}

enable_root_application_autosync() {
  if [[ "${ROOT_APP_AUTOSYNC_DISABLED}" != "1" ]] || [[ -z "${ARGO_ROOT_APPLICATION}" ]]; then
    return
  fi
  if ! cluster_exists || ! cluster_reachable || ! namespace_exists "${ARGOCD_NAMESPACE}"; then
    ROOT_APP_AUTOSYNC_DISABLED=0
    return
  fi
  log "re-enabling auto-sync on Argo Application ${ARGO_ROOT_APPLICATION}"
  kubectl_ctx -n "${ARGOCD_NAMESPACE}" patch application "${ARGO_ROOT_APPLICATION}" \
    --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
  ROOT_APP_AUTOSYNC_DISABLED=0
}

cleanup() {
  enable_root_application_autosync
}

trap cleanup EXIT

pause_argocd_controller() {
  if [[ "${ARGOCD_PAUSE_STRATEGY}" != "scale" ]]; then
    if [[ "${ARGOCD_PAUSE_STRATEGY}" != "autosync" ]]; then
      log "unknown ARGOCD_PAUSE_STRATEGY=${ARGOCD_PAUSE_STRATEGY}; defaulting to autosync"
    fi
    disable_root_application_autosync
    log "Argo CD auto-sync paused; skipping controller scale-down (ARGOCD_PAUSE_STRATEGY=autosync)"
    return
  fi

  if ! cluster_exists; then
    log "cluster ${CLUSTER_NAME} not found; skipping Argo CD scale-down"
    return
  fi

  if ! namespace_exists "${ARGOCD_NAMESPACE}"; then
    log "Argo CD namespace ${ARGOCD_NAMESPACE} not present; skipping scale-down"
    return
  fi

  local controller_kind=""
  local deployment_jsonpath=""
  if kubectl_ctx -n "${ARGOCD_NAMESPACE}" get statefulset "${ARGOCD_CONTROLLER_DEPLOYMENT}" >/dev/null 2>&1; then
    controller_kind="statefulset"
    deployment_jsonpath='{.spec.replicas}'
  elif kubectl_ctx -n "${ARGOCD_NAMESPACE}" get deployment "${ARGOCD_CONTROLLER_DEPLOYMENT}" >/dev/null 2>&1; then
    controller_kind="deployment"
    deployment_jsonpath='{.spec.replicas}'
  else
    log "Argo CD application controller ${ARGOCD_CONTROLLER_DEPLOYMENT} absent; skipping scale-down"
    return
  fi

  local replicas
  replicas="$(kubectl_ctx -n "${ARGOCD_NAMESPACE}" get "${controller_kind}" "${ARGOCD_CONTROLLER_DEPLOYMENT}" -o jsonpath="${deployment_jsonpath}")"
  if [[ "${replicas}" == "0" ]]; then
    log "Argo CD application controller already scaled to 0 replicas"
    return
  fi

  disable_root_application_autosync

  log "scaling Argo CD application controller (${controller_kind}) to 0 replicas to pause GitOps reconciliations"
  kubectl_ctx -n "${ARGOCD_NAMESPACE}" scale "${controller_kind}" "${ARGOCD_CONTROLLER_DEPLOYMENT}" --replicas=0 >/dev/null

  local wait_path
  if [[ "${controller_kind}" == "statefulset" ]]; then
    wait_path='{.status.readyReplicas}'
  else
    wait_path='{.status.availableReplicas}'
  fi

  if ! wait_argocd_controller_scaled_down "${controller_kind}" "${ARGOCD_CONTROLLER_DEPLOYMENT}" "${wait_path}"; then
    log "Argo CD controller scale-down wait timed out; continuing teardown"
  fi
}

delete_namespace_if_exists() {
  local namespace="$1"
  if ! namespace_exists "${namespace}"; then
    log "namespace ${namespace} not found; skipping deletion"
    return
  fi

  # External Secrets installs finalizers on ExternalSecret CRs. During a wipe the controller may
  # already be gone, leaving the namespace stuck in Terminating. Remove them best-effort.
  remove_external_secrets_finalizers "${namespace}"
  remove_known_namespace_finalizers "${namespace}"

  log "deleting namespace ${namespace}"
  kubectl_ctx delete namespace "${namespace}" --wait=false >/dev/null
  if ! wait_namespace_deleted "${namespace}" "${NAMESPACE_DELETE_TIMEOUT_SECONDS}"; then
    log "namespace ${namespace} did not terminate cleanly; retrying with forced namespace finalizer removal"
    force_finalize_namespace "${namespace}"
    wait_namespace_deleted "${namespace}" 60 || true
    if namespace_exists "${namespace}"; then
      log "namespace ${namespace} failed to terminate within ${NAMESPACE_DELETE_TIMEOUT_SECONDS}s; investigate manually if data persists"
    fi
  fi
}

cleanup_gitops_namespaces() {
  if ! cluster_exists; then
    log "cluster ${CLUSTER_NAME} not found; skipping namespace cleanup"
    return
  fi
  if ! cluster_reachable; then
    log "cluster ${CLUSTER_NAME} API not reachable; skipping namespace cleanup and proceeding to kind deletion"
    return
  fi

  local namespace
  local -a immediate_namespaces=()
  local -a deferred_namespaces=()

  if [[ -n "${GITOPS_DATA_NAMESPACES}" ]]; then
    # shellcheck disable=SC2206 # word splitting intentional to preserve caller-provided ordering
    local namespaces=(${GITOPS_DATA_NAMESPACES})
    for namespace in "${namespaces[@]}"; do
      if [[ "${namespace}" == "${EXTERNAL_SECRETS_NAMESPACE}" ]]; then
        deferred_namespaces+=("${namespace}")
      else
        immediate_namespaces+=("${namespace}")
      fi
    done
  fi

  for namespace in "${immediate_namespaces[@]}"; do
    delete_namespace_if_exists "${namespace}"
  done

  if [[ ${#deferred_namespaces[@]} -gt 0 ]]; then
    log "deleting deferred namespaces after their webhook consumers: ${deferred_namespaces[*]}"
    for namespace in "${deferred_namespaces[@]}"; do
      delete_namespace_if_exists "${namespace}"
    done
  fi

  if [[ "${ENABLE_SHARED_STORAGE}" != "0" ]]; then
    delete_namespace_if_exists "${SHARED_STORAGE_NAMESPACE}"
  fi
}

force_remove_kind_nodes() {
  local nodes
  nodes=$(docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}' 2>/dev/null || true)
  if [[ -n "${nodes}" ]]; then
    log "force removing lingering kind containers: ${nodes}"
    docker rm -f ${nodes} >/dev/null 2>&1 || true
  fi
}

delete_kind_cluster() {
  if ! cluster_exists; then
    log "cluster ${CLUSTER_NAME} not found; nothing to delete"
    return
  fi

  log "deleting kind cluster ${CLUSTER_NAME}"
  if kind delete cluster --name "${CLUSTER_NAME}"; then
    return
  fi

  log "kind delete cluster failed; forcing container removal"
  force_remove_kind_nodes
}

teardown_host_nfs() {
  if [[ "${ENABLE_SHARED_STORAGE}" == "0" ]]; then
    log "skipping host NFS teardown (ENABLE_SHARED_STORAGE=0)"
    return
  fi

  if [[ ! -x "${HOST_NFS_SCRIPT}" ]]; then
    log "host NFS helper script missing at ${HOST_NFS_SCRIPT}; verify container manually"
    return
  fi

  log "stopping OrbStack NFS host container"
  if [[ "${NFS_USE_DOCKER_VOLUME}" == "0" ]]; then
    if ! run_command_with_timeout 30 "${HOST_NFS_SCRIPT}" down \
      --context "${NFS_DOCKER_CONTEXT}" \
      --export-path "${NFS_EXPORT_PATH}"; then
      log "host NFS teardown command timed out or failed; continuing"
    fi
  else
    if ! run_command_with_timeout 30 "${HOST_NFS_SCRIPT}" down \
      --context "${NFS_DOCKER_CONTEXT}" \
      --export-volume "${NFS_EXPORT_VOLUME}"; then
      log "host NFS teardown command timed out or failed; continuing"
    fi
  fi
}

wipe_nfs_data() {
  if [[ "${WIPE_NFS_DATA}" != "1" ]]; then
    log "skipping NFS data wipe (WIPE_NFS_DATA=${WIPE_NFS_DATA})"
    return
  fi
  local descriptor
  if [[ "${NFS_USE_DOCKER_VOLUME}" == "0" ]]; then
    descriptor="path=${NFS_EXPORT_PATH}"
  else
    descriptor="volume=${NFS_EXPORT_VOLUME}"
  fi
  log "wiping OrbStack NFS data (${descriptor})"
  if [[ "${NFS_USE_DOCKER_VOLUME}" == "0" ]]; then
    if [[ -z "${NFS_EXPORT_PATH}" ]]; then
      log "NFS_EXPORT_PATH not set while NFS_USE_DOCKER_VOLUME=0; skipping data wipe"
      return
    fi
    rm -rf "${NFS_EXPORT_PATH:?}/"*
  else
    if ! command -v docker >/dev/null 2>&1; then
      log "docker CLI missing; cannot wipe OrbStack volume ${NFS_EXPORT_VOLUME}"
      return
    fi
    run_command_with_timeout 30 docker --context "${NFS_DOCKER_CONTEXT}" run --rm -v "${NFS_EXPORT_VOLUME}:/export" alpine:3.20 \
      sh -c 'set -euo pipefail; rm -rf /export/*' >/dev/null 2>&1 || true
    if run_command_with_timeout 10 docker --context "${NFS_DOCKER_CONTEXT}" volume inspect "${NFS_EXPORT_VOLUME}" >/dev/null 2>&1; then
      if run_command_with_timeout 20 docker --context "${NFS_DOCKER_CONTEXT}" volume rm "${NFS_EXPORT_VOLUME}" >/dev/null 2>&1; then
        log "deleted OrbStack NFS volume ${NFS_EXPORT_VOLUME}"
      else
        log "failed to remove OrbStack NFS volume ${NFS_EXPORT_VOLUME}; remove it manually if it persists"
      fi
    fi
  fi
}

pause_argocd_controller
cleanup_gitops_namespaces
delete_kind_cluster
teardown_host_nfs
wipe_nfs_data
rm -f "${STAGE0_SENTINEL}"
