#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/e2e-release-runtime-smokes.sh [options]

Goal:
  Run the curated runtime smoke suite used by release gating.

Profiles:
  quick  - high-signal networking/secrets/registry checks
  full   - quick set plus observability/valkey/backup-system checks

Options:
  --profile <quick|full>          Suite profile (default: full)
  --timeout <duration>            Wait timeout passed to run-runtime-smokes.sh (default: 25m quick, 35m full)
  --argocd-namespace <ns>         Argo CD namespace (default: argocd)
  --allow-missing-apps <yes|no>   Skip missing Applications instead of failing (default: no)
  --include-restore-canary <yes|no>
                                  Also trigger CronJob/storage-canary-restore (default: no)
  --help                          Show this help

Examples:
  ./tests/scripts/e2e-release-runtime-smokes.sh --profile quick
  ./tests/scripts/e2e-release-runtime-smokes.sh --profile full --include-restore-canary yes
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

run_cronjob_once() {
  local ns="$1"
  local cronjob="$2"
  local timeout_seconds="$3"
  local run_id="$4"
  local job
  job="$(trunc_name "${cronjob}" "manual-${run_id}")"

  echo "- ${ns}/CronJob/${cronjob} -> Job/${job}"
  kubectl -n "${ns}" create job --from=cronjob/"${cronjob}" "${job}" >/dev/null

  if wait_for_job_completion_or_failure "${ns}" "${job}" "${timeout_seconds}"; then
    echo "  OK: ${ns}/Job/${job}"
    return 0
  fi

  echo "  FAIL: ${ns}/Job/${job}" >&2
  kubectl -n "${ns}" describe job "${job}" >&2 || true
  kubectl -n "${ns}" logs "job/${job}" --tail=200 >&2 || true
  return 1
}

profile="full"
timeout=""
argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
allow_missing_apps="no"
include_restore_canary="no"

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
    --argocd-namespace)
      argocd_namespace="${2:-}"
      shift 2
      ;;
    --allow-missing-apps)
      allow_missing_apps="${2:-}"
      shift 2
      ;;
    --include-restore-canary)
      include_restore_canary="${2:-}"
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

case "${profile}" in
  quick|full) ;;
  *)
    echo "error: --profile must be quick|full (got '${profile}')" >&2
    exit 2
    ;;
esac

case "${allow_missing_apps}" in
  yes|no) ;;
  *)
    echo "error: --allow-missing-apps must be yes|no (got '${allow_missing_apps}')" >&2
    exit 2
    ;;
esac

case "${include_restore_canary}" in
  yes|no) ;;
  *)
    echo "error: --include-restore-canary must be yes|no (got '${include_restore_canary}')" >&2
    exit 2
    ;;
esac

if [[ -z "${timeout}" ]]; then
  if [[ "${profile}" == "quick" ]]; then
    timeout="25m"
  else
    timeout="35m"
  fi
fi
timeout_seconds="$(duration_to_seconds "${timeout}")"

quick_apps=(
  networking-metallb
  networking-gateway-api
  networking-dns-external-sync
  networking-ingress-smoke-tests
  shared-policy-kyverno
  secrets-vault-config
  secrets-external-secrets-config
  platform-registry-harbor-smoke-tests
)

full_extra_apps=(
  platform-observability-tests
  platform-forgejo-valkey-smoke-tests
)

apps=("${quick_apps[@]}")
if [[ "${profile}" == "full" ]]; then
  apps+=("${full_extra_apps[@]}")
fi

echo "==> Validating selected Argo CD Applications exist"
selected_apps=()
for app in "${apps[@]}"; do
  if kubectl -n "${argocd_namespace}" get application "${app}" >/dev/null 2>&1; then
    selected_apps+=("${app}")
    echo "- ${argocd_namespace}/Application/${app}"
    continue
  fi

  if [[ "${allow_missing_apps}" == "yes" ]]; then
    echo "WARN: missing ${argocd_namespace}/Application/${app}; skipping"
    continue
  fi

  echo "FAIL: missing required ${argocd_namespace}/Application/${app}" >&2
  exit 1
done

if [[ "${#selected_apps[@]}" -eq 0 ]]; then
  echo "error: no Applications selected for runtime smokes" >&2
  exit 1
fi

echo ""
echo "==> Running curated runtime smokes (profile=${profile}, timeout=${timeout})"
run_args=(--timeout "${timeout}" --wait --hooks --cronjobs)
for app in "${selected_apps[@]}"; do
  run_args+=(--app "${app}")
done
ARGOCD_NAMESPACE="${argocd_namespace}" ./tests/scripts/run-runtime-smokes.sh "${run_args[@]}"

if [[ "${profile}" == "full" ]]; then
  echo ""
  echo "==> Running explicit non-destructive backup smokes"
  backup_run_id="$(date -u +%Y%m%d%H%M%S)"
  run_cronjob_once "backup-system" "storage-smoke-backup-target-write" "${timeout_seconds}" "${backup_run_id}"
  run_cronjob_once "backup-system" "storage-smoke-backups-freshness" "${timeout_seconds}" "${backup_run_id}"
  run_cronjob_once "backup-system" "storage-smoke-pvc-restic-credentials" "${timeout_seconds}" "${backup_run_id}"
fi

if [[ "${include_restore_canary}" == "yes" ]]; then
  echo ""
  echo "==> Running optional backup restore canary"
  backup_namespace="backup-system"
  restore_cronjob="storage-canary-restore"
  run_id="$(date -u +%Y%m%d%H%M%S)"
  restore_job="$(trunc_name "${restore_cronjob}" "manual-${run_id}")"

  kubectl -n "${backup_namespace}" create job --from=cronjob/"${restore_cronjob}" "${restore_job}" >/dev/null
  echo "- ${backup_namespace}/CronJob/${restore_cronjob} -> Job/${restore_job}"

  if wait_for_job_completion_or_failure "${backup_namespace}" "${restore_job}" "${timeout_seconds}"; then
    echo "  OK: ${backup_namespace}/Job/${restore_job}"
  else
    echo "  FAIL: ${backup_namespace}/Job/${restore_job}" >&2
    kubectl -n "${backup_namespace}" describe job "${restore_job}" >&2 || true
    kubectl -n "${backup_namespace}" logs "job/${restore_job}" --tail=200 >&2 || true
    exit 1
  fi
fi

echo ""
echo "Release runtime smoke suite passed (${profile})"
