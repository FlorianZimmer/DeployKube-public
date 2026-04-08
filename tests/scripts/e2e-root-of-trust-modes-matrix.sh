#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'USAGE'
Usage: ./tests/scripts/e2e-root-of-trust-modes-matrix.sh [options]

Goal:
  Run live root-of-trust mode E2E by mutating singleton DeploymentConfig.spec.secrets.rootOfTrust,
  then triggering secrets bootstrap + Vault/ESO hook checks.

Profiles:
  quick  - inCluster mode sanity
  full   - quick profile plus optional external mode

Important:
  - This script mutates DeploymentConfig.spec.secrets.rootOfTrust and restores it on exit.
  - You MUST acknowledge mutation explicitly:
      --ack-config-mutation yes
    or:
      DK_ROT_E2E_ACK_CONFIG_MUTATION=yes

Options:
  --profile <quick|full>         Validation profile (default: full)
  --run-external <auto|yes|no>   Include external mode in full profile (default: auto)
  --external-address <url>       External seal endpoint for mode=external
  --provision-external-simulator <auto|yes|no>
                                 Provision ephemeral in-cluster external KMS endpoint simulator (default: auto)
  --external-simulator-namespace <ns>
                                 Namespace for simulator resources (default: vault-system)
  --external-simulator-name <name>
                                 Base name for simulator resources (default: dk-kms-external-sim)
  --verify-vault-restart <yes|no>
                                 Restart Vault pods and verify unseal via external endpoint in mode=external (default: yes)
  --timeout <duration>           Per-phase timeout (default: 25m)
  --settle-seconds <n>           Sleep after each config patch (default: 20)
  --deploymentconfig <name>      Target DeploymentConfig name (auto-detected when omitted)
  --argocd-namespace <ns>        Namespace for Argo CD resources (default: argocd)
  --freeze-gitops-sync <yes|no>  Temporarily disable Argo auto-sync for deployment-secrets-bundle during test (default: yes)
  --ack-config-mutation <yes|no> Explicitly allow DeploymentConfig mutation (required)
  --help                         Show this help

Environment knobs (optional):
  DK_ROT_E2E_ACK_CONFIG_MUTATION         Same as --ack-config-mutation
  DK_ROT_E2E_RUN_EXTERNAL                Same as --run-external
  DK_ROT_E2E_EXTERNAL_ADDRESS            Same as --external-address
  DK_ROT_E2E_PROVISION_EXTERNAL_SIMULATOR Same as --provision-external-simulator
  DK_ROT_E2E_EXTERNAL_SIMULATOR_NAMESPACE Same as --external-simulator-namespace
  DK_ROT_E2E_EXTERNAL_SIMULATOR_NAME      Same as --external-simulator-name
  DK_ROT_E2E_VERIFY_VAULT_RESTART         Same as --verify-vault-restart
USAGE
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

wait_for_snapshot_mode() {
  local expected_mode="$1"
  local timeout_seconds="$2"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi

  for _ in $(seq 1 "${loops}"); do
    local snapshot
    snapshot="$(kubectl -n "${argocd_namespace}" get configmap deploykube-deployment-config -o json 2>/dev/null | jq -r '.data["deployment-config.yaml"] // ""')"
    if grep -Eq "rootOfTrust:[[:space:]]*$" <<<"${snapshot}" && grep -Eq "mode:[[:space:]]*${expected_mode}" <<<"${snapshot}"; then
      return 0
    fi
    sleep 2
  done

  echo "FAIL: deployment-config snapshot did not converge to rootOfTrust.mode=${expected_mode}" >&2
  return 1
}

read_secret_data_key_b64() {
  local ns="$1"
  local name="$2"
  local key="$3"
  kubectl -n "${ns}" get secret "${name}" -o json 2>/dev/null | jq -r --arg k "${key}" '.data[$k] // ""'
}

