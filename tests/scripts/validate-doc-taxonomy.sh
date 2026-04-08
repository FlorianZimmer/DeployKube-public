#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) not found" >&2
  exit 1
fi

failures=0

echo "==> evidence notes must live under docs/evidence/"
mapfile -t misplaced_evidence < <(
  rg -l "^EvidenceFormat:[[:space:]]*v1[[:space:]]*$" docs -g'*.md' -g'!docs/evidence/**' -g'!docs/templates/**' | sort
)
if [ "${#misplaced_evidence[@]}" -ne 0 ]; then
  echo "FAIL: found EvidenceFormat: v1 notes outside docs/evidence/" >&2
  printf '  - %s\n' "${misplaced_evidence[@]}" >&2
  failures=$((failures + 1))
fi

echo "==> alert runbook_url targets must exist under docs/runbooks/"
mapfile -t runbook_paths < <(
  rg -n "runbook_url:[[:space:]]*docs/" platform -g'*.yaml' \
    | sed -E 's/.*runbook_url:[[:space:]]*//' \
    | sed -E 's/[\"'\"']//g' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | sort -u
)

for p in "${runbook_paths[@]}"; do
  if [[ "${p}" == docs/toils/* ]]; then
    echo "FAIL: runbook_url points at docs/toils (use docs/runbooks): ${p}" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ "${p}" == docs/runbooks/* ]]; then
    if [ ! -f "${p}" ]; then
      echo "FAIL: runbook_url target does not exist: ${p}" >&2
      failures=$((failures + 1))
    fi
  fi
done

if [ "${failures}" -ne 0 ]; then
  exit 1
fi

echo "PASS"
