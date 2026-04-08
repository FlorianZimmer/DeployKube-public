#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE0_SENTINEL="${STAGE0_SENTINEL:-${REPO_ROOT}/tmp/stage0-complete}"
CLUSTER_NAME="${CLUSTER_NAME:-deploykube-dev}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
KIND_CONFIG="${KIND_CONFIG:-${REPO_ROOT}/bootstrap/mac-orbstack/cluster/kind-config-single-worker.yaml}"
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-mac-orbstack-single}"
DEPLOYKUBE_CONFIG_FILE="${DEPLOYKUBE_CONFIG_FILE:-${REPO_ROOT}/platform/gitops/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/config.yaml}"
ORBSTACK_SCRIPT="${REPO_ROOT}/shared/scripts/orb-nfs-host.sh"
KIND_REFRESH_KUBECONFIG_SCRIPT="${KIND_REFRESH_KUBECONFIG_SCRIPT:-${REPO_ROOT}/shared/scripts/kind-refresh-kubeconfig.sh}"
LOCAL_REGISTRY_CACHE_SCRIPT="${LOCAL_REGISTRY_CACHE_SCRIPT:-${REPO_ROOT}/shared/scripts/local-registry-cache.sh}"
LOCAL_REGISTRY_CACHE_ENABLE="${LOCAL_REGISTRY_CACHE_ENABLE:-1}"
LOCAL_REGISTRY_NETWORK="${LOCAL_REGISTRY_NETWORK:-kind}"
LOCAL_REGISTRY_CONTEXT="${LOCAL_REGISTRY_CONTEXT:-}"
LOCAL_REGISTRY_WARM_IMAGES="${LOCAL_REGISTRY_WARM_IMAGES:-0}"
LOCAL_REGISTRY_SYNC_SCRIPT="${LOCAL_REGISTRY_SYNC_SCRIPT:-${REPO_ROOT}/shared/scripts/registry-sync.sh}"
NFS_EXPORT_VOLUME="${NFS_EXPORT_VOLUME:-deploykube-nfs-data}"
NFS_HOST_IP="${NFS_HOST_IP:-203.0.113.20}"
NFS_REMOTE_PATH="${NFS_REMOTE_PATH:-/}"
NFS_USE_DOCKER_VOLUME="${NFS_USE_DOCKER_VOLUME:-1}"
NFS_DOCKER_CONTEXT="${NFS_DOCKER_CONTEXT:-orbstack}"
NFS_DOCKER_NETWORK="${NFS_DOCKER_NETWORK:-kind}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-${REPO_ROOT}/nfs-data}"
CILIUM_VALUES="${CILIUM_VALUES:-${REPO_ROOT}/bootstrap/mac-orbstack/cilium/values-single.yaml}"
CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.18.5}"
METALLB_VALUES="${REPO_ROOT}/bootstrap/mac-orbstack/metallb/values.yaml"
METALLB_DIR="${REPO_ROOT}/bootstrap/mac-orbstack/metallb"
METALLB_CHART_VERSION="${METALLB_CHART_VERSION:-0.15.2}"
GATEWAY_API_MANIFEST_PATH="${GATEWAY_API_MANIFEST_PATH:-${REPO_ROOT}/platform/gitops/components/networking/gateway-api/standard-install.yaml}"
SHARED_STORAGE_VALUES="${REPO_ROOT}/bootstrap/mac-orbstack/storage/values.yaml"
SHARED_STORAGE_NAMESPACE="${SHARED_STORAGE_NAMESPACE:-storage-system}"
SHARED_STORAGE_RELEASE="${SHARED_STORAGE_RELEASE:-nfs-provisioner}"
NFS_PROVISIONER_CHART_VERSION="${NFS_PROVISIONER_CHART_VERSION:-4.0.18}"
SHARED_STORAGE_RWO_STORAGECLASS_MANIFEST="${REPO_ROOT}/bootstrap/mac-orbstack/storage/storageclass-rwo.yaml"
SHARED_STORAGE_VERIFY="${SHARED_STORAGE_VERIFY:-0}"
SHARED_STORAGE_PVC_MANIFEST="${REPO_ROOT}/platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-pvc.yaml"
SHARED_STORAGE_WRITER_MANIFEST="${REPO_ROOT}/platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-writer.yaml"
SHARED_STORAGE_READER_MANIFEST="${REPO_ROOT}/platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-reader.yaml"
DEPLOYKUBE_STORAGE_PROFILE="${DEPLOYKUBE_STORAGE_PROFILE:-local-path}"
ENABLE_NFS_HOST="${ENABLE_NFS_HOST:-0}"
LOCAL_STORAGE_KUSTOMIZATION="${LOCAL_STORAGE_KUSTOMIZATION:-${REPO_ROOT}/platform/gitops/components/storage/local-path-provisioner}"
BOOTSTRAP_TOOLS_IMAGE="${BOOTSTRAP_TOOLS_IMAGE:-registry.example.internal/deploykube/bootstrap-tools:1.4}"
BUILD_BOOTSTRAP_TOOLS_SCRIPT="${BUILD_BOOTSTRAP_TOOLS_SCRIPT:-${REPO_ROOT}/shared/scripts/build-bootstrap-tools-image.sh}"
VALIDATION_TOOLS_CORE_IMAGE="${VALIDATION_TOOLS_CORE_IMAGE:-registry.example.internal/deploykube/validation-tools-core:0.1.0}"
BUILD_VALIDATION_TOOLS_CORE_SCRIPT="${BUILD_VALIDATION_TOOLS_CORE_SCRIPT:-${REPO_ROOT}/shared/scripts/build-validation-tools-core-image.sh}"
TENANT_PROVISIONER_IMAGE="${TENANT_PROVISIONER_IMAGE:-registry.example.internal/deploykube/tenant-provisioner:0.2.24}"
BUILD_TENANT_PROVISIONER_SCRIPT="${BUILD_TENANT_PROVISIONER_SCRIPT:-${REPO_ROOT}/shared/scripts/build-tenant-provisioner-image.sh}"
STEP_CA_IMAGE="${STEP_CA_IMAGE:-cr.smallstep.com/smallstep/step-ca:0.28.4}"
PRELOAD_STEP_CA_IMAGE="${PRELOAD_STEP_CA_IMAGE:-1}"
PRELOAD_CERT_MANAGER_IMAGES="${PRELOAD_CERT_MANAGER_IMAGES:-1}"
CERT_MANAGER_IMAGES=(${CERT_MANAGER_IMAGES:-quay.io/jetstack/cert-manager-controller:v1.19.1 quay.io/jetstack/cert-manager-cainjector:v1.19.1 quay.io/jetstack/cert-manager-webhook:v1.19.1 quay.io/jetstack/cert-manager-acmesolver:v1.19.1})