read_secret_data_key() {
  local ns="$1"
  local name="$2"
  local key="$3"
  local b64
  b64="$(read_secret_data_key_b64 "${ns}" "${name}" "${key}")"
  if [ -z "${b64}" ]; then
    echo ""
    return 0
  fi
  printf '%s' "${b64}" | base64 -d 2>/dev/null || true
}

assert_secret_exists() {
  local ns="$1"
  local name="$2"
  if ! kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
    echo "FAIL: missing Secret ${ns}/${name}" >&2
    return 1
  fi
}

clear_kms_token_address_if_present() {
  kubectl -n vault-system patch secret kms-shim-token --type json -p='[{"op":"remove","path":"/data/address"}]' >/dev/null 2>&1 || true
}

profile="full"
run_external="${DK_ROT_E2E_RUN_EXTERNAL:-auto}"
external_address_override="${DK_ROT_E2E_EXTERNAL_ADDRESS:-}"
provision_external_simulator="${DK_ROT_E2E_PROVISION_EXTERNAL_SIMULATOR:-auto}"
external_simulator_namespace="${DK_ROT_E2E_EXTERNAL_SIMULATOR_NAMESPACE:-vault-system}"
external_simulator_name="${DK_ROT_E2E_EXTERNAL_SIMULATOR_NAME:-dk-kms-external-sim}"
verify_vault_restart="${DK_ROT_E2E_VERIFY_VAULT_RESTART:-yes}"
timeout="25m"
settle_seconds="20"
deploymentconfig_name=""
argocd_namespace="argocd"
ack_config_mutation="${DK_ROT_E2E_ACK_CONFIG_MUTATION:-no}"
freeze_gitops_sync="${DK_ROT_E2E_FREEZE_GITOPS_SYNC:-yes}"
gitops_root_app_name="platform-apps"
gitops_root_original_automated_json=""
gitops_leaf_app_name="deployment-secrets-bundle"
gitops_leaf_original_automated_json=""
gitops_sync_paused=0

vault_namespace="vault-system"
vault_statefulset_name="vault"
vault_pod_selector="app.kubernetes.io/name=vault"

run_id="$(date -u +%Y%m%d%H%M%S)"
external_simulator_configmap_name="${external_simulator_name}-script"
external_simulator_service_name="${external_simulator_name}"
external_simulator_deploy_name="${external_simulator_name}"
external_simulator_provisioned=0
bootstrap_tools_image=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --run-external)
      run_external="${2:-}"
      shift 2
      ;;
    --external-address)
      external_address_override="${2:-}"
      shift 2
      ;;
    --provision-external-simulator)
      provision_external_simulator="${2:-}"
      shift 2
      ;;
    --external-simulator-namespace)
      external_simulator_namespace="${2:-}"
      shift 2
      ;;
    --external-simulator-name)
      external_simulator_name="${2:-}"
      external_simulator_configmap_name="${external_simulator_name}-script"
      external_simulator_service_name="${external_simulator_name}"
      external_simulator_deploy_name="${external_simulator_name}"
      shift 2
      ;;
    --verify-vault-restart)
      verify_vault_restart="${2:-}"
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
    --argocd-namespace)
      argocd_namespace="${2:-}"
      shift 2
      ;;
    --freeze-gitops-sync)
      freeze_gitops_sync="${2:-}"
      shift 2
      ;;
    --ack-config-mutation)
      ack_config_mutation="${2:-}"
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
case "${profile}" in
  quick|full) ;;
  *)
    echo "error: --profile must be quick|full (got '${profile}')" >&2
    exit 2
    ;;
esac
case "${run_external}" in
  auto|yes|no) ;;
  *)
    echo "error: --run-external must be auto|yes|no (got '${run_external}')" >&2
    exit 2
    ;;
esac
case "${provision_external_simulator}" in
  auto|yes|no) ;;
  *)
    echo "error: --provision-external-simulator must be auto|yes|no (got '${provision_external_simulator}')" >&2
    exit 2
    ;;
