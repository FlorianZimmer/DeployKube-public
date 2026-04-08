#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'USAGE'
Usage: ./tests/scripts/e2e-dns-delegation-modes-matrix.sh [options]

Goal:
  Run live DNS delegation mode E2E by mutating singleton DeploymentConfig.spec.dns.delegation,
  then validating controller outputs and dns-external-sync hook behavior.

Profiles:
  quick  - mode=none + mode=manual
  full   - quick profile plus optional mode=auto

Important:
  - This script mutates DeploymentConfig.spec.dns.delegation and restores it on exit.
  - You MUST acknowledge mutation explicitly:
      --ack-config-mutation yes
    or:
      DK_DNS_E2E_ACK_CONFIG_MUTATION=yes

Options:
  --profile <quick|full>         Validation profile (default: full)
  --run-auto <auto|yes|no>       Include auto mode in full profile (default: auto)
  --timeout <duration>           Per-phase timeout (default: 20m)
  --settle-seconds <n>           Sleep after each config patch (default: 20)
  --deploymentconfig <name>      Target DeploymentConfig name (auto-detected when omitted)
  --dns-namespace <ns>           Namespace for DNS config maps (default: dns-system)
  --argocd-namespace <ns>        Namespace for Argo CD resources (default: argocd)
  --tenant-controller-namespace <ns>
                                 Namespace for tenant networking controller (default: tenant-system)
  --tenant-controller-deployment <name>
                                 Deployment name for tenant networking controller (default: tenant-networking-controller)
  --parent-zone <zone>           Override parent zone for manual/auto phases
  --writer-secret-name <name>    Override writerRef.name used for auto mode
  --writer-secret-namespace <ns> Override writerRef.namespace used for auto mode
  --provision-writer-simulator <auto|yes|no>
                                 Provision ephemeral in-cluster PowerDNS-like writer for auto mode (default: auto)
  --writer-simulator-namespace <ns>
                                 Namespace for writer simulator resources (default: dns-system)
  --writer-simulator-name <name>
                                 Base name for writer simulator resources (default: dk-dns-writer-sim)
  --freeze-gitops-sync <yes|no>  Temporarily disable Argo auto-sync for deployment-secrets-bundle during test (default: yes)
  --ack-config-mutation <yes|no> Explicitly allow DeploymentConfig mutation (required)
  --help                         Show this help

Environment knobs (optional):
  DK_DNS_E2E_ACK_CONFIG_MUTATION       Same as --ack-config-mutation
  DK_DNS_E2E_RUN_AUTO                  Same as --run-auto
  DK_DNS_E2E_PARENT_ZONE               Same as --parent-zone
  DK_DNS_E2E_WRITER_SECRET_NAME        Same as --writer-secret-name
  DK_DNS_E2E_WRITER_SECRET_NAMESPACE   Same as --writer-secret-namespace
  DK_DNS_E2E_PROVISION_WRITER_SIMULATOR Same as --provision-writer-simulator
  DK_DNS_E2E_WRITER_SIMULATOR_NAMESPACE Same as --writer-simulator-namespace
  DK_DNS_E2E_WRITER_SIMULATOR_NAME      Same as --writer-simulator-name
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

to_fqdn() {
  local raw="$1"
  raw="${raw%.}"
  echo "${raw}."
}

is_same_or_child_of_domain() {
  local child="${1%.}"
  local parent="${2%.}"
  [[ -n "${child}" && -n "${parent}" ]] || return 1
  if [ "${child}" = "${parent}" ]; then
    return 0
  fi
  [[ "${child}" == *."${parent}" ]]
}

wait_for_jsonpath_equals() {
  local cmd="$1"
  local expected="$2"
  local timeout_seconds="$3"
  local label="$4"

  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    local actual
    actual="$(eval "${cmd}" 2>/dev/null || true)"
    if [ "${actual}" = "${expected}" ]; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: timeout waiting for ${label}='${expected}'" >&2
  return 1
}

wait_for_controller_log() {
  local expected="$1"
  local timeout_seconds="$2"

  local loops=$((timeout_seconds / 5))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    local logs
    logs="$(kubectl -n "${tenant_controller_namespace}" --request-timeout=10s logs deployment/"${tenant_controller_deployment}" --since=10m 2>/dev/null || true)"
    if grep -Fq -- "${expected}" <<<"${logs}"; then
      return 0
    fi
    sleep 5
  done
  echo "FAIL: did not observe controller log marker '${expected}'" >&2
  return 1
}