log() {
  printf '[stage0] %s\n' "$1"
}

wait_for_kube_apiserver() {
  local attempts=0
  local max_attempts=${KUBE_API_MAX_ATTEMPTS:-60}
  local delay=${KUBE_API_DELAY_SECONDS:-2}
  while true; do
    if kubectl --context "${KIND_CONTEXT}" get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge "${max_attempts}" ]]; then
      log "kube-apiserver not reachable via context ${KIND_CONTEXT} after $((attempts * delay))s"
      return 1
    fi
    sleep "${delay}"
  done
}

ensure_kind_vm_time_synced() {
  # Helm charts can embed timestamps into generated certs (via template functions like `now`).
  # On macOS+OrbStack, the Linux VM clock can be skewed behind the workstation, which makes
  # those certs "not yet valid" when consumed inside the kind nodes.
  #
  # Best-effort: if the kind VM clock is behind the workstation clock, set it forward using
  # the privileged kind control-plane container.
  local control_plane_container="${CLUSTER_NAME}-control-plane"
  if ! docker inspect "${control_plane_container}" >/dev/null 2>&1; then
    return 0
  fi

  local host_epoch node_epoch
  host_epoch="$(date -u +%s)"
  node_epoch="$(docker exec "${control_plane_container}" date -u +%s 2>/dev/null || true)"
  if [[ -z "${node_epoch}" ]]; then
    log "warning: unable to read kind VM time from ${control_plane_container}; continuing without time sync"
    return 0
  fi

  local max_skew="${KIND_TIME_MAX_SKEW_SECONDS:-2}"
  if (( host_epoch - node_epoch > max_skew )); then
    local host_ts
    host_ts="$(date -u '+%Y-%m-%d %H:%M:%S')"
    log "syncing kind VM time via ${control_plane_container} (skew=$((host_epoch - node_epoch))s)"
    if ! docker exec "${control_plane_container}" sh -c "date -s '${host_ts}'" >/dev/null 2>&1; then
      log "warning: failed to set kind VM time via ${control_plane_container}; bootstrap may fail with TLS 'not yet valid' errors"
      return 0
    fi
  elif (( node_epoch - host_epoch > max_skew )); then
    log "warning: kind VM time is ahead of workstation clock (skew=$((node_epoch - host_epoch))s); refusing to set time backwards"
  fi
}

