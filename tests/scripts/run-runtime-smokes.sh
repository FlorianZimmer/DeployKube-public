#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/run-runtime-smokes.sh [options]

Goal:
  Trigger DeployKube "smoke" validation runs on a live cluster.

Selection (required):
  --all                  Run all smoke CronJobs in the cluster (names contain "smoke")
  --app <name>           Scope to a specific Argo CD Application (repeatable)

Modes:
  --cronjobs             Trigger smoke CronJobs by creating Jobs from them (default)
  --hooks                Trigger Argo hook-based smoke Jobs by syncing the selected Application(s)

Execution:
  --wait                 Wait for triggered runs to complete and report failures
  --timeout <duration>   Wait timeout (default: 20m). Examples: 5m, 900s
  --include-suspended    Include CronJobs with spec.suspend=true (default: skip)

Env:
  KUBECONFIG / kubectl context are respected.
  ARGOCD_NAMESPACE defaults to "argocd".

Examples:
  # Run all smoke CronJobs now (cluster-wide)
  ./tests/scripts/run-runtime-smokes.sh --all --cronjobs --wait

  # Rerun only Istio namespaces hook smoke (PostSync) + its smoke CronJobs (if any)
  ./tests/scripts/run-runtime-smokes.sh --app networking-istio-namespaces --hooks --cronjobs --wait

Notes:
  - This is a runtime (cluster) check. It is intentionally NOT part of ./tests/scripts/ci.sh.
  - Prod clusters may override bootstrap-tools images via Argo Kustomize image overrides; this script triggers
    CronJobs from the cluster (so the jobTemplate image is already correct) and hook Jobs via Argo sync.
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

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

mode_cronjobs=1
mode_hooks=0
wait=0
timeout="20m"
all=0
include_suspended=0
apps=()

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    --all)
      all=1
      shift
      ;;
    --app)
      apps+=("${2:-}")
      shift 2
      ;;
    --cronjobs)
      mode_cronjobs=1
      shift
      ;;
    --hooks)
      mode_hooks=1
      shift
      ;;
    --wait)
      wait=1
      shift
      ;;
    --include-suspended)
      include_suspended=1
      shift
      ;;
    --timeout)
      timeout="${2:-}"
      shift 2
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

if [ "${all}" -eq 0 ] && [ "${#apps[@]}" -eq 0 ]; then
  echo "error: selection required (use --all or --app <name>)" >&2
  usage >&2
  exit 2
fi

run_id="$(date -u +%Y%m%d%H%M%S)"
timeout_seconds="$(duration_to_seconds "${timeout}")"

wait_for_job_completion_or_failure() {
  local ns="$1"
  local job="$2"

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

try_argocd_terminate_operation() {
  local app="$1"
  local kube_ctx=""
  local tmp_kubeconfig=""

  if ! command -v argocd >/dev/null 2>&1; then
    return 1
  fi

  kube_ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "${kube_ctx}" ]; then
    return 1
  fi

  tmp_kubeconfig="$(mktemp)"
  if ! kubectl config view --raw >"${tmp_kubeconfig}" 2>/dev/null; then
    rm -f "${tmp_kubeconfig}" || true
    return 1
  fi

  # argocd --core resolves argocd-cm in the context namespace.
  KUBECONFIG="${tmp_kubeconfig}" kubectl config set-context "${kube_ctx}" --namespace="${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || true

  if KUBECONFIG="${tmp_kubeconfig}" argocd app terminate-op "${app}" --core --kube-context "${kube_ctx}" >/dev/null 2>&1; then
    rm -f "${tmp_kubeconfig}" || true
    return 0
  fi

  rm -f "${tmp_kubeconfig}" || true
  return 1
}