profile="full"
run_auto="${DK_DNS_E2E_RUN_AUTO:-auto}"
timeout="20m"
settle_seconds="20"
deploymentconfig_name=""
dns_namespace="dns-system"
argocd_namespace="argocd"
tenant_controller_namespace="tenant-system"
tenant_controller_deployment="tenant-networking-controller"
parent_zone_override="${DK_DNS_E2E_PARENT_ZONE:-}"
writer_secret_name_override="${DK_DNS_E2E_WRITER_SECRET_NAME:-}"
writer_secret_namespace_override="${DK_DNS_E2E_WRITER_SECRET_NAMESPACE:-}"
provision_writer_simulator="${DK_DNS_E2E_PROVISION_WRITER_SIMULATOR:-auto}"
writer_simulator_namespace="${DK_DNS_E2E_WRITER_SIMULATOR_NAMESPACE:-dns-system}"
writer_simulator_name="${DK_DNS_E2E_WRITER_SIMULATOR_NAME:-dk-dns-writer-sim}"
ack_config_mutation="${DK_DNS_E2E_ACK_CONFIG_MUTATION:-no}"
freeze_gitops_sync="${DK_DNS_E2E_FREEZE_GITOPS_SYNC:-yes}"
gitops_root_app_name="platform-apps"
gitops_root_original_automated_json=""
gitops_leaf_app_name="deployment-secrets-bundle"
gitops_leaf_original_automated_json=""
gitops_sync_paused=0
run_id="$(date -u +%Y%m%d%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --run-auto)
      run_auto="${2:-}"
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
    --dns-namespace)
      dns_namespace="${2:-}"
      shift 2
      ;;
    --argocd-namespace)
      argocd_namespace="${2:-}"
      shift 2
      ;;
    --tenant-controller-namespace)
      tenant_controller_namespace="${2:-}"
      shift 2
      ;;
    --tenant-controller-deployment)
      tenant_controller_deployment="${2:-}"
      shift 2
      ;;
    --parent-zone)
      parent_zone_override="${2:-}"
      shift 2
      ;;
    --writer-secret-name)
      writer_secret_name_override="${2:-}"
      shift 2
      ;;
    --writer-secret-namespace)
      writer_secret_namespace_override="${2:-}"
      shift 2
      ;;
    --provision-writer-simulator)
      provision_writer_simulator="${2:-}"
      shift 2
      ;;
    --writer-simulator-namespace)
      writer_simulator_namespace="${2:-}"
      shift 2
      ;;
    --writer-simulator-name)
      writer_simulator_name="${2:-}"
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
case "${run_auto}" in
  auto|yes|no) ;;
  *)
    echo "error: --run-auto must be auto|yes|no (got '${run_auto}')" >&2
    exit 2
    ;;
esac
case "${provision_writer_simulator}" in
  auto|yes|no) ;;
  *)
    echo "error: --provision-writer-simulator must be auto|yes|no (got '${provision_writer_simulator}')" >&2
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

original_delegation_json="$(jq -c '.items[0].spec.dns.delegation // {}' <<<"${dep_cfg_json}")"
original_parent_zone="$(jq -r '.items[0].spec.dns.delegation.parentZone // ""' <<<"${dep_cfg_json}")"
original_writer_name="$(jq -r '.items[0].spec.dns.delegation.writerRef.name // ""' <<<"${dep_cfg_json}")"
original_writer_namespace="$(jq -r '.items[0].spec.dns.delegation.writerRef.namespace // ""' <<<"${dep_cfg_json}")"

parent_zone="${parent_zone_override:-${original_parent_zone}}"
writer_secret_name="${writer_secret_name_override:-${original_writer_name}}"
writer_secret_namespace="${writer_secret_namespace_override:-${original_writer_namespace}}"

mutated=0
writer_simulator_provisioned=0
writer_simulator_configmap_name="${writer_simulator_name}-script"
writer_simulator_service_name="${writer_simulator_name}"
writer_simulator_deploy_name="${writer_simulator_name}"
writer_simulator_secret_name="${writer_simulator_name}-writer"
writer_simulator_api_key="dk-dns-writer-sim-${run_id}"
bootstrap_tools_image=""

auto_expected_base_fqdn=""
auto_expected_ns_ip=""
auto_expected_ns_sorted=""
auto_expected_glue_hosts=()

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

