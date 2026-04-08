#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

catalog="docs/ai/prompt-templates/component-assessment/component-catalog.tsv"

usage() {
  cat >&2 <<'EOF'
Usage: ./tests/scripts/validate-component-assessment-runtime-e2e-coverage.sh

Fails when runtime E2E / release-gating workflow surfaces exist in-repo but are not
referenced by any enabled component-assessment catalog row.

Guarded surfaces:
  - .github/workflows/*mode-e2e.yml
  - .github/workflows/release-e2e-gate.yml
  - tests/scripts/e2e-*-modes-matrix.sh
  - tests/scripts/e2e-release-runtime-smokes.sh
  - scripts/release/release-tag.sh
  - scripts/release/release-gate.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) not found" >&2
  exit 1
fi

if [[ ! -f "${catalog}" ]]; then
  echo "error: missing catalog: ${catalog}" >&2
  exit 1
fi

mapfile -t required_files < <(
  {
    rg --files .github/workflows | rg '(^\.github/workflows/[^/]*mode-e2e\.yml$)|(^\.github/workflows/release-e2e-gate\.yml$)'
    rg --files tests/scripts | rg '(^tests/scripts/e2e-[^/]*-modes-matrix\.sh$)|(^tests/scripts/e2e-release-runtime-smokes\.sh$)'
    printf '%s\n' "scripts/release/release-tag.sh" "scripts/release/release-gate.sh"
  } | sort -u
)

if [[ ${#required_files[@]} -eq 0 ]]; then
  echo "FAIL: no runtime E2E / release-gating surfaces found (unexpected)" >&2
  exit 1
fi

declare -A referenced_by=()

while IFS=$'\037' read -r component_id enabled issue_slug primary_path context_paths_csv notes target_scope; do
  [[ -z "${component_id}" ]] && continue
  [[ "${enabled}" == "true" ]] || continue

  if [[ -n "${primary_path}" ]]; then
    referenced_by["${primary_path}"]+="${component_id} "
  fi

  if [[ -n "${context_paths_csv}" ]]; then
    IFS=',' read -r -a context_paths <<< "${context_paths_csv}"
    for p in "${context_paths[@]}"; do
      [[ -n "${p}" ]] || continue
      referenced_by["${p}"]+="${component_id} "
    done
  fi
done < <(
  awk -F'\t' '
    BEGIN { OFS = "\037" }
    NF == 0 || $1 ~ /^#/ { next }
    { print $1, $2, $3, $4, $5, $6, $7 }
  ' "${catalog}"
)

failures=0
for required in "${required_files[@]}"; do
  if [[ -z "${referenced_by[${required}]:-}" ]]; then
    echo "FAIL: runtime E2E / release-gating surface is not referenced by any enabled catalog row: ${required}" >&2
    failures=$((failures + 1))
  fi
done

if [[ ${failures} -ne 0 ]]; then
  echo "Hint: add the missing file(s) to docs/ai/prompt-templates/component-assessment/component-catalog.tsv" >&2
  exit 1
fi

echo "PASS: component-assessment catalog covers runtime E2E / release-gating surfaces (${#required_files[@]} files)"