refresh_kind_kubeconfig() {
  if [[ -x "${KIND_REFRESH_KUBECONFIG_SCRIPT}" ]]; then
    CLUSTER_NAME="${CLUSTER_NAME}" "${KIND_REFRESH_KUBECONFIG_SCRIPT}"
    return 0
  fi
  kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
}

ensure_bootstrap_tools_image() {
  if [[ ! -x "${BUILD_BOOTSTRAP_TOOLS_SCRIPT}" ]]; then
    log "missing bootstrap tools builder at ${BUILD_BOOTSTRAP_TOOLS_SCRIPT}"
    exit 1
  fi
  log "building bootstrap tools image ${BOOTSTRAP_TOOLS_IMAGE}"
  "${BUILD_BOOTSTRAP_TOOLS_SCRIPT}" --image "${BOOTSTRAP_TOOLS_IMAGE}" --cluster "${CLUSTER_NAME}"
}

ensure_validation_tools_core_image() {
  if [[ ! -x "${BUILD_VALIDATION_TOOLS_CORE_SCRIPT}" ]]; then
    log "missing validation tools core builder at ${BUILD_VALIDATION_TOOLS_CORE_SCRIPT}"
    exit 1
  fi
  log "building validation tools core image ${VALIDATION_TOOLS_CORE_IMAGE}"
  "${BUILD_VALIDATION_TOOLS_CORE_SCRIPT}" --image "${VALIDATION_TOOLS_CORE_IMAGE}" --cluster "${CLUSTER_NAME}"
}

ensure_tenant_provisioner_image() {
  if [[ ! -x "${BUILD_TENANT_PROVISIONER_SCRIPT}" ]]; then
    log "missing tenant provisioner builder at ${BUILD_TENANT_PROVISIONER_SCRIPT}"
    exit 1
  fi
  log "building tenant provisioner image ${TENANT_PROVISIONER_IMAGE}"
  "${BUILD_TENANT_PROVISIONER_SCRIPT}" --image "${TENANT_PROVISIONER_IMAGE}" --cluster "${CLUSTER_NAME}"
}

ensure_step_ca_image() {
  if [[ "${PRELOAD_STEP_CA_IMAGE}" != "1" ]]; then
    log "skipping Step CA image preload (PRELOAD_STEP_CA_IMAGE=${PRELOAD_STEP_CA_IMAGE})"
    return
  fi
  if ! docker image inspect "${STEP_CA_IMAGE}" >/dev/null 2>&1; then
    log "pulling Step CA image ${STEP_CA_IMAGE}"
    docker pull "${STEP_CA_IMAGE}"
  fi
  log "loading Step CA image ${STEP_CA_IMAGE} into kind cluster ${CLUSTER_NAME}"
  kind load docker-image --name "${CLUSTER_NAME}" "${STEP_CA_IMAGE}"
}