patch_delegation() {
  local delegation_json="$1"
  local patch_payload
  patch_payload="$(jq -cn --argjson delegation "${delegation_json}" '[{"op":"replace","path":"/spec/dns/delegation","value":$delegation}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    mutated=1
    return 0
  fi
  patch_payload="$(jq -cn --argjson delegation "${delegation_json}" '[{"op":"add","path":"/spec/dns/delegation","value":$delegation}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  mutated=1
}

restore_original_delegation() {
  if [ "${mutated}" -eq 0 ]; then
    return 0
  fi
  echo "==> Restoring original spec.dns.delegation on DeploymentConfig/${deploymentconfig_name}"
  local patch_payload
  patch_payload="$(jq -cn --argjson delegation "${original_delegation_json}" '[{"op":"replace","path":"/spec/dns/delegation","value":$delegation}]')"
  if kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null; then
    sleep "${settle_seconds}"
    return 0
  fi
  patch_payload="$(jq -cn --argjson delegation "${original_delegation_json}" '[{"op":"add","path":"/spec/dns/delegation","value":$delegation}]')"
  kubectl patch deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" --type json -p "${patch_payload}" >/dev/null
  sleep "${settle_seconds}"
}

wait_for_writer_simulator_ready() {
  kubectl -n "${writer_simulator_namespace}" --request-timeout=10s rollout status deployment/"${writer_simulator_deploy_name}" --timeout="${timeout}" >/dev/null
  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi
  for _ in $(seq 1 "${loops}"); do
    if kubectl -n "${writer_simulator_namespace}" --request-timeout=10s exec deploy/"${writer_simulator_deploy_name}" -- /usr/bin/python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8081/__health", timeout=3).read()' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: writer simulator did not become healthy" >&2
  return 1
}

