#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./scripts/release/release-gate.sh [options]

Runs the repo's "Release E2E Gate" workflow against a self-hosted runner (intended: homelab Proxmox cluster),
waits for completion, and exits non-zero on failure.

This is the recommended "don't forget" path: treat this as a mandatory pre-release gate.

Options:
  --ref <gitref>          Git ref to validate (default: current branch)
  --kubeconfig-path <p>   Optional absolute kubeconfig path on the runner (workflow input)
  --cert-modes <csv>      Certificate modes CSV (default: subCa,acme,wildcard)
  --smoke-profile <v>     Runtime smoke profile quick|full (default: full)
  --include-restore-canary <v>
                          Also run backup restore canary yes|no (default: no)
  --run-upstream-sim <v>  auto|yes|no (default: auto)
  --timeout <dur>         Wait timeout for workflow run (default: 180m)
  -h|--help               Show this help

Prereqs:
  - gh CLI authenticated (`gh auth status`)
  - GitHub Actions enabled for the repo
  - Self-hosted runner has kubeconfig access to proxmox cluster
EOF
}

need() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing required binary: ${bin}" >&2
    exit 1
  fi
}

duration_to_seconds() {
  local d="$1"
  if [[ "${d}" =~ ^[0-9]+$ ]]; then
    echo "${d}"
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
  echo "error: unsupported duration '${d}' (use <n>, <n>m, <n>h)" >&2
  exit 2
}

ref="$(git branch --show-current 2>/dev/null || true)"
if [[ -z "${ref}" ]]; then
  ref="HEAD"
fi
kubeconfig_path=""
cert_modes="subCa,acme,wildcard"
smoke_profile="full"
include_restore_canary="no"
run_upstream_sim="auto"
timeout="180m"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      ref="${2:-}"
      shift 2
      ;;
    --kubeconfig-path)
      kubeconfig_path="${2:-}"
      shift 2
      ;;
    --cert-modes)
      cert_modes="${2:-}"
      shift 2
      ;;
    --smoke-profile)
      smoke_profile="${2:-}"
      shift 2
      ;;
    --include-restore-canary)
      include_restore_canary="${2:-}"
      shift 2
      ;;
    --run-upstream-sim)
      run_upstream_sim="${2:-}"
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

if [[ -z "${ref}" ]]; then
  echo "error: --ref is empty" >&2
  exit 2
fi

case "${run_upstream_sim}" in
  auto|yes|no) ;;
  *)
    echo "error: --run-upstream-sim must be auto|yes|no (got '${run_upstream_sim}')" >&2
    exit 2
    ;;
esac
case "${smoke_profile}" in
  quick|full) ;;
  *)
    echo "error: --smoke-profile must be quick|full (got '${smoke_profile}')" >&2
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

need gh

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated (run: gh auth login)" >&2
  exit 1
fi

target_sha="$(git rev-parse "${ref}^{commit}" 2>/dev/null || true)"
if [[ -z "${target_sha}" ]]; then
  echo "error: could not resolve --ref to a commit: ${ref}" >&2
  exit 2
fi

echo "==> Triggering workflow: Release E2E Gate"
echo "Ref: ${ref}"
echo "Target SHA: ${target_sha}"
echo "Cert modes: ${cert_modes}"
echo "Runtime smoke profile: ${smoke_profile}"
echo "Include restore canary: ${include_restore_canary}"
echo "Run upstream-sim: ${run_upstream_sim}"

args=(workflow run "Release E2E Gate" --ref "${ref}" -f "cert_modes=${cert_modes}" -f "smoke_profile=${smoke_profile}" -f "include_restore_canary=${include_restore_canary}" -f "run_upstream_sim=${run_upstream_sim}")
if [[ -n "${kubeconfig_path}" ]]; then
  args+=(-f "kubeconfig_path=${kubeconfig_path}")
fi

gh "${args[@]}" >/dev/null

echo "==> Resolving workflow run id"

# Best-effort: the run we triggered should be the most recent workflow_dispatch for this workflow and SHA.
run_id=""
for _ in $(seq 1 30); do
  run_id="$(
    gh run list \
      --workflow "Release E2E Gate" \
      --limit 1 \
      --json databaseId,event,headSha \
      --jq "if (.[0].event == \"workflow_dispatch\" and .[0].headSha == \"${target_sha}\") then .[0].databaseId else empty end"
  )"
  if [[ -n "${run_id}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${run_id}" ]]; then
  run_id="$(
    gh run list \
      --workflow "Release E2E Gate" \
      --limit 20 \
      --json databaseId,event,headSha,createdAt \
      --jq "[.[] | select(.event == \"workflow_dispatch\" and .headSha == \"${target_sha}\")][0].databaseId // empty"
  )"
fi

if [[ -z "${run_id}" || "${run_id}" == "null" ]]; then
  echo "error: failed to resolve workflow run id" >&2
  echo "hint: open GitHub Actions and locate the newest 'Release E2E Gate' run for SHA ${target_sha}" >&2
  exit 1
fi

timeout_seconds="$(duration_to_seconds "${timeout}")"

echo "==> Waiting for workflow run: ${run_id} (timeout=${timeout})"
if ! gh run watch "${run_id}" --exit-status --interval 10 --timeout "${timeout_seconds}s"; then
  echo "FAIL: Release E2E Gate failed (run id: ${run_id})" >&2
  exit 1
fi

echo "Release E2E Gate PASSED (run id: ${run_id})"
