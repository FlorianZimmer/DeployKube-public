#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/dev/task-new.sh <slug> [base-branch]

Creates:
  - branch:   task/<slug>
  - worktree: ../DeployKube-<slug>

Notes:
  - Keeps work durable by isolating a task in its own worktree.
  - Fails if the current worktree is dirty (commit/checkpoint first).
EOF
}

slug="${1:-}"
base_branch="${2:-origin/main}"

if [[ -z "${slug}" ]]; then
  usage
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

hooks_path="$(git -C "${repo_root}" config --get core.hooksPath 2>/dev/null || true)"
if [[ "${hooks_path}" != ".githooks" ]]; then
  "${repo_root}/scripts/dev/setup-githooks.sh" >/dev/null
fi

if [[ "${DK_TASK_NEW_FETCH:-1}" == "1" ]]; then
  git -C "${repo_root}" fetch --prune origin >/dev/null 2>&1 || {
    echo "WARNING: git fetch failed; continuing with existing refs." >&2
  }
fi

if [[ -n "$(git -C "${repo_root}" status --porcelain=v1)" ]]; then
  echo "ERROR: current worktree has uncommitted changes; commit/checkpoint before creating a new task worktree." >&2
  exit 1
fi

sanitized_slug="$(printf '%s' "${slug}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
if [[ -z "${sanitized_slug}" ]]; then
  echo "ERROR: slug '${slug}' becomes empty after sanitization; use something like 'multitenancy-networking'." >&2
  exit 1
fi

branch="task/${sanitized_slug}"
worktree_path="$(dirname "${repo_root}")/DeployKube-${sanitized_slug}"

if git -C "${repo_root}" show-ref --verify --quiet "refs/heads/${branch}"; then
  echo "ERROR: branch already exists: ${branch}" >&2
  exit 1
fi

if [[ -e "${worktree_path}" ]]; then
  echo "ERROR: worktree path already exists: ${worktree_path}" >&2
  exit 1
fi

git -C "${repo_root}" rev-parse --verify "${base_branch}" >/dev/null 2>&1 || {
  echo "ERROR: base branch not found: ${base_branch}" >&2
  exit 1
}

if [[ "${base_branch}" == "main" ]] && git -C "${repo_root}" rev-parse --verify origin/main >/dev/null 2>&1; then
  main_sha="$(git -C "${repo_root}" rev-parse main)"
  origin_main_sha="$(git -C "${repo_root}" rev-parse origin/main)"
  if [[ "${main_sha}" != "${origin_main_sha}" && "${DK_ALLOW_DIVERGED_MAIN_BASE:-}" != "1" ]]; then
    cat >&2 <<'EOF'
ERROR: Refusing to base a new task on local 'main' because it differs from origin/main.

Fix:
  git switch main
  git pull --ff-only

Or use origin/main explicitly:
  ./scripts/dev/task-new.sh <slug> origin/main

If you really intend to base off a diverged local main, bypass explicitly:
  DK_ALLOW_DIVERGED_MAIN_BASE=1 ./scripts/dev/task-new.sh <slug> main
EOF
    exit 1
  fi
fi

git -C "${repo_root}" worktree add -b "${branch}" "${worktree_path}" "${base_branch}"

cat <<EOF
Created:
  branch:   ${branch}
  worktree: ${worktree_path}

Next:
  cd ${worktree_path}
EOF