provision_writer_simulator_backend() {
  echo "==> Provisioning DNS writer simulator in ${writer_simulator_namespace}/${writer_simulator_name}"

  if [ -z "${bootstrap_tools_image}" ]; then
    bootstrap_tools_image="$(kubectl -n "${dns_namespace}" get cronjob dns-external-sync-periodic -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi
  if [ -z "${bootstrap_tools_image}" ]; then
    bootstrap_tools_image="registry.example.internal/deploykube/bootstrap-tools:1.4"
  fi

  kubectl get namespace "${writer_simulator_namespace}" >/dev/null 2>&1 || kubectl create namespace "${writer_simulator_namespace}" >/dev/null

  kubectl -n "${writer_simulator_namespace}" create configmap "${writer_simulator_configmap_name}" \
    --from-file=server.py="${root_dir}/tests/scripts/lib/dns_delegation_writer_sim.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${writer_simulator_service_name}
  namespace: ${writer_simulator_namespace}
  labels:
    app.kubernetes.io/name: ${writer_simulator_name}
spec:
  selector:
    app.kubernetes.io/name: ${writer_simulator_name}
  ports:
    - name: http
      port: 8081
      targetPort: 8081
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${writer_simulator_deploy_name}
  namespace: ${writer_simulator_namespace}
  labels:
    app.kubernetes.io/name: ${writer_simulator_name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${writer_simulator_name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${writer_simulator_name}
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: writer-sim
          image: ${bootstrap_tools_image}
          imagePullPolicy: IfNotPresent
          command:
            - /usr/bin/python3
            - /app/server.py
          env:
            - name: PORT
              value: "8081"
            - name: SIM_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ${writer_simulator_secret_name}
                  key: apiKey
          ports:
            - name: http
              containerPort: 8081
          volumeMounts:
            - name: script
              mountPath: /app
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: script
          configMap:
            name: ${writer_simulator_configmap_name}
            items:
              - key: server.py
                path: server.py
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${writer_simulator_secret_name}
  namespace: ${writer_simulator_namespace}
type: Opaque
stringData:
  provider: powerdns
  apiUrl: http://${writer_simulator_service_name}.${writer_simulator_namespace}.svc.cluster.local:8081/api/v1
  apiKey: ${writer_simulator_api_key}
  serverId: local
YAML

  wait_for_writer_simulator_ready

  writer_secret_name="${writer_simulator_secret_name}"
  writer_secret_namespace="${writer_simulator_namespace}"
  writer_simulator_provisioned=1
}

cleanup_writer_simulator_backend() {
  if [ "${writer_simulator_provisioned}" -eq 0 ]; then
    return 0
  fi
  echo "==> Cleaning DNS writer simulator resources"
  kubectl -n "${writer_simulator_namespace}" delete deployment "${writer_simulator_deploy_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${writer_simulator_namespace}" delete service "${writer_simulator_service_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${writer_simulator_namespace}" delete secret "${writer_simulator_secret_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${writer_simulator_namespace}" delete configmap "${writer_simulator_configmap_name}" --ignore-not-found >/dev/null 2>&1 || true
}

reset_writer_simulator_state() {
  [ "${writer_simulator_provisioned}" -eq 1 ] || return 0
  kubectl -n "${writer_simulator_namespace}" --request-timeout=10s exec deploy/"${writer_simulator_deploy_name}" -- /usr/bin/python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8081/__reset", timeout=5).read()' >/dev/null
}

fetch_writer_simulator_state() {
  kubectl -n "${writer_simulator_namespace}" --request-timeout=10s exec deploy/"${writer_simulator_deploy_name}" -- /usr/bin/python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8081/__state", timeout=5).read().decode("utf-8"))'
}

prepare_auto_expected_records() {
  local wiring_json
  wiring_json="$(kubectl -n "${dns_namespace}" --request-timeout=10s get configmap deploykube-dns-wiring -o json)"

  local base_domain
  base_domain="$(jq -r '.data.DNS_DOMAIN // ""' <<<"${wiring_json}")"
  auto_expected_base_fqdn="$(to_fqdn "${base_domain}")"
  auto_expected_ns_ip="$(jq -r '.data.DNS_AUTH_NS_IP // ""' <<<"${wiring_json}")"
  local ns_hosts_raw
  ns_hosts_raw="$(jq -r '.data.DNS_AUTH_NS_HOSTS // ""' <<<"${wiring_json}")"

  if [ -z "${auto_expected_base_fqdn}" ] || [ -z "${auto_expected_ns_ip}" ] || [ -z "${ns_hosts_raw}" ]; then
    echo "FAIL: missing DNS wiring data required for auto mode assertions" >&2
    return 1
  fi

  auto_expected_glue_hosts=()
  local ns_lines=""
  local ns_host
  for ns_host in ${ns_hosts_raw}; do
    local fqdn
    fqdn="$(to_fqdn "${ns_host}")"
    ns_lines+="${fqdn}"$'\n'
    if is_same_or_child_of_domain "${ns_host}" "${parent_zone}"; then
      auto_expected_glue_hosts+=("${fqdn}")
    fi
  done
  auto_expected_ns_sorted="$(printf '%s' "${ns_lines}" | sed '/^$/d' | sort -u)"
}

request_matches_expected_rrsets() {
  local req_json="$1"

  local zone
  zone="$(jq -r '.zone // ""' <<<"${req_json}")"
  if [ -z "${zone}" ]; then
    return 1
  fi

  local parent_trimmed parent_fqdn
  parent_trimmed="${parent_zone%.}"
  parent_fqdn="${parent_trimmed}."
  if [ "${zone}" != "${parent_trimmed}" ] && [ "${zone}" != "${parent_fqdn}" ]; then
    return 1
  fi

  local ns_actual
  ns_actual="$(jq -r --arg base "${auto_expected_base_fqdn}" '.rrsets[]? | select(.type=="NS" and .name==$base) | .records[]?.content' <<<"${req_json}" | sed '/^$/d' | sort -u)"
  if [ "${ns_actual}" != "${auto_expected_ns_sorted}" ]; then
    return 1
  fi

  local glue_host
  for glue_host in "${auto_expected_glue_hosts[@]}"; do
    local glue_ips
    glue_ips="$(jq -r --arg name "${glue_host}" '.rrsets[]? | select(.type=="A" and .name==$name) | .records[]?.content' <<<"${req_json}" | sed '/^$/d' | sort -u)"
    if ! grep -Fxq -- "${auto_expected_ns_ip}" <<<"${glue_ips}"; then
      return 1
    fi
  done

  return 0
}

assert_auto_rrsets_with_simulator() {
  [ "${writer_simulator_provisioned}" -eq 1 ] || return 0
  prepare_auto_expected_records

  local loops=$((timeout_seconds / 2))
  if [ "${loops}" -lt 1 ]; then
    loops=1
  fi

  for _ in $(seq 1 "${loops}"); do
    local state_json
    state_json="$(fetch_writer_simulator_state 2>/dev/null || true)"
    if [ -z "${state_json}" ]; then
      sleep 2
      continue
    fi

    local req
    while IFS= read -r req; do
      if request_matches_expected_rrsets "${req}"; then
        echo "  OK: simulator captured expected NS/glue rrsets"
        return 0
      fi
    done < <(jq -c '.requests[]?' <<<"${state_json}" 2>/dev/null || true)

    sleep 2
  done

  echo "FAIL: did not observe expected auto delegation rrsets in simulator state" >&2
  fetch_writer_simulator_state >&2 || true
  return 1
}

cleanup() {
  restore_original_delegation
  cleanup_writer_simulator_backend
  restore_gitops_sync_after_test
}
trap cleanup EXIT

run_dns_external_sync_hooks() {
  ./tests/scripts/run-runtime-smokes.sh \
    --app networking-dns-external-sync \
    --hooks \
    --wait \
    --timeout "${timeout}"
}

assert_legacy_delegation_configmap_absent() {
  if kubectl -n "${argocd_namespace}" get configmap deploykube-dns-delegation >/dev/null 2>&1; then
    echo "FAIL: expected legacy ${argocd_namespace}/ConfigMap/deploykube-dns-delegation to be absent" >&2
    kubectl -n "${argocd_namespace}" get configmap deploykube-dns-delegation -o yaml >&2 || true
    return 1
  fi
}

assert_delegation_status_mode() {
  local expected="$1"
  local actual
  actual="$(kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o json | jq -r '.status.dns.delegation.mode // ""')"
  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: expected DeploymentConfig/${deploymentconfig_name} status.dns.delegation.mode='${expected}', got '${actual}'" >&2
    kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o json | jq '.status.dns.delegation' >&2 || true
    return 1
  fi
}

assert_manual_status() {
  local dep_json status_mode status_parent status_base instructions_count
  dep_json="$(kubectl get deploymentconfigs.platform.darksite.cloud "${deploymentconfig_name}" -o json)"
  status_mode="$(jq -r '.status.dns.delegation.mode // ""' <<<"${dep_json}")"
  status_parent="$(jq -r '.status.dns.delegation.parentZone // ""' <<<"${dep_json}")"
  status_base="$(jq -r '.status.dns.delegation.baseDomain // ""' <<<"${dep_json}")"
  instructions_count="$(jq -r '(.status.dns.delegation.manualInstructions // []) | length' <<<"${dep_json}")"
  if [ "${status_mode}" != "manual" ]; then
    echo "FAIL: expected status.dns.delegation.mode=manual, got '${status_mode}'" >&2
    return 1
  fi
  if [ "${status_parent}" != "${parent_zone}" ]; then
    echo "FAIL: expected status.dns.delegation.parentZone='${parent_zone}', got '${status_parent}'" >&2
    return 1
  fi
  if [ -z "${status_base}" ]; then
    echo "FAIL: expected status.dns.delegation.baseDomain to be populated" >&2
    return 1
  fi
  if [ "${instructions_count}" -lt 1 ]; then
    echo "FAIL: expected status.dns.delegation.manualInstructions to be populated for manual mode" >&2
    return 1
  fi
}

run_mode_none() {
  echo ""
  echo "==> Phase: mode=none"
  patch_delegation '{"mode":"none"}'
  sleep "${settle_seconds}"
  wait_for_jsonpath_equals \
    "kubectl -n ${dns_namespace} --request-timeout=10s get configmap deploykube-dns-wiring -o jsonpath='{.data.DNS_DELEGATION_MODE}'" \
    "none" \
    "${timeout_seconds}" \
    "deploykube-dns-wiring.data.DNS_DELEGATION_MODE"
  wait_for_jsonpath_equals \
    "kubectl get deploymentconfigs.platform.darksite.cloud ${deploymentconfig_name} -o json | jq -r '.status.dns.delegation.mode // \"\"'" \
    "none" \
    "${timeout_seconds}" \
    "DeploymentConfig.status.dns.delegation.mode"
  assert_legacy_delegation_configmap_absent
  run_dns_external_sync_hooks
}

run_mode_manual() {
  echo ""
  echo "==> Phase: mode=manual"
  if [ -z "${parent_zone}" ]; then
    echo "error: parent zone is required for manual mode (use --parent-zone or DK_DNS_E2E_PARENT_ZONE)" >&2
    exit 2
  fi
  local manual_json
  manual_json="$(jq -cn --arg parent "${parent_zone}" '{mode:"manual",parentZone:$parent}')"
  patch_delegation "${manual_json}"
  sleep "${settle_seconds}"
  wait_for_jsonpath_equals \
    "kubectl -n ${dns_namespace} --request-timeout=10s get configmap deploykube-dns-wiring -o jsonpath='{.data.DNS_DELEGATION_MODE}'" \
    "manual" \
    "${timeout_seconds}" \
    "deploykube-dns-wiring.data.DNS_DELEGATION_MODE"
  wait_for_jsonpath_equals \
    "kubectl get deploymentconfigs.platform.darksite.cloud ${deploymentconfig_name} -o json | jq -r '.status.dns.delegation.mode // \"\"'" \
    "manual" \
    "${timeout_seconds}" \
    "DeploymentConfig.status.dns.delegation.mode"
  assert_manual_status
  assert_legacy_delegation_configmap_absent
  run_dns_external_sync_hooks
}

run_mode_auto() {
  echo ""
  echo "==> Phase: mode=auto"
  if [ -z "${parent_zone}" ]; then
    echo "error: parent zone is required for auto mode" >&2
    exit 2
  fi
  if [ -z "${writer_secret_name}" ] || [ -z "${writer_secret_namespace}" ]; then
    echo "error: auto mode requires writer secret ref (name+namespace)" >&2
    exit 2
  fi

  reset_writer_simulator_state

  local auto_json
  auto_json="$(jq -cn --arg parent "${parent_zone}" --arg name "${writer_secret_name}" --arg ns "${writer_secret_namespace}" '{mode:"auto",parentZone:$parent,writerRef:{name:$name,namespace:$ns}}')"
  patch_delegation "${auto_json}"
  sleep "${settle_seconds}"

  echo "  waiting for DNS_DELEGATION_MODE=auto snapshot"
  wait_for_jsonpath_equals \
    "kubectl -n ${dns_namespace} --request-timeout=10s get configmap deploykube-dns-wiring -o jsonpath='{.data.DNS_DELEGATION_MODE}'" \
    "auto" \
    "${timeout_seconds}" \
    "deploykube-dns-wiring.data.DNS_DELEGATION_MODE"
  wait_for_jsonpath_equals \
    "kubectl get deploymentconfigs.platform.darksite.cloud ${deploymentconfig_name} -o json | jq -r '.status.dns.delegation.mode // \"\"'" \
    "auto" \
    "${timeout_seconds}" \
    "DeploymentConfig.status.dns.delegation.mode"
  echo "  asserting legacy manual delegation configmap is absent"
  assert_legacy_delegation_configmap_absent
  echo "  waiting for tenant-networking-controller auto delegation reconcile log marker"
  wait_for_controller_log "auto delegation reconciled" "${timeout_seconds}"
  echo "  verifying expected NS/glue rrsets via simulator"
  assert_auto_rrsets_with_simulator
  echo "  running dns-external-sync hooks"
  run_dns_external_sync_hooks
}

prepare_auto_mode_writer() {
  local should_provision="no"
  case "${provision_writer_simulator}" in
    yes)
      should_provision="yes"
      ;;
    no)
      should_provision="no"
      ;;
    auto)
      if [ -z "${writer_secret_name}" ] || [ -z "${writer_secret_namespace}" ]; then
        should_provision="yes"
      fi
      ;;
  esac

  if [ "${should_provision}" = "yes" ]; then
    provision_writer_simulator_backend
  fi
}