ensure_cert_manager_images() {
  if [[ "${PRELOAD_CERT_MANAGER_IMAGES}" != "1" ]]; then
    log "skipping cert-manager image preload (PRELOAD_CERT_MANAGER_IMAGES=${PRELOAD_CERT_MANAGER_IMAGES})"
    return
  fi
  local image
  for image in "${CERT_MANAGER_IMAGES[@]}"; do
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      log "pulling cert-manager image ${image}"
      docker pull "${image}"
    fi
    log "loading cert-manager image ${image} into kind cluster ${CLUSTER_NAME}"
    kind load docker-image --name "${CLUSTER_NAME}" "${image}"
  done
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    log "missing dependency '${bin}' – please install it before running stage 0"
    exit 1
  fi
}

ensure_prerequisites() {
  log "validating workstation prerequisites"
  check_dependency kind
  check_dependency kubectl
  check_dependency helm
  check_dependency docker
  check_dependency cilium
  if ! command -v step >/dev/null 2>&1; then
    log "warning: 'step' CLI not found – Step CA values cannot be regenerated; ensure values.local.yaml already exists"
  fi
  if [[ ! -f "${REPO_ROOT}/bootstrap/mac-orbstack/step-ca/values.local.yaml" ]]; then
    log "warning: Step CA values file missing (bootstrap/mac-orbstack/step-ca/values.local.yaml); create it before Stage 1"
  fi
}

