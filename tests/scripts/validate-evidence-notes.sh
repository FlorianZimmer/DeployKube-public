#!/usr/bin/env bash
# validate-evidence-notes.sh - Lint evidence notes (v1 only)
#
# This script only validates evidence notes that opt in with:
#   EvidenceFormat: v1
#
# Older evidence notes are intentionally skipped.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

evidence_dir="docs/evidence"
failures=0
checked=0
skipped=0

escape_regex_literal() {
  # Escape regex metacharacters so environment IDs like "proxmox-talos" remain literal.
  printf '%s' "$1" | sed -E 's/[][(){}.^$|?*+\\\\]/\\\\&/g'
}

allowed_env_alt="$(
  {
    find "platform/gitops/apps/environments" -mindepth 1 -maxdepth 1 -type d -print0 \
      | xargs -0 -n 1 basename \
      | sort
    echo "repo-only"
  } | while IFS= read -r env_id; do
    escape_regex_literal "${env_id}"
    echo "|"
  done | tr -d '\n' | sed 's/|$//'
)"

echo "==> Validating evidence notes (EvidenceFormat: v1)"

if [ ! -d "${evidence_dir}" ]; then
  echo "error: missing ${evidence_dir}" >&2
  exit 1
fi

mapfile -t evidence_files < <(
  rg --files "${evidence_dir}" -g '*.md' | rg -v '/README\.md$' | sort
)

require_grep() {
  local file="$1"
  local label="$2"
  local pattern="$3"
  if ! rg -n -q "${pattern}" "${file}"; then
    echo "  missing: ${label} (${pattern})" >&2
    return 1
  fi
  return 0
}

require_regex() {
  local file="$1"
  local label="$2"
  local regex="$3"
  if ! rg -n -q --regexp "${regex}" "${file}"; then
    echo "  missing: ${label} (${regex})" >&2
    return 1
  fi
  return 0
}

require_any_regex() {
  local file="$1"
  local label="$2"
  shift 2
  local regex
  for regex in "$@"; do
    if rg -n -q --regexp "${regex}" "${file}"; then
      return 0
    fi
  done
  echo "  missing: ${label} (expected one of ${*})" >&2
  return 1
}

for f in "${evidence_files[@]}"; do
  if ! rg -n -q '^EvidenceFormat: v1$' "${f}"; then
    skipped=$((skipped + 1))
    continue
  fi

checked=$((checked + 1))
echo ""
echo "==> ${f}"

local_fail=0

require_grep "${f}" "EvidenceFormat v1" '^EvidenceFormat: v1$' || local_fail=1
  require_regex "${f}" "Date" '^Date:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$' || local_fail=1
  require_regex "${f}" "Environment" "^Environment:[[:space:]]+(${allowed_env_alt})([[:space:]].*)?$" || local_fail=1

  require_any_regex "${f}" "Scope / ground truth" \
    '^(##[[:space:]]+)?Scope / ground truth(:)?[[:space:]]*$' || local_fail=1
  require_regex "${f}" "Scope bullets" '^- .+' || local_fail=1

  # Git/Argo sections are accepted in the legacy v1 template and optional in newer v1 notes.
  if rg -n -q '^Git:$' "${f}"; then
    require_regex "${f}" "Git commit" '^- Commit: .+' || local_fail=1
  fi

  if rg -n -q '^Argo:$' "${f}"; then
    require_regex "${f}" "Argo root app" '^- Root app: .+' || local_fail=1
    require_regex "${f}" "Argo sync/health" '^- Sync/Health: .+' || local_fail=1
    require_regex "${f}" "Argo revision" '^- Revision: .+' || local_fail=1
  fi

  require_grep "${f}" "What changed heading" '^## What changed$' || local_fail=1
  require_any_regex "${f}" "Commands heading" \
    '^## Commands / outputs$' \
    '^## Validation commands$' || local_fail=1
  require_grep "${f}" "Commands block" '^```bash$' || local_fail=1
  require_any_regex "${f}" "Output label" '^Output:$' '^Result:$' || local_fail=1
  require_grep "${f}" "Output block" '^```text$' || local_fail=1

if [ "${local_fail}" -ne 0 ]; then
  failures=$((failures + 1))
  echo "FAIL: evidence note lint failed for ${f}" >&2
else
  echo "PASS"
fi
done

echo ""
echo "==> Summary"
echo "- Checked v1 notes: ${checked}"
echo "- Skipped non-v1 notes: ${skipped}"

if [ "${failures}" -ne 0 ]; then
  echo "" >&2
  echo "evidence note lint FAILED (${failures} file(s))" >&2
  exit 1
fi

echo "evidence note lint PASSED"
