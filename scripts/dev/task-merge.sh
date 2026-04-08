#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/dev/task-merge.sh <task-branch> [main-branch] [--keep] [--delete-remote]

Merges a task branch into main and pushes main to origin.
Stops on conflicts (manual resolution required).

By default, the task is closed after a successful merge:
  - remove its worktree (if any)
  - delete the local branch

Use --keep to skip the auto-close step.
EOF
}

repo_root="$(git rev-parse --show-toplevel)"

hooks_path="$(git -C "${repo_root}" config --get core.hooksPath 2>/dev/null || true)"
if [[ "${hooks_path}" != ".githooks" ]]; then
  "${repo_root}/scripts/dev/setup-githooks.sh" >/dev/null
fi

task_branch=""
main_branch="main"
auto_close="true"
delete_remote="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      auto_close="false"
      shift
      ;;
    --delete-remote)
      delete_remote="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [[ -z "${task_branch}" ]]; then
        task_branch="$1"
        shift
      elif [[ "${main_branch}" == "main" ]]; then
        main_branch="$1"
        shift
      else
        usage
        exit 2
      fi
      ;;
  esac
done

if [[ -z "${task_branch}" ]]; then
  usage
  exit 2
fi

git -C "${repo_root}" rev-parse --verify "${task_branch}" >/dev/null 2>&1 || {
  echo "ERROR: branch not found: ${task_branch}" >&2
  exit 1
}

git -C "${repo_root}" rev-parse --verify "${main_branch}" >/dev/null 2>&1 || {
  echo "ERROR: main branch not found: ${main_branch}" >&2
  exit 1
}

main_worktree_path="$(
  git -C "${repo_root}" worktree list --porcelain \
    | awk -v target="refs/heads/${main_branch}" '
      $1=="worktree"{path=$2}
      $1=="branch" && $2==target{print path}
    '
)"
if [[ -z "${main_worktree_path}" ]]; then
  main_worktree_path="${repo_root}"
fi

if [[ -n "$(git -C "${main_worktree_path}" status --porcelain=v1)" ]]; then
  echo "ERROR: main worktree is dirty (${main_worktree_path}); commit/checkpoint first." >&2
  exit 1
fi

git -C "${main_worktree_path}" switch "${main_branch}"
git -C "${main_worktree_path}" pull --ff-only
DK_ALLOW_MAIN_COMMIT=1 git -C "${main_worktree_path}" merge --no-ff "${task_branch}" -m "Merge branch '${task_branch}'"
DK_ALLOW_MAIN_PUSH=1 git -C "${main_worktree_path}" push origin "${main_branch}"

echo "Merged and pushed: ${task_branch} -> ${main_branch}"

if [[ "${auto_close}" == "true" ]]; then
  close_args=("${task_branch}" "${main_branch}")
  if [[ "${delete_remote}" == "true" ]]; then
    close_args=("${task_branch}" "--delete-remote" "${main_branch}")
  fi

  "${repo_root}/scripts/dev/task-close.sh" "${close_args[@]}"
fi
