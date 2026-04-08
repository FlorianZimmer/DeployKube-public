#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/task-close.sh <task-branch> [--delete-remote] [main-branch]

Removes the worktree for a task branch and deletes the local branch (only if merged).

Options:
  --delete-remote   Also delete the remote branch on origin (after verifying merged).
  main-branch       Defaults to 'main'.
EOF
}

task_branch="${1:-}"
delete_remote="false"
main_branch="main"

if [[ -z "${task_branch}" ]]; then
  usage
  exit 2
fi

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-remote)
      delete_remote="true"
      shift
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      main_branch="$1"
      shift
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"

git -C "${repo_root}" rev-parse --verify "${main_branch}" >/dev/null 2>&1 || {
  echo "ERROR: main branch not found: ${main_branch}" >&2
  exit 1
}

git -C "${repo_root}" rev-parse --verify "${task_branch}" >/dev/null 2>&1 || {
  echo "ERROR: task branch not found: ${task_branch}" >&2
  exit 1
}

if ! git -C "${repo_root}" merge-base --is-ancestor "${task_branch}" "${main_branch}"; then
  echo "ERROR: ${task_branch} is not merged into ${main_branch}; refusing to delete worktree/branch." >&2
  exit 1
fi

worktree_path="$(
  git -C "${repo_root}" worktree list --porcelain \
    | awk -v target="refs/heads/${task_branch}" '
      $1=="worktree"{path=$2}
      $1=="branch" && $2==target{print path}
    '
)"

if [[ -n "${worktree_path}" ]]; then
  if [[ -n "$(git -C "${worktree_path}" status --porcelain=v1)" ]]; then
    echo "ERROR: worktree is dirty (${worktree_path}); checkpoint before closing." >&2
    exit 1
  fi

  git -C "${repo_root}" worktree remove "${worktree_path}"
  echo "Removed worktree: ${worktree_path}"
else
  echo "No worktree found for ${task_branch}; deleting branch only."
fi

git -C "${repo_root}" branch -d "${task_branch}"
echo "Deleted local branch: ${task_branch}"

if [[ "${delete_remote}" == "true" ]]; then
  if git -C "${repo_root}" ls-remote --exit-code --heads origin "${task_branch}" >/dev/null 2>&1; then
    git -C "${repo_root}" push origin --delete "${task_branch}"
    echo "Deleted remote branch: origin/${task_branch}"
  else
    echo "Remote branch not found: origin/${task_branch}"
  fi
fi

