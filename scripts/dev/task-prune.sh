#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/task-prune.sh [--fetch] [--delete-remote] [main-branch]

Removes all merged task worktrees (branches under refs/heads/task/*) once they are fully merged into main.

Safety:
  - Skips dirty worktrees (no data loss).
  - Refuses to run if the main worktree is dirty.

Options:
  --fetch           Run 'git fetch origin --prune' first (useful after GitHub PR merges).
  --delete-remote   Also delete merged remote branches on origin (if present).
  main-branch       Defaults to 'main'.
EOF
}

do_fetch="false"
delete_remote="false"
main_branch="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fetch)
      do_fetch="true"
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

if [[ "${do_fetch}" == "true" ]]; then
  git -C "${repo_root}" fetch origin --prune
fi

removed=0
skipped_dirty=0
skipped_unmerged=0

current_path=""
current_branch_ref=""

flush() {
  if [[ -z "${current_path}" ]]; then
    return 0
  fi

  if [[ -z "${current_branch_ref}" ]]; then
    current_path=""
    current_branch_ref=""
    return 0
  fi

  case "${current_branch_ref}" in
    refs/heads/task/*)
      ;;
    *)
      current_path=""
      current_branch_ref=""
      return 0
      ;;
  esac

  branch="${current_branch_ref#refs/heads/}"

  if git -C "${repo_root}" merge-base --is-ancestor "${branch}" "${main_branch}"; then
    if [[ -n "$(git -C "${current_path}" status --porcelain=v1)" ]]; then
      echo "SKIP (dirty worktree): ${branch} (${current_path})"
      skipped_dirty="$((skipped_dirty + 1))"
      current_path=""
      current_branch_ref=""
      return 0
    fi

    echo "Pruning merged task: ${branch} (${current_path})"
    git -C "${repo_root}" worktree remove "${current_path}"
    git -C "${repo_root}" branch -d "${branch}"

    if [[ "${delete_remote}" == "true" ]]; then
      if git -C "${repo_root}" ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
        git -C "${repo_root}" push origin --delete "${branch}"
      fi
    fi

    removed="$((removed + 1))"
  else
    skipped_unmerged="$((skipped_unmerged + 1))"
  fi

  current_path=""
  current_branch_ref=""
}

while IFS= read -r line; do
  case "${line}" in
    worktree\ *)
      flush
      current_path="${line#worktree }"
      ;;
    branch\ *)
      current_branch_ref="${line#branch }"
      ;;
    *)
      ;;
  esac
done < <(git -C "${repo_root}" worktree list --porcelain)
flush

echo "Done: removed=${removed} skipped_dirty=${skipped_dirty} skipped_unmerged=${skipped_unmerged}"

