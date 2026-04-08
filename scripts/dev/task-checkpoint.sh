#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/dev/task-checkpoint.sh -m "<commit message>"

Stages all changes, creates a commit, and pushes the current branch to origin.

Why:
  - Makes work durable (no more “what’s in the stash/dirty worktree?”).
  - Makes “newer than main” visible via the commit graph.
EOF
}

message=""
while getopts ":m:h" opt; do
  case "${opt}" in
    m) message="${OPTARG}" ;;
    h)
      usage
      exit 0
      ;;
    \?)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${message}" ]]; then
  usage
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "${repo_root}" branch --show-current)"

if [[ -z "${branch}" ]]; then
  echo "ERROR: not on a branch (detached HEAD); refusing to checkpoint." >&2
  exit 1
fi

hooks_path="$(git -C "${repo_root}" config --get core.hooksPath 2>/dev/null || true)"
if [[ "${hooks_path}" != ".githooks" ]]; then
  "${repo_root}/scripts/dev/setup-githooks.sh" >/dev/null
fi

if [[ "${branch}" == "main" ]]; then
  echo "ERROR: refusing to checkpoint on 'main'. Create a task worktree first (./scripts/dev/task-new.sh <slug> origin/main)." >&2
  exit 1
fi

git -C "${repo_root}" add -A

if git -C "${repo_root}" diff --cached --quiet; then
  echo "No staged changes; nothing to commit."
  exit 0
fi

git -C "${repo_root}" commit -m "${message}"
git -C "${repo_root}" push -u origin HEAD

echo "Checkpoint pushed: ${branch}"
