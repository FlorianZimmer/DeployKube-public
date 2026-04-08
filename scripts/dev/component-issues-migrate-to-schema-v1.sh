#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/component-issues-migrate-to-schema-v1.sh [--apply] [--today YYYY-MM-DD] [--force-from-head]

Migrates legacy `docs/component-issues/*.md` into the v1 machine-readable findings schema:
- adds `DK:COMPONENT_ISSUES_FINDINGS_V1` JSONL block (best-effort from legacy `## Open*` section)
- normalizes/creates an `## Open` section containing the `DK:COMPONENT_ISSUES_OPEN_RENDER_V1` block
  (rendered deterministically without LLM to avoid token spend)

Idempotent:
- files that already contain a findings block are skipped.

Notes:
- This migration is conservative and best-effort; it only encodes legacy OPEN items into findings.
- Resolved history/evidence remains as-is.
EOF
}

apply="false"
today="$(date -u +%Y-%m-%d)"
force_from_head="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply="true"
      shift
      ;;
    --today)
      today="$2"
      shift 2
      ;;
    --force-from-head)
      force_from_head="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
args=(--repo-root "${repo_root}" --today "${today}")
if [[ "${apply}" == "true" ]]; then
  args+=(--apply)
fi
if [[ "${force_from_head}" == "true" ]]; then
  args+=(--force-from-head)
fi

python3 "${repo_root}/scripts/dev/component-issues-migrate-to-schema-v1.py" "${args[@]}"