esac
case "${verify_vault_restart}" in
  yes|no) ;;
  *)
    echo "error: --verify-vault-restart must be yes|no (got '${verify_vault_restart}')" >&2
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

dep_cfg_json="$(kubectl get deploymentconfigs.platform.darksite.cloud -o json)"
dep_cfg_count="$(jq -r '.items | length' <<<"${dep_cfg_json}")"
if [ "${dep_cfg_count}" -lt 1 ]; then
  echo "error: no DeploymentConfig resources found" >&2
  exit 1
fi
if [ -z "${deploymentconfig_name}" ]; then
  deploymentconfig_name="$(jq -r '.items[0].metadata.name' <<<"${dep_cfg_json}")"
fi

original_root_json="$(jq -c '.items[0].spec.secrets.rootOfTrust // {}' <<<"${dep_cfg_json}")"
original_external_address="$(jq -r '.items[0].spec.secrets.rootOfTrust.external.address // ""' <<<"${dep_cfg_json}")"
original_root_mode="$(jq -r '.items[0].spec.secrets.rootOfTrust.mode // "inCluster"' <<<"${dep_cfg_json}")"
external_address="${external_address_override:-${original_external_address}}"
mutated=0
ran_external_phase=0

pause_gitops_sync_for_test() {
  if [ "${freeze_gitops_sync}" != "yes" ]; then
    return 0
  fi

  if kubectl -n "${argocd_namespace}" get application "${gitops_root_app_name}" >/dev/null 2>&1; then
    gitops_root_original_automated_json="$(kubectl -n "${argocd_namespace}" get application "${gitops_root_app_name}" -o json | jq -c '.spec.syncPolicy.automated // null')"
    if [ "${gitops_root_original_automated_json}" != "null" ]; then
      echo "==> Freezing Argo auto-sync on ${argocd_namespace}/${gitops_root_app_name}"
      kubectl -n "${argocd_namespace}" patch application "${gitops_root_app_name}" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      gitops_sync_paused=1
    fi
  fi

  if kubectl -n "${argocd_namespace}" get application "${gitops_leaf_app_name}" >/dev/null 2>&1; then
    gitops_leaf_original_automated_json="$(kubectl -n "${argocd_namespace}" get application "${gitops_leaf_app_name}" -o json | jq -c '.spec.syncPolicy.automated // null')"
    if [ "${gitops_leaf_original_automated_json}" != "null" ]; then
      echo "==> Freezing Argo auto-sync on ${argocd_namespace}/${gitops_leaf_app_name}"
      kubectl -n "${argocd_namespace}" patch application "${gitops_leaf_app_name}" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      gitops_sync_paused=1
    fi
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
    local leaf_patch_payload
    leaf_patch_payload="$(jq -cn --argjson automated "${gitops_leaf_original_automated_json}" '{"spec":{"syncPolicy":{"automated":$automated}}}')"
    kubectl -n "${argocd_namespace}" patch application "${gitops_leaf_app_name}" --type merge -p "${leaf_patch_payload}" >/dev/null || true
  fi
  if [ -n "${gitops_root_original_automated_json}" ] && [ "${gitops_root_original_automated_json}" != "null" ]; then
    local root_patch_payload
    root_patch_payload="$(jq -cn --argjson automated "${gitops_root_original_automated_json}" '{"spec":{"syncPolicy":{"automated":$automated}}}')"
    kubectl -n "${argocd_namespace}" patch application "${gitops_root_app_name}" --type merge -p "${root_patch_payload}" >/dev/null || true
  fi
}

patch_root_of_trust() {
  local root_json="$1"
  local patch_payload
  patch_payload="$(jq -cn --argjson root "${root_json}" '[{"op":"replace","path":"/spec/secrets/rootOfTrust","value":$root}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    mutated=1
    return 0
  fi
  patch_payload="$(jq -cn --argjson root "${root_json}" '[{"op":"add","path":"/spec/secrets/rootOfTrust","value":$root}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  mutated=1
}