ensure_cluster() {
  local kind_cluster_exists=0
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    kind_cluster_exists=1
  fi

  # Prefer the kind runtime as source-of-truth. Kubecontexts can outlive the cluster.
  if [[ "${kind_cluster_exists}" == "1" ]]; then
    if kubectl config get-contexts "${KIND_CONTEXT}" >/dev/null 2>&1; then
      log "kind cluster ${CLUSTER_NAME} already exists; skipping creation"
    else
      log "kind cluster ${CLUSTER_NAME} exists but kubecontext ${KIND_CONTEXT} is missing; restoring kubeconfig"
    fi

    # Ensure kubeconfig points at the currently mapped API port.
    refresh_kind_kubeconfig
    wait_for_kube_apiserver || {
      log "remediation: ensure the kind control-plane container is running, then re-run Stage 0"
      exit 1
    }
    return
  fi

  # If the cluster is gone but the kubecontext remains, clean up the stale entries
  # so Stage 0 can recreate the cluster instead of failing during kubeconfig refresh.
  if kubectl config get-contexts "${KIND_CONTEXT}" >/dev/null 2>&1; then
    log "kubecontext ${KIND_CONTEXT} exists but kind cluster ${CLUSTER_NAME} is missing; removing stale kubeconfig entries"
    kubectl config delete-context "${KIND_CONTEXT}" >/dev/null 2>&1 || true
    kubectl config delete-cluster "${KIND_CONTEXT}" >/dev/null 2>&1 || true
    kubectl config delete-user "${KIND_CONTEXT}" >/dev/null 2>&1 || true
  fi

  log "creating kind cluster ${CLUSTER_NAME}"
  cd "${REPO_ROOT}"
  local create_output
  if ! create_output=$(kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" 2>&1); then
    if [[ "${create_output}" == *"node(s) already exist"* ]]; then
      log "detected stale kind node containers for ${CLUSTER_NAME}; cleaning up and retrying"
      kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
      local stale_containers=()
      mapfile -t stale_containers < <(docker ps -a --format '{{.Names}}' | grep -E "^${CLUSTER_NAME}-(control-plane|worker([0-9]+)?)$" || true)
      if (( ${#stale_containers[@]} > 0 )); then
        docker rm -f "${stale_containers[@]}" >/dev/null 2>&1 || true
      fi
      create_output=$(kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" 2>&1) || {
        printf '%s\n' "${create_output}" >&2
        exit 1
      }
    else
      printf '%s\n' "${create_output}" >&2
      exit 1
    fi
  fi
  printf '%s\n' "${create_output}"
  # Defensive: on some setups kubeconfig can end up with a stale localhost port.
  # Re-export kubeconfig from the live kind cluster to ensure connectivity.
  refresh_kind_kubeconfig
  wait_for_kube_apiserver || {
    log "remediation: wait a few seconds then re-run Stage 0 (or inspect docker logs for ${CLUSTER_NAME}-control-plane)"
    exit 1
  }
  log "kind cluster ${CLUSTER_NAME} ready"
}

ensure_kind_control_plane_dns_fallback() {
  # The kube-apiserver process (static pod) resolves the OIDC issuer host during runtime.
  # On macOS+OrbStack, the default resolver inside the kube-apiserver pod sandbox often
  # returns NXDOMAIN for the in-cluster baseDomain (e.g. dev.internal.*), which prevents
  # the OIDC authenticator from ever initializing.
  #
  # A plain "fallback nameserver" doesn't help here because glibc only tries subsequent
  # resolvers on timeout, not on NXDOMAIN. Wire the kube-apiserver sandbox to use the
  # in-cluster DNS Service (CoreDNS) as its *primary* resolver instead.
  local kube_dns_ip
  kube_dns_ip="$(kubectl --context "${KIND_CONTEXT}" -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -z "${kube_dns_ip}" ]]; then
    log "warning: unable to determine kube-dns ClusterIP; skipping kind control-plane DNS wiring (OIDC smokes may fail)"
    return 0
  fi

  local control_plane_container="${CLUSTER_NAME}-control-plane"
  if ! docker inspect "${control_plane_container}" >/dev/null 2>&1; then
    log "warning: kind control-plane container ${control_plane_container} not found; skipping DNS fallback wiring"
    return 0
  fi

  local apiserver_container_id
  apiserver_container_id="$(docker exec "${control_plane_container}" sh -c "crictl ps -q --name kube-apiserver" 2>/dev/null | head -n 1 || true)"
  if [[ -z "${apiserver_container_id}" ]]; then
    log "warning: could not locate kube-apiserver container via crictl in ${control_plane_container}; skipping DNS fallback wiring"
    return 0
  fi

  local sandbox_resolv
  sandbox_resolv="$(
    docker exec "${control_plane_container}" sh -c "
      crictl inspect '${apiserver_container_id}' \
        | grep -m1 -E 'sandboxes/.*/resolv\\.conf' \
        | sed -E 's/.*\"source\": \"([^\"]+)\".*/\\1/'
    " 2>/dev/null || true
  )"
  if [[ -z "${sandbox_resolv}" ]]; then
    log "warning: could not determine kube-apiserver sandbox resolv.conf path (container=${apiserver_container_id}); skipping DNS fallback wiring"
    return 0
  fi

  if docker exec "${control_plane_container}" sh -c "head -n 5 '${sandbox_resolv}' | grep -qE '^nameserver[[:space:]]+${kube_dns_ip}$'" >/dev/null 2>&1; then
    log "kube-apiserver sandbox resolv.conf already prefers kube-dns (${kube_dns_ip}); skipping restart"
    return 0
  fi

  log "wiring kube-apiserver sandbox DNS to prefer kube-dns (${kube_dns_ip}) (sandbox resolv.conf: ${sandbox_resolv})"
  docker exec "${control_plane_container}" sh -c "
    set -eu
    tmp='${sandbox_resolv}.deploykube.tmp'
    awk -v dns='${kube_dns_ip}' '
      BEGIN { inserted=0 }
      /^nameserver[[:space:]]+/ {
        if (!inserted) { print \"nameserver \" dns; inserted=1 }
        if (\$2 != dns) { print }
        next
      }
      { print }
      END { if (!inserted) { print \"nameserver \" dns } }
    ' '${sandbox_resolv}' > \"\$tmp\"
    mv \"\$tmp\" '${sandbox_resolv}'
  "

  log "restarting kube-apiserver container to pick up updated sandbox resolv.conf"
  docker exec "${control_plane_container}" sh -c "crictl stop '${apiserver_container_id}' && crictl rm '${apiserver_container_id}'" >/dev/null 2>&1 || true
  wait_for_kube_apiserver || {
    log "kube-apiserver did not recover after restart; investigate node logs (${control_plane_container})"
    exit 1
  }
}

ensure_local_registry_cache() {
  if [[ "${LOCAL_REGISTRY_CACHE_ENABLE}" != "1" ]]; then
    log "local registry cache disabled (LOCAL_REGISTRY_CACHE_ENABLE=0)"
    return
  fi
  if [[ ! -x "${LOCAL_REGISTRY_CACHE_SCRIPT}" ]]; then
    log "local registry cache helper missing at ${LOCAL_REGISTRY_CACHE_SCRIPT}"
    exit 1
  fi
  local context
  if [[ -n "${LOCAL_REGISTRY_CONTEXT}" ]]; then
    context="${LOCAL_REGISTRY_CONTEXT}"
  else
    context="$(docker context show 2>/dev/null || echo default)"
  fi
  log "ensuring local registry cache containers (context=${context}, network=${LOCAL_REGISTRY_NETWORK})"
  "${LOCAL_REGISTRY_CACHE_SCRIPT}" up --context "${context}" --network "${LOCAL_REGISTRY_NETWORK}"
}

warm_local_registry_cache() {
  if [[ "${LOCAL_REGISTRY_WARM_IMAGES}" != "1" ]]; then
    log "skipping registry warm (LOCAL_REGISTRY_WARM_IMAGES=0)"
    return
  fi
  if [[ ! -x "${LOCAL_REGISTRY_SYNC_SCRIPT}" ]]; then
    log "registry sync helper missing at ${LOCAL_REGISTRY_SYNC_SCRIPT}"
    exit 1
  fi
  # Warming requires additional tools; keep it optional and non-fatal so new machines can
  # bootstrap without installing extra dependencies up front.
  local missing=()
  command -v rg >/dev/null 2>&1 || missing+=("rg")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  command -v skopeo >/dev/null 2>&1 || missing+=("skopeo")
  if (( ${#missing[@]} > 0 )); then
    log "warning: cannot warm registry caches; missing dependencies: ${missing[*]} (install them or set LOCAL_REGISTRY_WARM_IMAGES=0)"
    return
  fi
  log "warming registry caches from repo image references"
  "${LOCAL_REGISTRY_SYNC_SCRIPT}"
}

ensure_orbstack_nfs_host() {
  if [[ ! -x "${ORBSTACK_SCRIPT}" ]]; then
    log "cannot locate OrbStack helper at ${ORBSTACK_SCRIPT}"
    exit 1
  fi
  log "ensuring OrbStack NFS host container is running"
  local volume_flag
  if [[ "${NFS_USE_DOCKER_VOLUME}" == "1" ]]; then
    volume_flag=(--use-volume --export-volume "${NFS_EXPORT_VOLUME}")
  else
    volume_flag=(--no-volume --export-path "${NFS_EXPORT_PATH}")
  fi
  "${ORBSTACK_SCRIPT}" up \
    "${volume_flag[@]}" \
    --network "${NFS_DOCKER_NETWORK}" \
    --context "${NFS_DOCKER_CONTEXT}" \
    --ip "${NFS_HOST_IP}"
}

ensure_cilium() {
  if kubectl --context "${KIND_CONTEXT}" -n kube-system get daemonset cilium >/dev/null 2>&1; then
    log "Cilium already installed; waiting for daemonset readiness"
    kubectl --context "${KIND_CONTEXT}" -n kube-system rollout status daemonset/cilium --timeout=300s
    return
  fi
  log "installing Cilium via cilium-cli"
  cilium install \
    --context "${KIND_CONTEXT}" \
    --version "${CILIUM_CHART_VERSION}" \
    --helm-values "${CILIUM_VALUES}"
  cilium status --context "${KIND_CONTEXT}" --wait --wait-duration "${CILIUM_WAIT_DURATION:-5m}"
}

ensure_metallb() {
  # Stage 0 is intended to be re-runnable even after Stage 1 (Argo CD) has taken over
  # ownership of MetalLB resources. In that case, Helm server-side apply can conflict
  # with Argo's field manager. Prefer skipping Helm and just ensuring the IP pools exist.
  if kubectl --context "${KIND_CONTEXT}" -n metallb-system get deployment metallb-controller >/dev/null 2>&1; then
    log "MetalLB already present; skipping Helm install/upgrade (avoid Argo field-manager conflicts)"
  else
    log "installing/upgrading MetalLB"
    helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
    helm upgrade --install metallb metallb/metallb \
      --version "${METALLB_CHART_VERSION}" \
      --namespace metallb-system \
      --create-namespace \
      --disable-openapi-validation \
      --kube-context "${KIND_CONTEXT}" \
      --values "${METALLB_VALUES}"

    log "waiting for MetalLB components"
    kubectl --context "${KIND_CONTEXT}" -n metallb-system rollout status deployment/metallb-controller --timeout=180s
    kubectl --context "${KIND_CONTEXT}" -n metallb-system rollout status daemonset/metallb-speaker --timeout=180s
  fi

  log "applying MetalLB address pools"
  kubectl --context "${KIND_CONTEXT}" apply -f "${METALLB_DIR}/ipaddresspool.yaml"
}

ensure_gateway_api() {
  log "applying Gateway API CRDs (stage 0 baseline)"
  if [[ ! -f "${GATEWAY_API_MANIFEST_PATH}" ]]; then
    log "missing Gateway API manifest at ${GATEWAY_API_MANIFEST_PATH}"
    exit 1
  fi
  kubectl --context "${KIND_CONTEXT}" apply -f "${GATEWAY_API_MANIFEST_PATH}"
}

ensure_shared_storage() {
  local provisioner="deployment/${SHARED_STORAGE_RELEASE}-nfs-subdir-external-provisioner"
  if kubectl --context "${KIND_CONTEXT}" -n "${SHARED_STORAGE_NAMESPACE}" get ${provisioner} >/dev/null 2>&1; then
    log "shared NFS provisioner already present; skipping Helm install/upgrade (avoid Argo field-manager conflicts)"
  else
    log "installing shared NFS provisioner"
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner >/dev/null 2>&1 || true
    helm upgrade --install "${SHARED_STORAGE_RELEASE}" nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
      --version "${NFS_PROVISIONER_CHART_VERSION}" \
      --namespace "${SHARED_STORAGE_NAMESPACE}" \
      --create-namespace \
      --kube-context "${KIND_CONTEXT}" \
      --values "${SHARED_STORAGE_VALUES}" \
      --set nfs.server="${NFS_HOST_IP}" \
      --set nfs.path="${NFS_REMOTE_PATH}"
  fi

  kubectl --context "${KIND_CONTEXT}" -n "${SHARED_STORAGE_NAMESPACE}" rollout status ${provisioner} --timeout=180s

  log "applying shared-rwo storage class"
  kubectl --context "${KIND_CONTEXT}" apply -f "${SHARED_STORAGE_RWO_STORAGECLASS_MANIFEST}"

  log "setting shared-rwo as default storage class"
  kubectl --context "${KIND_CONTEXT}" annotate storageclass shared-rwo storageclass.kubernetes.io/is-default-class="true" --overwrite >/dev/null
  if kubectl --context "${KIND_CONTEXT}" get storageclass standard >/dev/null 2>&1; then
    log "demoting standard storage class"
    kubectl --context "${KIND_CONTEXT}" annotate storageclass standard storageclass.kubernetes.io/is-default-class="false" --overwrite >/dev/null
  fi
}

verify_shared_storage() {
  if [[ "${SHARED_STORAGE_VERIFY}" != "1" ]]; then
    log "skipping shared storage verification (SHARED_STORAGE_VERIFY=0)"
    return
  fi
  log "running shared storage smoke test"
  kubectl --context "${KIND_CONTEXT}" apply -f "${SHARED_STORAGE_PVC_MANIFEST}"
  kubectl --context "${KIND_CONTEXT}" apply -f "${SHARED_STORAGE_WRITER_MANIFEST}"
  kubectl --context "${KIND_CONTEXT}" wait --for=condition=complete job/shared-rwo-writer --timeout=120s
  kubectl --context "${KIND_CONTEXT}" apply -f "${SHARED_STORAGE_READER_MANIFEST}"
  kubectl --context "${KIND_CONTEXT}" wait --for=condition=complete job/shared-rwo-reader --timeout=120s
  kubectl --context "${KIND_CONTEXT}" delete -f "${SHARED_STORAGE_WRITER_MANIFEST}" --ignore-not-found
  kubectl --context "${KIND_CONTEXT}" delete -f "${SHARED_STORAGE_READER_MANIFEST}" --ignore-not-found
  kubectl --context "${KIND_CONTEXT}" delete -f "${SHARED_STORAGE_PVC_MANIFEST}" --ignore-not-found
}

ensure_local_storage() {
  if kubectl --context "${KIND_CONTEXT}" get storageclass shared-rwo >/dev/null 2>&1; then
    log "StorageClass shared-rwo already present"
  else
    log "applying local-path provisioner + shared-rwo StorageClass (${LOCAL_STORAGE_KUSTOMIZATION})"
    kubectl --context "${KIND_CONTEXT}" apply -k "${LOCAL_STORAGE_KUSTOMIZATION}"
  fi

  log "setting shared-rwo as default storage class"
  kubectl --context "${KIND_CONTEXT}" annotate storageclass shared-rwo storageclass.kubernetes.io/is-default-class="true" --overwrite >/dev/null
  if kubectl --context "${KIND_CONTEXT}" get storageclass standard >/dev/null 2>&1; then
    log "demoting standard storage class"
    kubectl --context "${KIND_CONTEXT}" annotate storageclass standard storageclass.kubernetes.io/is-default-class="false" --overwrite >/dev/null
  fi
}

main() {
  ensure_prerequisites
  ensure_cluster
  ensure_kind_vm_time_synced
  ensure_kind_control_plane_dns_fallback
  ensure_local_registry_cache
  warm_local_registry_cache
  if [[ "${ENABLE_NFS_HOST}" != "0" ]]; then
    ensure_orbstack_nfs_host
  else
    log "skipping OrbStack NFS host (ENABLE_NFS_HOST=0)"
  fi
  ensure_cilium
  ensure_metallb
  ensure_gateway_api
  case "${DEPLOYKUBE_STORAGE_PROFILE}" in
    shared-nfs)
      ensure_shared_storage
      verify_shared_storage
      ;;
    local-path)
      ensure_local_storage
      ;;
    *)
      log "unknown DEPLOYKUBE_STORAGE_PROFILE=${DEPLOYKUBE_STORAGE_PROFILE} (expected: shared-nfs|local-path)"
      exit 1
      ;;
  esac
  ensure_bootstrap_tools_image
  ensure_validation_tools_core_image
  ensure_tenant_provisioner_image
  ensure_step_ca_image
  ensure_cert_manager_images
  mkdir -p "$(dirname "${STAGE0_SENTINEL}")"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STAGE0_SENTINEL}"
  log "Stage 0 complete – cluster and foundational services are ready for GitOps bootstrap (sentinel: ${STAGE0_SENTINEL})"
}

main "$@"