is_ignorable_cronjob_health_sync_failure() {
  local app="$1"
  local app_json=""
  local sync_status=""

  app_json="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o json 2>/dev/null || true)"
  if [ -z "${app_json}" ]; then
    return 1
  fi

  sync_status="$(jq -r '.status.sync.status // ""' <<<"${app_json}")"
  if [ "${sync_status}" != "Synced" ]; then
    return 1
  fi

  jq -e '
    (.status.operationState.syncResult.resources // []) as $resources
    | ($resources | map(select((.hookPhase // "") == "Failed"))) as $failed
    | ($failed | length) > 0
      and ($failed | all(
        (.kind // "") == "CronJob"
        and (.status // "") == "Synced"
        and ((.message // "") | test("CronJob has not completed its last execution successfully"))
      ))
  ' <<<"${app_json}" >/dev/null 2>&1
}

selected_apps=()
if [ "${all}" -eq 1 ]; then
  mapfile -t selected_apps < <(kubectl -n "${ARGOCD_NAMESPACE}" get applications -o json | jq -r '.items[].metadata.name' | sort)
else
  selected_apps=("${apps[@]}")
fi

if [ "${mode_hooks}" -eq 1 ]; then
  echo ""
  echo "==> Triggering Argo hook smokes (sync Application)"
  for app in "${selected_apps[@]}"; do
    if [ -z "${app}" ]; then
      echo "error: empty --app value" >&2
      exit 2
    fi
    echo "- sync ${ARGOCD_NAMESPACE}/Application/${app}"
    kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s annotate application "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null || true
    had_existing_requested=0
    existing_phase="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    existing_started="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)"
    existing_operation="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.operation}' 2>/dev/null || true)"
    if [ -n "${existing_operation}" ]; then
      had_existing_requested=1
      echo "  INFO: terminating pre-existing operation phase=${existing_phase:-<unknown>} started=${existing_started:-<unknown>}"
      if try_argocd_terminate_operation "${app}"; then
        echo "  INFO: requested terminate-op via argocd CLI"
      fi
      kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s patch application "${app}" --type merge -p '{"operation":null}' >/dev/null || true
      for _ in $(seq 1 30); do
        pending="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.operation}' 2>/dev/null || true)"
        [ -z "${pending}" ] && break
        sleep 1
      done
    fi
    prev_started="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)"
    sync_source_json="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o json | jq -c '.spec.source // null')"
    if [ "${sync_source_json}" != "null" ]; then
      sync_patch_payload="$(jq -cn --argjson source "${sync_source_json}" '{"operation":{"sync":{"prune":true,"source":$source}}}')"
    else
      sync_patch_payload='{"operation":{"sync":{"prune":true}}}'
    fi
    kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s patch application "${app}" --type merge -p "${sync_patch_payload}" >/dev/null

    if [ "${wait}" -eq 1 ]; then
      # Poll for completion of the operation we just triggered (ignore stale prior operationState).
      loops=$((timeout_seconds / 2))
      if [ "${loops}" -lt 1 ]; then
        loops=1
      fi
      completed=0
      observed_new_operation=0
      retriggered_after_terminate=0
      for _ in $(seq 1 "${loops}"); do
        started="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)"
        phase="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
        finished="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)"
        requested_operation="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.operation}' 2>/dev/null || true)"

        # A previously failed operation may still be recorded. Evaluate only once we can
        # correlate state to the just-triggered request.
        if [ -n "${started}" ] && [ "${started}" != "${prev_started}" ]; then
          observed_new_operation=1
        elif [ "${had_existing_requested}" -eq 1 ] && [ -n "${requested_operation}" ]; then
          observed_new_operation=1
        else
          if [ "${had_existing_requested}" -eq 1 ] && [ -z "${requested_operation}" ] && [ "${retriggered_after_terminate}" -eq 0 ]; then
            msg="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
            if [ "${phase}" = "Failed" ] && printf '%s' "${msg}" | grep -qi "operation terminated"; then
              echo "  INFO: prior operation terminated; triggering fresh sync"
              kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s patch application "${app}" --type merge -p "${sync_patch_payload}" >/dev/null || true
              retriggered_after_terminate=1
              prev_started="${started}"
              sleep 2
              continue
            fi
          fi
          sleep 2
          continue
        fi

        case "${phase}" in
          Succeeded)
            echo "  OK: ${app} op=${phase} started=${started:-<unknown>} finished=${finished:-<unknown>}"
            completed=1
            break
          ;;
          Failed|Error)
            if is_ignorable_cronjob_health_sync_failure "${app}"; then
              echo "  WARN: ${app} op=${phase} but only CronJob health drift was reported; continuing"
              completed=1
              break
            fi
            echo "  FAIL: ${app} op=${phase} started=${started:-<unknown>} finished=${finished:-<unknown>}" >&2
            msg="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
            [ -n "${msg}" ] && echo "  message: ${msg}" >&2
            exit 1
          ;;
          *)
            sleep 2
          ;;
        esac
      done
      if [ "${completed}" -ne 1 ]; then
        if [ "${observed_new_operation}" -ne 1 ]; then
          echo "  FAIL: ${app} did not start a new operation within timeout=${timeout}" >&2
        else
          echo "  FAIL: ${app} operation did not reach terminal state within timeout=${timeout}" >&2
        fi
        phase="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
        started="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)"
        msg="$(kubectl -n "${ARGOCD_NAMESPACE}" --request-timeout=10s get application "${app}" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
        [ -n "${phase}" ] && echo "  phase: ${phase}" >&2
        [ -n "${started}" ] && echo "  startedAt: ${started}" >&2
        [ -n "${msg}" ] && echo "  message: ${msg}" >&2
        exit 1
      fi
    fi
  done
fi

triggered_jobs=()

if [ "${mode_cronjobs}" -eq 1 ]; then
  echo ""
  echo "==> Triggering smoke CronJobs (create Job from CronJob)"

  cronjobs_json="$(kubectl get cronjobs.batch -A -o json)"

  if [ "${all}" -eq 1 ]; then
    mapfile -t cronjob_refs < <(
      jq -r --argjson include_suspended "${include_suspended}" '
        .items[]
        | select(.metadata.name | test("smoke"))
        | select($include_suspended == 1 or ((.spec.suspend // false) | not))
        | "\(.metadata.namespace)\t\(.metadata.name)\t\(.metadata.annotations["argocd.argoproj.io/tracking-id"] // "")"
      ' <<<"${cronjobs_json}" | sort
    )
  else
    mapfile -t cronjob_refs < <(
      jq -r --argjson include_suspended "${include_suspended}" '
        .items[]
        | select(.metadata.name | test("smoke"))
        | select($include_suspended == 1 or ((.spec.suspend // false) | not))
        | "\(.metadata.namespace)\t\(.metadata.name)\t\(.metadata.annotations["argocd.argoproj.io/tracking-id"] // "")"
      ' <<<"${cronjobs_json}" \
      | awk -v apps="$(printf '%s\n' "${selected_apps[@]}" | paste -sd '|' -)" '
          BEGIN { split(apps, a, "|"); for (i in a) allow[a[i]] = 1 }
          {
            tracking = $3
            if (tracking ~ /^[^:]+:/) {
              app = tracking
              sub(/:.*/, "", app)
              if (allow[app]) print $0
            }
          }
        ' \
      | sort
    )
  fi

  if [ "${#cronjob_refs[@]}" -eq 0 ]; then
    echo "  (no smoke CronJobs matched selection)"
  fi

  for row in "${cronjob_refs[@]}"; do
    ns="$(awk '{print $1}' <<<"${row}")"
    cj="$(awk '{print $2}' <<<"${row}")"
    job="$(trunc_name "${cj}" "manual-${run_id}")"
    echo "- ${ns}/CronJob/${cj} -> Job/${job}"
    kubectl -n "${ns}" create job --from=cronjob/"${cj}" "${job}" >/dev/null
    triggered_jobs+=("${ns}\t${job}")

    if [ "${wait}" -eq 1 ]; then
      if wait_for_job_completion_or_failure "${ns}" "${job}"; then
        echo "  OK: ${ns}/Job/${job}"
      else
        echo "  FAIL: ${ns}/Job/${job}" >&2
        kubectl -n "${ns}" describe job "${job}" >&2 || true
        kubectl -n "${ns}" logs "job/${job}" --tail=200 >&2 || true
        exit 1
      fi
    fi
  done
fi

if [ "${wait}" -eq 0 ]; then
  echo ""
  echo "Triggered run_id=${run_id}."
  if [ "${#triggered_jobs[@]}" -gt 0 ]; then
    echo "Tip: check status with:"
    echo "  kubectl get jobs.batch -A | rg \"manual-${run_id}\""
  fi
fi