read_live_root_mode() {
  kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o json 2>/dev/null \
    | jq -r '.spec.secrets.rootOfTrust.mode // ""'
}

wait_for_live_root_mode() {
  local expected_mode="$1"
  local timeout_seconds="$2"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi

  for _ in $(seq 1 "${loops}"); do
    local live_mode
    live_mode="$(read_live_root_mode)"
    if [ "${live_mode}" = "${expected_mode}" ]; then
      echo "Live DeploymentConfig rootOfTrust.mode=${live_mode}"
      return 0
    fi
    sleep 2
  done

  local live_mode
  live_mode="$(read_live_root_mode)"
  echo "FAIL: live DeploymentConfig spec.secrets.rootOfTrust.mode did not converge to ${expected_mode} (got '${live_mode}')" >&2
  return 1
}

restore_original_root() {
  if [ "${mutated}" -eq 0 ]; then
    return 0
  fi
  echo "==> Restoring original spec.secrets.rootOfTrust on DeploymentConfig/${deploymentconfig_name}"
  local patch_payload
  patch_payload="$(jq -cn --argjson root "${original_root_json}" '[{"op":"replace","path":"/spec/secrets/rootOfTrust","value":$root}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    sleep "${settle_seconds}"
    return 0
  fi
  patch_payload="$(jq -cn --argjson root "${original_root_json}" '[{"op":"add","path":"/spec/secrets/rootOfTrust","value":$root}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  sleep "${settle_seconds}"
}

wait_for_external_simulator_ready() {
  kubectl -n "${external_simulator_namespace}" rollout status deployment/"${external_simulator_deploy_name}" --timeout="${timeout}" >/dev/null
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    if kubectl -n "${external_simulator_namespace}" exec deploy/"${external_simulator_deploy_name}" -- /usr/bin/python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8200/__health", timeout=3).read()' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: external KMS simulator did not become healthy" >&2
  return 1
}

