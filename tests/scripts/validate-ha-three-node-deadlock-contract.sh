#!/usr/bin/env bash
# validate-ha-three-node-deadlock-contract.sh
#
# Purpose:
# - Enforce the product HA baseline for proxmox-talos:
#   - minimum worker-node floor is 3
#   - hard anti-affinity workloads with 3+ replicas stay schedulable on 3 nodes
# - Prevent rollout deadlocks for Deployment workloads that use hard anti-affinity.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

ENV_BUNDLE="platform/gitops/apps/environments/proxmox-talos"
PLATFORM_APPS_OVERLAY="platform/gitops/components/platform/platform-apps-controller/overlays/proxmox-talos"
PROXMOX_BOOTSTRAP_CONFIG="bootstrap/proxmox-talos/config.yaml"
ARGOCD_VALUES_RESOURCES="bootstrap/shared/argocd/values-resources.yaml"
TARGET_STACK_DOC="target-stack.md"

tmp_dir="$(mktemp -d)"
failures=0
checked_sources=0
qualified_workloads=0
violations_found=0
workloads_seen=0
tmp_helm_dir=""

cleanup() {
  if [[ -n "${tmp_helm_dir}" && -d "${tmp_helm_dir}" ]]; then
    rm -rf "${tmp_helm_dir}"
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

helm_short() {
  local cmd="$1"
  "${cmd}" version --short 2>/dev/null || true
}

helm_is_v3() {
  local cmd="$1"
  helm_short "${cmd}" | rg -q '^v3\.'
}

resolve_helm_v3() {
  if [[ -n "${HELM_BIN:-}" ]]; then
    if ! helm_is_v3 "${HELM_BIN}"; then
      echo "error: HELM_BIN must point to helm v3 (found: $(helm_short "${HELM_BIN}"))" >&2
      exit 1
    fi
    echo "${HELM_BIN}"
    return 0
  fi

  if command -v helm >/dev/null 2>&1 && helm_is_v3 helm; then
    echo "helm"
    return 0
  fi
  if command -v helm3 >/dev/null 2>&1 && helm_is_v3 helm3; then
    echo "helm3"
    return 0
  fi
  if [[ -x "./tmp/tools/helm" ]] && helm_is_v3 "./tmp/tools/helm"; then
    echo "./tmp/tools/helm"
    return 0
  fi

  echo "error: no helm v3 binary found (set HELM_BIN to a helm v3 binary)" >&2
  echo "found helm: $(helm_short helm)" >&2
  exit 1
}

activate_helm_v3() {
  local helm_bin="$1"
  if [[ "${helm_bin}" == "helm" ]]; then
    return 0
  fi

  tmp_helm_dir="$(mktemp -d)"
  if [[ "${helm_bin}" == */* ]]; then
    ln -s "$(cd "$(dirname "${helm_bin}")" && pwd)/$(basename "${helm_bin}")" "${tmp_helm_dir}/helm"
  else
    ln -s "$(command -v "${helm_bin}")" "${tmp_helm_dir}/helm"
  fi
  export PATH="${tmp_helm_dir}:${PATH}"
}

render_path() {
  local rel="$1"
  local abs="platform/gitops/${rel}"
  if [[ -f "${abs}/kustomization.yaml" || -f "${abs}/kustomization.yml" || -f "${abs}/Kustomization" ]]; then
    kustomize build --enable-helm "${abs}"
    return 0
  fi
  if [[ -f "${abs}/Chart.yaml" ]]; then
    helm template "ha-ci-$(echo "${rel}" | tr '/.' '-')" "${abs}"
    return 0
  fi
  return 1
}

collect_env_paths() {
  kustomize build --enable-helm "${ENV_BUNDLE}" \
    | yq -p=yaml -o=json '.' \
    | jq -r 'select(.kind=="Application") | .spec.source.path' \
    | sort -u
}

collect_platformapps_paths() {
  local platformapps_json paths_raw

  platformapps_json="$(
    kustomize build --enable-helm "${PLATFORM_APPS_OVERLAY}" \
      | yq -p=yaml -o=json '.' \
      | jq -c 'select(.kind=="PlatformApps")'
  )"
  if [[ -z "${platformapps_json}" ]]; then
    fail "could not render PlatformApps CR from ${PLATFORM_APPS_OVERLAY}"
    return 1
  fi

  if ! paths_raw="$(
    printf '%s\n' "${platformapps_json}" \
      | jq -r '
          .spec as $s |
          ($s.enabledApps // []
            | map(tostring)
            | map(gsub("^\\s+|\\s+$";""))
            | map(select(length > 0))
            | map({(.): true})
            | add // {}) as $enabled |
          ($s.disabledApps // []
            | map(tostring)
            | map(gsub("^\\s+|\\s+$";""))
            | map(select(length > 0))
            | map({(.): true})
            | add // {}) as $disabled |
          ($s.apps // [])[] |
          (.name | tostring | gsub("^\\s+|\\s+$";"")) as $name |
          select($name != "") |
          select(($disabled[$name] // false) | not) |
          select((.enabled == false and ($enabled[$name] // false | not)) | not) |
          if (.overlay // false) then
            if ((.overlayPaths // {}) | length) > 0 then
              (.overlayPaths[$s.overlayMode] // error("missing overlay path for app " + $name + " mode " + ($s.overlayMode|tostring)))
            elif ($s.deploymentId // "") != "" then
              ((.path | tostring) + "/overlays/" + ($s.deploymentId | tostring))
            elif ($s.overlayMode // "") != "" then
              ((.path | tostring) + "/overlays/" + ($s.overlayMode | tostring))
            else
              (.path | tostring)
            end
          else
            (.path | tostring)
          end |
          tostring |
          gsub("\\{\\{ \\$\\.Values\\.deploymentId \\}\\}"; ($s.deploymentId | tostring))
        '
  )"; then
    fail "failed to derive effective PlatformApps source paths for proxmox-talos"
    return 1
  fi

  printf '%s\n' "${paths_raw}" | sort -u
}

check_worker_floor() {
  local workers
  workers="$(yq -r '.nodes.workers | length' "${PROXMOX_BOOTSTRAP_CONFIG}" 2>/dev/null || true)"
  if [[ ! "${workers}" =~ ^[0-9]+$ ]]; then
    fail "could not parse nodes.workers length from ${PROXMOX_BOOTSTRAP_CONFIG}"
    return
  fi
  if (( workers < 3 )); then
    fail "${PROXMOX_BOOTSTRAP_CONFIG} must define at least 3 workers (found ${workers})"
    return
  fi
  echo "PASS: proxmox worker floor is ${workers} (>=3)"
}

check_target_stack_contract() {
  if ! rg -n -q --fixed-strings "Minimum worker nodes (prod baseline): 3" "${TARGET_STACK_DOC}"; then
    fail "${TARGET_STACK_DOC} must explicitly advertise 'Minimum worker nodes (prod baseline): 3'"
    return
  fi
  echo "PASS: target stack documents the 3-worker prod baseline"
}

check_argocd_rollout_contract() {
  local global_type global_surge global_unavail
  local haproxy_type haproxy_surge haproxy_unavail

  global_type="$(yq -r '.global.deploymentStrategy.type // ""' "${ARGOCD_VALUES_RESOURCES}")"
  global_surge="$(yq -r '.global.deploymentStrategy.rollingUpdate.maxSurge // ""' "${ARGOCD_VALUES_RESOURCES}")"
  global_unavail="$(yq -r '.global.deploymentStrategy.rollingUpdate.maxUnavailable // ""' "${ARGOCD_VALUES_RESOURCES}")"
  haproxy_type="$(yq -r '.redis-ha.haproxy.deploymentStrategy.type // ""' "${ARGOCD_VALUES_RESOURCES}")"
  haproxy_surge="$(yq -r '.redis-ha.haproxy.deploymentStrategy.rollingUpdate.maxSurge // ""' "${ARGOCD_VALUES_RESOURCES}")"
  haproxy_unavail="$(yq -r '.redis-ha.haproxy.deploymentStrategy.rollingUpdate.maxUnavailable // ""' "${ARGOCD_VALUES_RESOURCES}")"

  if [[ "${global_type}" != "RollingUpdate" || "${global_surge}" != "0" || "${global_unavail}" != "1" ]]; then
    fail "${ARGOCD_VALUES_RESOURCES} must set global deploymentStrategy to RollingUpdate with maxSurge=0 and maxUnavailable=1"
  fi
  if [[ "${haproxy_type}" != "RollingUpdate" || "${haproxy_surge}" != "0" || "${haproxy_unavail}" != "1" ]]; then
    fail "${ARGOCD_VALUES_RESOURCES} must set redis-ha.haproxy deploymentStrategy to RollingUpdate with maxSurge=0 and maxUnavailable=1"
  fi
  if [[ "${failures}" -eq 0 ]]; then
    echo "PASS: Argo CD bootstrap rollout strategy contract is anti-affinity-safe"
  fi
}

check_ha_tier_contract() {
  local source="$1"
  local rendered="$2"

  mapfile -t tier_violations < <(
    printf '%s\n' "${rendered}" \
      | yq -p=yaml -o=json '.' \
      | jq -r --arg source "${source}" '
          def label_meta: (.metadata.labels["darksite.cloud/ha-tier"] // "");
          def label_tpl: (.spec.template.metadata.labels["darksite.cloud/ha-tier"] // "");
          def replicas: (.spec.replicas // 1);
          . as $obj
          | select($obj.kind=="Deployment" or $obj.kind=="StatefulSet")
          | (label_meta) as $meta
          | (label_tpl) as $tpl
          | (if $meta != "" then $meta else $tpl end) as $tier
          | (
              (if ($meta == "" and $tpl == "") then
                [{reason:"missing-ha-tier-label", details:"set darksite.cloud/ha-tier on metadata.labels and pod template labels"}]
              else [] end)
              +
              (if ($meta != "" and $tpl != "" and $meta != $tpl) then
                [{reason:"ha-tier-label-mismatch", details:("metadata=" + $meta + " template=" + $tpl)}]
              else [] end)
              +
              (if ($tier != "" and ($tier != "tier-0" and $tier != "tier-1" and $tier != "tier-2")) then
                [{reason:"invalid-ha-tier-value", details:("darksite.cloud/ha-tier=" + $tier)}]
              else [] end)
              +
              (if ($tier == "tier-0" and (replicas < 3)) then
                [{reason:"tier-0-replicas", details:("replicas=" + (replicas|tostring) + " (need >=3)")}]
              else [] end)
              +
              (if ($tier == "tier-0" and ((replicas % 2) == 0)) then
                [{reason:"tier-0-even-replicas", details:("replicas=" + (replicas|tostring) + " (use odd count for quorum)")}]
              else [] end)
              +
              (if ($tier == "tier-1" and (replicas < 2)) then
                [{reason:"tier-1-replicas", details:("replicas=" + (replicas|tostring) + " (need >=2)")}]
              else [] end)
            )
          | .[]
          | [
              $source,
              $obj.kind,
              ($obj.metadata.namespace // "default"),
              ($obj.metadata.name // "(unknown)"),
              .reason,
              .details
            ] | @tsv
        '
  )

  local seen
  seen="$(
    printf '%s\n' "${rendered}" \
      | yq -p=yaml -o=json '.' \
      | jq -r 'select(.kind=="Deployment" or .kind=="StatefulSet") | 1' \
      | wc -l | tr -d ' '
  )"
  workloads_seen=$((workloads_seen + seen))

  local v
  for v in "${tier_violations[@]}"; do
    IFS=$'\t' read -r v_source v_kind v_ns v_name v_reason v_details <<<"${v}"
    echo "FAIL: ${v_source} ${v_kind}/${v_ns}/${v_name} ${v_reason} (${v_details})" >&2
    failures=$((failures + 1))
    violations_found=$((violations_found + 1))
  done
}

echo "==> Validating three-node HA deadlock contract (proxmox-talos)"

require_cmd jq
require_cmd yq
require_cmd kustomize
require_cmd helm
require_cmd rg

helm_v3_bin="$(resolve_helm_v3)"
activate_helm_v3 "${helm_v3_bin}"

check_worker_floor
check_target_stack_contract
check_argocd_rollout_contract

paths_file="${tmp_dir}/paths.txt"
{
  collect_env_paths
  collect_platformapps_paths
} | sort -u > "${paths_file}"

if [[ ! -s "${paths_file}" ]]; then
  fail "no application source paths discovered from ${ENV_BUNDLE} + ${PLATFORM_APPS_OVERLAY}"
fi

while IFS= read -r rel; do
  [[ -n "${rel}" ]] || continue
  checked_sources=$((checked_sources + 1))
  if ! rendered="$(render_path "${rel}" 2>"${tmp_dir}/render.err")"; then
    fail "failed to render platform source path '${rel}' ($(head -n 1 "${tmp_dir}/render.err"))"
    continue
  fi

  check_ha_tier_contract "${rel}" "${rendered}"

  q_count="$(
    printf '%s\n' "${rendered}" \
      | yq -p=yaml -o=json '.' \
      | jq -r '
          def hard_terms: (.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution // []);
          . | select((.kind=="Deployment" or .kind=="StatefulSet"))
            | select((hard_terms | length) > 0 and ((.spec.replicas // 1) >= 3))
            | 1
        ' \
      | wc -l | tr -d ' '
  )"
  qualified_workloads=$((qualified_workloads + q_count))

  mapfile -t resource_violations < <(
    printf '%s\n' "${rendered}" \
      | yq -p=yaml -o=json '.' \
      | jq -r --arg source "${rel}" '
          def hard_terms: (.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution // []);
          def replicas: (.spec.replicas // 1);
          . as $obj
          | select(($obj.kind=="Deployment" or $obj.kind=="StatefulSet"))
          | select((hard_terms | length) > 0 and (replicas >= 3))
          | (
              (if replicas != 3 then
                [{reason:"replicas-not-3", details:("replicas=" + (replicas|tostring))}]
              else [] end)
              +
              (if ([hard_terms[]? | select((.topologyKey // "") == "kubernetes.io/hostname")] | length) == 0 then
                [{reason:"missing-hostname-hard-anti-affinity", details:"requiredDuringSchedulingIgnoredDuringExecution must include topologyKey=kubernetes.io/hostname"}]
              else [] end)
              +
              (if $obj.kind == "Deployment" then
                ( ($obj.spec.strategy.type // "RollingUpdate") | tostring ) as $stype |
                ( ($obj.spec.strategy.rollingUpdate.maxSurge // "25%") | tostring ) as $maxSurge |
                ( ($obj.spec.strategy.rollingUpdate.maxUnavailable // "25%") | tostring ) as $maxUnavailable |
                [
                  (if $stype != "RollingUpdate" then
                    {reason:"deployment-strategy-type", details:("strategy.type=" + $stype)}
                  else empty end),
                  (if ($maxSurge != "0" and $maxSurge != "0%") then
                    {reason:"deployment-maxSurge", details:("maxSurge=" + $maxSurge)}
                  else empty end),
                  (if $maxUnavailable != "1" then
                    {reason:"deployment-maxUnavailable", details:("maxUnavailable=" + $maxUnavailable)}
                  else empty end)
                ]
              else [] end)
            )
          | .[]
          | [
              $source,
              $obj.kind,
              ($obj.metadata.namespace // "default"),
              ($obj.metadata.name // "(unknown)"),
              .reason,
              .details
            ] | @tsv
        '
  )

  for v in "${resource_violations[@]}"; do
    IFS=$'\t' read -r source kind ns name reason details <<<"${v}"
    echo "FAIL: ${source} ${kind}/${ns}/${name} ${reason} (${details})" >&2
    failures=$((failures + 1))
    violations_found=$((violations_found + 1))
  done
done < "${paths_file}"

echo ""
echo "==> Summary"
echo "- Rendered source paths: ${checked_sources}"
echo "- Deployments/StatefulSets evaluated: ${workloads_seen}"
echo "- Qualified hard anti-affinity workloads (replicas>=3): ${qualified_workloads}"
echo "- Violations: ${violations_found}"

if [[ "${qualified_workloads}" -eq 0 ]]; then
  fail "no qualified workloads found; check render/discovery logic in this validator"
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "three-node HA deadlock contract FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "three-node HA deadlock contract PASSED"
