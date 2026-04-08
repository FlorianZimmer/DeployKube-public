#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/dev/setup-githooks.sh

Configures this repo to use versioned hooks from '.githooks/' by setting:
  git config core.hooksPath .githooks

Currently installed hooks:
  - pre-commit: block direct commits on main (guardrail)
  - pre-push: block pushes to origin/main (guardrail)
  - post-merge: auto-prune merged task worktrees
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"

if [[ ! -d "${repo_root}/.githooks" ]]; then
  echo "ERROR: .githooks directory not found in repo." >&2
  exit 1
fi

chmod +x "${repo_root}/.githooks/"* 2>/dev/null || true
git -C "${repo_root}" config core.hooksPath .githooks

echo "Configured core.hooksPath=.githooks for ${repo_root}"