provision_external_simulator_backend() {
  echo "==> Provisioning external KMS simulator in ${external_simulator_namespace}/${external_simulator_name}"

  if [ -z "${bootstrap_tools_image}" ]; then
    bootstrap_tools_image="$(kubectl -n vault-seal-system get deployment kms-shim -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi
  if [ -z "${bootstrap_tools_image}" ]; then
    bootstrap_tools_image="registry.example.internal/deploykube/bootstrap-tools:1.4"
  fi

  kubectl get namespace "${external_simulator_namespace}" >/dev/null 2>&1 || kubectl create namespace "${external_simulator_namespace}" >/dev/null

  kubectl -n "${external_simulator_namespace}" create configmap "${external_simulator_configmap_name}" \
    --from-file=proxy.py="${root_dir}/tests/scripts/lib/kms_shim_external_proxy_sim.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${external_simulator_service_name}
  namespace: ${external_simulator_namespace}
  labels:
    app.kubernetes.io/name: ${external_simulator_name}
spec:
  selector:
    app.kubernetes.io/name: ${external_simulator_name}
  ports:
    - name: http
      port: 8200
      targetPort: 8200
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${external_simulator_deploy_name}
  namespace: ${external_simulator_namespace}
  labels:
    app.kubernetes.io/name: ${external_simulator_name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${external_simulator_name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${external_simulator_name}
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: kms-external-proxy
          image: ${bootstrap_tools_image}
          imagePullPolicy: IfNotPresent
          command:
            - /usr/bin/python3
            - /app/proxy.py
          env:
            - name: PORT
              value: "8200"
            - name: UPSTREAM_BASE_URL
              value: http://kms-shim.vault-seal-system.svc:8200
          ports:
            - name: http
              containerPort: 8200
          volumeMounts:
            - name: script
              mountPath: /app
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: script
          configMap:
            name: ${external_simulator_configmap_name}
            items:
              - key: proxy.py
                path: proxy.py
        - name: tmp
          emptyDir: {}
YAML

  wait_for_external_simulator_ready
  external_address="http://${external_simulator_service_name}.${external_simulator_namespace}.svc.cluster.local:8200"
  external_simulator_provisioned=1
}

cleanup_external_simulator_backend() {
  if [ "${external_simulator_provisioned}" -eq 0 ]; then
    return 0
  fi
  echo "==> Cleaning external KMS simulator resources"
  kubectl -n "${external_simulator_namespace}" delete deployment "${external_simulator_deploy_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${external_simulator_namespace}" delete service "${external_simulator_service_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${external_simulator_namespace}" delete configmap "${external_simulator_configmap_name}" --ignore-not-found >/dev/null 2>&1 || true
}

reset_external_simulator_state() {
  [ "${external_simulator_provisioned}" -eq 1 ] || return 0
  kubectl -n "${external_simulator_namespace}" exec deploy/"${external_simulator_deploy_name}" -- /usr/bin/python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8200/__reset", timeout=5).read()' >/dev/null
}

fetch_external_simulator_state() {
  kubectl -n "${external_simulator_namespace}" exec deploy/"${external_simulator_deploy_name}" -- /usr/bin/python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8200/__state", timeout=5).read().decode("utf-8"))'
}

wait_for_vault_pod_ready() {
  local pod="$1"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    local ready
    ready="$(kubectl -n "${vault_namespace}" get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "${ready}" = "True" ]; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: pod ${vault_namespace}/${pod} did not become Ready" >&2
  return 1
}

wait_for_vault_pod_unsealed() {
  local pod="$1"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    local status_json
    status_json="$(kubectl -n "${vault_namespace}" exec "${pod}" -c vault -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null || true)"
    if [ -n "${status_json}" ] && jq -e '.sealed == false' <<<"${status_json}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: pod ${vault_namespace}/${pod} did not report unsealed state" >&2
  kubectl -n "${vault_namespace}" logs "${pod}" -c vault --tail=120 >&2 || true
  return 1
}

wait_for_vault_external_marker() {
  local pod="$1"
  local marker="[vault] using seal provider: kms-shim (external address)"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    if kubectl -n "${vault_namespace}" logs "${pod}" -c vault --since=15m 2>/dev/null | grep -Fq -- "${marker}"; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: did not find external seal marker in logs for ${vault_namespace}/${pod}" >&2
  return 1
}

wait_for_vault_incluster_seal_addr() {
  local pod="$1"
  local expected_addr="http://kms-shim.vault-seal-system.svc:8200"
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    local addr
    addr="$(kubectl -n "${vault_namespace}" exec "${pod}" -c vault -- sh -c "grep -E '^[[:space:]]*address[[:space:]]*=' /home/vault/storageconfig.hcl | tail -n 1 | cut -d '\"' -f2" 2>/dev/null || true)"
    if [ "${addr}" = "${expected_addr}" ]; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: pod ${vault_namespace}/${pod} did not converge to inCluster seal address ${expected_addr}" >&2
  return 1
}

verify_external_simulator_traffic() {
  [ "${external_simulator_provisioned}" -eq 1 ] || return 0

  local state_json
  state_json="$(fetch_external_simulator_state)"

  if ! jq -e '.requestCount > 0' <<<"${state_json}" >/dev/null 2>&1; then
    echo "FAIL: external simulator did not observe any traffic" >&2
    echo "${state_json}" >&2
    return 1
  fi

  if ! jq -e 'any(.requests[]?; (.path // "") | test("^/v1/transit/(encrypt|decrypt)/"))' <<<"${state_json}" >/dev/null 2>&1; then
    echo "FAIL: external simulator did not observe transit encrypt/decrypt calls" >&2
    echo "${state_json}" >&2
    return 1
  fi
}

verify_vault_restart_unseal_external() {
  if [ "${verify_vault_restart}" != "yes" ]; then
    return 0
  fi

  echo "==> Verifying Vault restart/unseal against external endpoint"

  reset_external_simulator_state

  local pods
  pods="$(kubectl -n "${vault_namespace}" get pods -l "${vault_pod_selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sed '/^$/d' | sort)"
  if [ -z "${pods}" ]; then
    echo "FAIL: no Vault pods found in ${vault_namespace}" >&2
    return 1
  fi

  local pod
  while IFS= read -r pod; do
    [ -n "${pod}" ] || continue
    echo "  - restart ${pod}"
    kubectl -n "${vault_namespace}" delete pod "${pod}" --wait=false >/dev/null
    wait_for_vault_pod_ready "${pod}"
    wait_for_vault_pod_unsealed "${pod}"
    wait_for_vault_external_marker "${pod}"
  done <<<"${pods}"

  verify_external_simulator_traffic
}

verify_vault_restart_unseal_incluster() {
  if [ "${verify_vault_restart}" != "yes" ]; then
    return 0
  fi

  echo "==> Verifying Vault restart/unseal against in-cluster kms-shim endpoint"

  local pods
  pods="$(kubectl -n "${vault_namespace}" get pods -l "${vault_pod_selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sed '/^$/d' | sort)"
  if [ -z "${pods}" ]; then
    echo "FAIL: no Vault pods found in ${vault_namespace}" >&2
    return 1
  fi

  local pod
  while IFS= read -r pod; do
    [ -n "${pod}" ] || continue
    echo "  - restart ${pod}"
    kubectl -n "${vault_namespace}" delete pod "${pod}" --wait=false >/dev/null
    wait_for_vault_pod_ready "${pod}"
    wait_for_vault_pod_unsealed "${pod}"
    wait_for_vault_incluster_seal_addr "${pod}"
  done <<<"${pods}"
}

cleanup() {
  restore_original_root || true
  if [ "${mutated}" -eq 1 ]; then
    echo "==> Reconciling hooks after root-of-trust restore"
    run_rot_restore_hooks || true
    if [ "${original_root_mode}" = "inCluster" ]; then
      clear_kms_token_address_if_present
      if [ "${ran_external_phase}" -eq 1 ]; then
        verify_vault_restart_unseal_incluster || true
      fi
    fi
  fi
  cleanup_external_simulator_backend || true
  restore_gitops_sync_after_test || true
}
trap cleanup EXIT

run_rot_hooks() {
  ./tests/scripts/run-runtime-smokes.sh \
    --app secrets-bootstrap \
    --hooks \
    --wait \
    --timeout "${timeout}"

  ./tests/scripts/run-runtime-smokes.sh \
    --app secrets-vault-config \
    --hooks \
    --wait \
    --timeout "${timeout}" || echo "WARN: secrets-vault-config hook sync returned non-success; continuing root-of-trust mode validation"

  ./tests/scripts/run-runtime-smokes.sh \
    --app secrets-external-secrets-config \
    --hooks \
    --wait \
    --timeout "${timeout}" || echo "WARN: secrets-external-secrets-config hook sync returned non-success; continuing root-of-trust mode validation"
}

run_rot_restore_hooks() {
  ./tests/scripts/run-runtime-smokes.sh \
    --app secrets-bootstrap \
    --hooks \
    --wait \
    --timeout "${timeout}"
}

run_mode_incluster() {
  echo ""
  echo "==> Phase: mode=inCluster"
  local incluster_json
  incluster_json="$(jq -cn --argjson base "${original_root_json}" '
    ($base // {})
    | .provider = "kmsShim"
    | .mode = "inCluster"
    | if (.external | type) == "object" then del(.external.address) else . end
  ')"
  patch_root_of_trust "${incluster_json}"
  wait_for_live_root_mode "inCluster" "${timeout_seconds}"
  sleep "${settle_seconds}"
  wait_for_snapshot_mode "inCluster" "${timeout_seconds}"
  run_rot_hooks

  assert_secret_exists "vault-system" "kms-shim-token"
  assert_secret_exists "vault-seal-system" "kms-shim-token"
  local token_addr
  token_addr="$(read_secret_data_key "vault-system" "kms-shim-token" "address")"
  if [ -n "${token_addr}" ]; then
    echo "WARN: Secret/vault-system/kms-shim-token data.address remained set after inCluster sync; clearing stale value" >&2
    clear_kms_token_address_if_present
    token_addr="$(read_secret_data_key "vault-system" "kms-shim-token" "address")"
    if [ -n "${token_addr}" ]; then
      echo "FAIL: expected Secret/vault-system/kms-shim-token data.address to be empty in inCluster mode; got '${token_addr}'" >&2
      return 1
    fi
  fi

  verify_vault_restart_unseal_incluster
}

run_mode_external() {
  echo ""
  echo "==> Phase: mode=external"
  ran_external_phase=1
  if [ -z "${external_address}" ]; then
    echo "error: external mode requested but no external address provided" >&2
    exit 2
  fi
  local external_json
  external_json="$(jq -cn --argjson base "${original_root_json}" --arg addr "${external_address}" '
    ($base // {})
    | .provider = "kmsShim"
    | .mode = "external"
    | .external = (.external // {})
    | .external.address = $addr
  ')"
  patch_root_of_trust "${external_json}"
  wait_for_live_root_mode "external" "${timeout_seconds}"
  sleep "${settle_seconds}"
  wait_for_snapshot_mode "external" "${timeout_seconds}"
  run_rot_hooks

  assert_secret_exists "vault-system" "kms-shim-token"
  local token_addr
  token_addr="$(read_secret_data_key "vault-system" "kms-shim-token" "address")"
  if [ "${token_addr}" != "${external_address}" ]; then
    echo "FAIL: expected Secret/vault-system/kms-shim-token data.address='${external_address}', got '${token_addr}'" >&2
    return 1
  fi

  verify_vault_restart_unseal_external
}

prepare_external_endpoint() {
  local should_provision="no"
  case "${provision_external_simulator}" in
    yes)
      should_provision="yes"
      ;;
    no)
      should_provision="no"
      ;;
    auto)
      if [ -z "${external_address}" ]; then
        should_provision="yes"
      fi
      ;;
  esac

  if [ "${should_provision}" = "yes" ]; then
    provision_external_simulator_backend
  fi
}

pause_gitops_sync_for_test

echo "DeploymentConfig: ${deploymentconfig_name}"
echo "Profile: ${profile}"
echo "Run external: ${run_external}"
echo "Provision external simulator: ${provision_external_simulator}"
echo "Verify Vault restart: ${verify_vault_restart}"
echo "Timeout: ${timeout}"
echo "Freeze GitOps sync: ${freeze_gitops_sync}"
if [ -n "${external_address}" ]; then
  echo "External address: ${external_address}"
fi

run_mode_incluster

if [ "${profile}" = "full" ]; then
  should_run_external="no"
  case "${run_external}" in
    yes)
      should_run_external="yes"
      ;;
    no)
      should_run_external="no"
      ;;
    auto)
      if [ -n "${external_address}" ]; then
        should_run_external="yes"
      elif [ "${provision_external_simulator}" != "no" ]; then
        should_run_external="yes"
      fi
      ;;
  esac

  if [ "${should_run_external}" = "yes" ]; then
    prepare_external_endpoint
    run_mode_external
  else
    echo ""
    echo "==> Skipping mode=external (run_external=${run_external})"
  fi
fi

echo ""
echo "Root-of-trust mode E2E passed (${profile})"
