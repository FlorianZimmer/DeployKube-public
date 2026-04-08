#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/dev/component-assessment-catalog-check.sh [--catalog <path>] [--list-enabled]

Validates the component assessment catalog:
  - required columns are present
  - component ids are unique
  - primary/context paths exist (file or directory)
  - enabled rows point at existing docs/component-issues/<issue_slug>.md
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
catalog_path="${repo_root}/docs/ai/prompt-templates/component-assessment/component-catalog.tsv"
list_enabled="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog)
      catalog_path="$2"
      shift 2
      ;;
    --list-enabled)
      list_enabled="true"
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

if [[ ! -f "${catalog_path}" ]]; then
  echo "ERROR: catalog not found: ${catalog_path}" >&2
  exit 1
fi

declare -A seen_ids=()
declare -a enabled_ids=()
errors=0
total_rows=0
enabled_rows=0
disabled_rows=0

while IFS=$'\037' read -r component_id enabled issue_slug primary_path context_paths_csv notes target_scope version_lock_mode version_lock_refs_csv; do
  [[ -z "${component_id}" ]] && continue

  total_rows=$((total_rows + 1))

  if [[ -n "${seen_ids[${component_id}]:-}" ]]; then
    echo "ERROR: duplicate component_id '${component_id}' in ${catalog_path}" >&2
    errors=$((errors + 1))
    continue
  fi
  seen_ids["${component_id}"]=1

  if [[ "${enabled}" != "true" && "${enabled}" != "false" ]]; then
    echo "ERROR: component '${component_id}' has invalid enabled flag '${enabled}' (expected true|false)" >&2
    errors=$((errors + 1))
  fi

  if [[ -z "${target_scope}" ]]; then
    target_scope="component"
  fi
  if [[ "${target_scope}" != "component" && "${target_scope}" != "project" ]]; then
    echo "ERROR: component '${component_id}' has invalid target_scope '${target_scope}' (expected component|project)" >&2
    errors=$((errors + 1))
  fi

  if [[ -z "${version_lock_mode}" ]]; then
    echo "ERROR: component '${component_id}' has empty version_lock_mode" >&2
    errors=$((errors + 1))
  elif [[ "${version_lock_mode}" != "direct" && "${version_lock_mode}" != "shared" && "${version_lock_mode}" != "none" && "${version_lock_mode}" != "gap" ]]; then
    echo "ERROR: component '${component_id}' has invalid version_lock_mode '${version_lock_mode}' (expected direct|shared|none|gap)" >&2
    errors=$((errors + 1))
  fi

  if [[ "${version_lock_mode}" == "direct" || "${version_lock_mode}" == "shared" ]]; then
    if [[ -z "${version_lock_refs_csv}" ]]; then
      echo "ERROR: component '${component_id}' must set version_lock_refs_csv for mode '${version_lock_mode}'" >&2
      errors=$((errors + 1))
    fi
  fi

  if [[ "${version_lock_mode}" == "none" && -n "${version_lock_refs_csv}" ]]; then
    echo "ERROR: component '${component_id}' must leave version_lock_refs_csv empty for mode 'none'" >&2
    errors=$((errors + 1))
  fi

  if [[ -z "${primary_path}" ]]; then
    echo "ERROR: component '${component_id}' has empty primary_path" >&2
    errors=$((errors + 1))
  elif [[ ! -e "${repo_root}/${primary_path}" ]]; then
    echo "ERROR: component '${component_id}' primary_path not found: ${primary_path}" >&2
    errors=$((errors + 1))
  fi

  if [[ -z "${context_paths_csv}" ]]; then
    echo "ERROR: component '${component_id}' has empty context_paths_csv" >&2
    errors=$((errors + 1))
  else
    IFS=',' read -r -a context_paths <<< "${context_paths_csv}"
    for p in "${context_paths[@]}"; do
      if [[ ! -e "${repo_root}/${p}" ]]; then
        echo "ERROR: component '${component_id}' context path not found: ${p}" >&2
        errors=$((errors + 1))
      fi
    done
  fi

  if [[ "${enabled}" == "true" ]]; then
    enabled_rows=$((enabled_rows + 1))
    enabled_ids+=("${component_id}")

    if [[ -z "${issue_slug}" ]]; then
      echo "ERROR: enabled component '${component_id}' has empty issue_slug" >&2
      errors=$((errors + 1))
    elif [[ ! -f "${repo_root}/docs/component-issues/${issue_slug}.md" ]]; then
      echo "ERROR: enabled component '${component_id}' issue tracker missing: docs/component-issues/${issue_slug}.md" >&2
      errors=$((errors + 1))
    fi
  else
    disabled_rows=$((disabled_rows + 1))
  fi
done < <(
  awk -F'\t' '
    BEGIN { OFS = "\037" }
    NF == 0 || $1 ~ /^#/ { next }
    { print $1, $2, $3, $4, $5, $6, $7, $8, $9 }
  ' "${catalog_path}"
)

if [[ "${list_enabled}" == "true" ]]; then
  printf '%s\n' "${enabled_ids[@]}"
fi

echo "Catalog: ${catalog_path}"
echo "Rows: ${total_rows} (enabled: ${enabled_rows}, disabled: ${disabled_rows})"

if [[ ${errors} -ne 0 ]]; then
  echo "Validation: FAILED (${errors} error(s))" >&2
  exit 1
fi

echo "Validation: OK"
