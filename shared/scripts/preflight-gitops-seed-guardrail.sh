#!/usr/bin/env bash
# preflight-gitops-seed-guardrail.sh
#
# Bootstrap guardrail: refuse to seed Forgejo from a dirty repo, and fail fast if
# DeploymentConfig-driven rendered overlays drift from their committed outputs.
#
# Why:
# - Forgejo seeding snapshots git HEAD (committed state). Uncommitted changes are ignored.
# - Some overlays are repo-rendered from DeploymentConfig and committed (Phase 4 style). If they
#   drift, bootstraps can seed inconsistent state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

DEPLOYMENT_ID=""
FORCE_SEED="false"
SEED_SENTINEL=""

usage() {
  cat <<'USAGE'
Usage:
  ./shared/scripts/preflight-gitops-seed-guardrail.sh \
    --deployment-id <id> \
    --seed-sentinel <path> \
    [--force-seed true|false]

What it checks (when seeding is expected to run):
  1) The git working tree is clean (no staged/unstaged/untracked changes).
  2) DeploymentConfig-driven rendered overlays are in sync with what renderers would output.

Notes:
  - If the seed sentinel exists and --force-seed is false, this script exits 0 (skips preflight),
    because Stage 1 will typically skip seeding as well.
USAGE
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

run() {
  echo ""
  echo "==> $*"
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --seed-sentinel) SEED_SENTINEL="$2"; shift 2 ;;
    --force-seed) FORCE_SEED="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" ]]; then
  echo "error: missing --deployment-id" >&2
  usage >&2
  exit 1
fi
if [[ -z "${SEED_SENTINEL}" ]]; then
  echo "error: missing --seed-sentinel" >&2
  usage >&2
  exit 1
fi

if [[ -f "${SEED_SENTINEL}" && "${FORCE_SEED}" != "true" ]]; then
  echo "==> GitOps seed sentinel present; skipping preflight (set --force-seed true to force)"
  echo "==> Sentinel: ${SEED_SENTINEL}"
  exit 0
fi

require git

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git worktree; cannot safely seed Forgejo" >&2
  exit 1
fi

echo "==> Preflight: GitOps seed guardrail (deploymentId=${DEPLOYMENT_ID})"
echo "==> Git HEAD: $(git rev-parse --short HEAD)"

if [[ -n "$(git status --porcelain=v1)" ]]; then
  echo "" >&2
  echo "error: working tree is dirty; Forgejo seeding snapshots git HEAD and will ignore these changes" >&2
  echo "" >&2
  git status --porcelain=v1 >&2 || true
  echo "" >&2
  echo "Fix: commit changes (or clean the tree) before bootstrapping/seeding." >&2
  exit 1
fi

# Render drift checks (repo-only).
#
# Keep this list focused on DeploymentConfig-driven renderers and committed render outputs;
# do not run the full CI suite from bootstrap.
run ./tests/scripts/validate-deployment-config.sh
run ./tests/scripts/validate-loki-limits-controller-cutover.sh
run ./tests/scripts/validate-certificates-ingress-controller-cutover.sh
run ./tests/scripts/validate-istio-gateway.sh
run ./tests/scripts/validate-ingress-adjacent-controller-cutover.sh
run ./tests/scripts/validate-dns-wiring-controller-cutover.sh
run ./tests/scripts/validate-platform-apps-controller.sh

echo ""
echo "PASS: GitOps seed preflight completed"
