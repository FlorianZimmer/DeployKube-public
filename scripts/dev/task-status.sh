#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/dev/task-status.sh [--fetch] [main-branch]

Shows:
  - worktrees + dirty state
  - ahead/behind vs main
  - main vs its upstream (e.g., origin/main)

Use --fetch to refresh remote-tracking refs first.
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
main_branch="main"
fetch="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fetch)
      fetch="true"
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
      if [[ "${main_branch}" == "main" ]]; then
        main_branch="$1"
        shift
      else
        usage
        exit 2
      fi
      ;;
  esac
done

if ! git -C "${repo_root}" rev-parse --verify "${main_branch}" >/dev/null 2>&1; then
  echo "ERROR: main branch not found: ${main_branch}" >&2
  exit 1
fi

if [[ "${fetch}" == "true" ]]; then
  git -C "${repo_root}" fetch --prune origin >/dev/null 2>&1 || {
    echo "WARNING: git fetch failed; continuing with existing refs." >&2
  }
fi

stash_count="$(git -C "${repo_root}" stash list | wc -l | tr -d ' ')"
hooks_path="$(git -C "${repo_root}" config --get core.hooksPath 2>/dev/null || true)"

upstream_ref="$(git -C "${repo_root}" rev-parse --abbrev-ref "${main_branch}@{upstream}" 2>/dev/null || true)"
if [[ -z "${upstream_ref}" ]] && git -C "${repo_root}" rev-parse --verify "origin/${main_branch}" >/dev/null 2>&1; then
  upstream_ref="origin/${main_branch}"
fi

upstream_status="(no upstream)"
if [[ -n "${upstream_ref}" ]] && git -C "${repo_root}" rev-parse --verify "${upstream_ref}" >/dev/null 2>&1; then
  read -r upstream_ahead upstream_behind < <(
    git -C "${repo_root}" rev-list --left-right --count "${main_branch}...${upstream_ref}"
  )
  upstream_status="ahead=${upstream_ahead} behind=${upstream_behind} (${upstream_ref})"
fi

echo "Repo: ${repo_root}"
echo "Main: ${main_branch}"
echo "Upstream: ${upstream_status}"
echo "Stashes: ${stash_count}"
if [[ "${hooks_path}" != ".githooks" ]]; then
  echo "Hooks: WARNING core.hooksPath not set (run ./scripts/dev/setup-githooks.sh)"
else
  echo "Hooks: ${hooks_path}"
fi
echo

current_path=""
current_head=""
current_branch_ref=""

flush() {
  if [[ -z "${current_path}" ]]; then
    return 0
  fi

local branch_name="(detached)"
if [[ -n "${current_branch_ref}" ]]; then
  branch_name="${current_branch_ref#refs/heads/}"
fi

local dirty="clean"
if [[ -n "$(git -C "${current_path}" status --porcelain=v1)" ]]; then
  dirty="DIRTY"
fi

local ahead="?"
local behind="?"
if [[ "${branch_name}" != "(detached)" ]]; then
  ahead="$(git -C "${repo_root}" rev-list --count "${main_branch}..${branch_name}" 2>/dev/null || echo "?")"
  behind="$(git -C "${repo_root}" rev-list --count "${branch_name}..${main_branch}" 2>/dev/null || echo "?")"
fi

printf '%s\n' "${current_path}"
printf '  branch: %s\n' "${branch_name}"
printf '  head:   %s\n' "${current_head:0:12}"
printf '  status: %s\n' "${dirty}"
printf '  main:   ahead=%s behind=%s\n' "${ahead}" "${behind}"
echo

current_path=""
current_head=""
current_branch_ref=""
}

while IFS= read -r line; do
  case "${line}" in
    worktree\ *)
      flush
      current_path="${line#worktree }"
      ;;
    HEAD\ *)
      current_head="${line#HEAD }"
      ;;
    branch\ *)
      current_branch_ref="${line#branch }"
      ;;
    *)
      ;;
  esac
done < <(git -C "${repo_root}" worktree list --porcelain)
flush

if [[ "${stash_count}" != "0" ]]; then
  echo "NOTE: non-empty stash list means there is hidden work outside the commit graph."
  echo "      Recommendation: apply → checkpoint commit → push, then delete the stash."
fi