pause_gitops_sync_for_test

echo "DeploymentConfig: ${deploymentconfig_name}"
echo "Profile: ${profile}"
echo "Run auto: ${run_auto}"
echo "Provision writer simulator: ${provision_writer_simulator}"
echo "Timeout: ${timeout}"
echo "Freeze GitOps sync: ${freeze_gitops_sync}"
if [ -n "${parent_zone}" ]; then
  echo "Parent zone: ${parent_zone}"
fi
if [ -n "${writer_secret_name}" ] && [ -n "${writer_secret_namespace}" ]; then
  echo "Auto writerRef: ${writer_secret_namespace}/${writer_secret_name}"
fi

run_mode_none
run_mode_manual

if [ "${profile}" = "full" ]; then
  should_run_auto="no"
  case "${run_auto}" in
    yes)
      should_run_auto="yes"
      ;;
    no)
      should_run_auto="no"
      ;;
    auto)
      if [ -n "${writer_secret_name}" ] && [ -n "${writer_secret_namespace}" ]; then
        should_run_auto="yes"
      elif [ "${provision_writer_simulator}" != "no" ]; then
        should_run_auto="yes"
      fi
      ;;
  esac

  if [ "${should_run_auto}" = "yes" ]; then
    prepare_auto_mode_writer
    run_mode_auto
  else
    echo ""
    echo "==> Skipping mode=auto (run_auto=${run_auto})"
  fi
fi

echo ""
echo "DNS delegation mode E2E passed (${profile})"
