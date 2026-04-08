#!/usr/bin/env bash
# validate-version-lock-component-coverage.sh - Ensure each catalog row declares explicit version-lock coverage status.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

catalog_file="docs/ai/prompt-templates/component-assessment/component-catalog.tsv"
lock_file="versions.lock.yaml"
gap_marker="DK:VERSION_LOCK_GAP_TRACKED"
gap_line='- `versions.lock.yaml` does not yet include this component. Keep this gap tracked here until a curated entry is added.'

failures=0
checked_components=0
direct_components=0
shared_components=0
none_components=0
gap_components=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

require_cmd jq
require_cmd rg
require_cmd yq

if [[ ! -f "${catalog_file}" ]]; then
  echo "error: missing ${catalog_file}" >&2
  exit 1
fi
if [[ ! -f "${lock_file}" ]]; then
  echo "error: missing ${lock_file}" >&2
  exit 1
fi

echo "==> Validating version-lock component coverage"
echo "catalog: ${catalog_file}"
echo "lock:    ${lock_file}"

lock_json="$(yq -o=json '.' "${lock_file}")"

declare -A known_lock_ids=()
declare -A lock_owner_slugs=()

while IFS=$'\t' read -r lock_id owner_slugs_csv; do
  [[ -z "${lock_id}" ]] && continue
  known_lock_ids["${lock_id}"]=1
  lock_owner_slugs["${lock_id}"]="${owner_slugs_csv}"
done < <(printf '%s' "${lock_json}" | jq -r '.components[] | [.id, (.tracks_issue_slugs // [] | join(","))] | @tsv')

validate_refs() {
  local component_id="$1"
  local refs_csv="$2"
  local mode="$3"

  if [[ -z "${refs_csv}" ]]; then
    if [[ "${mode}" == "direct" || "${mode}" == "shared" ]]; then
      fail "${component_id}: version_lock_refs_csv must be non-empty for mode '${mode}'"
    fi
    return 0
  fi

  IFS=',' read -r -a refs <<<"${refs_csv}"
  for ref in "${refs[@]}"; do
    [[ -n "${ref}" ]] || continue
    if [[ -z "${known_lock_ids[${ref}]:-}" ]]; then
      fail "${component_id}: version_lock_refs_csv references unknown lock id '${ref}'"
    fi
  done
}

direct_owns_issue() {
  local issue_slug="$1"
  local refs_csv="$2"
  local ref

  IFS=',' read -r -a refs <<<"${refs_csv}"
  for ref in "${refs[@]}"; do
    [[ -n "${ref}" ]] || continue
    if printf '%s\n' "${lock_owner_slugs[${ref}]}" | tr ',' '\n' | rg -x --fixed-strings "${issue_slug}" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

while IFS=$'\037' read -r component_id enabled issue_slug primary_path context_paths_csv notes target_scope version_lock_mode version_lock_refs_csv; do
  if [[ "${component_id}" == "component_id" ]]; then
    continue
  fi
  if [[ "${enabled}" != "true" ]]; then
    continue
  fi
  if [[ -z "${target_scope}" ]]; then
    target_scope="component"
  fi
  if [[ "${target_scope}" != "component" ]]; then
    continue
  fi

  checked_components=$((checked_components + 1))
  issue_file="docs/component-issues/${issue_slug}.md"

  if [[ ! -f "${issue_file}" ]]; then
    fail "${component_id}: missing issue tracker ${issue_file}"
    continue
  fi

  if [[ -z "${version_lock_mode}" ]]; then
    fail "${component_id}: missing version_lock_mode"
    continue
  fi

  case "${version_lock_mode}" in
    direct)
      direct_components=$((direct_components + 1))
      validate_refs "${component_id}" "${version_lock_refs_csv}" "${version_lock_mode}"
      if ! direct_owns_issue "${issue_slug}" "${version_lock_refs_csv}"; then
        fail "${component_id}: mode 'direct' requires at least one referenced lock entry to own issue slug '${issue_slug}' via tracks_issue_slugs"
      fi
      if rg -n -F -m1 "${gap_marker}" "${issue_file}" >/dev/null 2>&1; then
        fail "${component_id}: ${issue_file} still carries ${gap_marker} but the component is marked direct"
      fi
      ;;
    shared)
      shared_components=$((shared_components + 1))
      validate_refs "${component_id}" "${version_lock_refs_csv}" "${version_lock_mode}"
      if rg -n -F -m1 "${gap_marker}" "${issue_file}" >/dev/null 2>&1; then
        fail "${component_id}: ${issue_file} still carries ${gap_marker} but the component is marked shared"
      fi
      ;;
    none)
      none_components=$((none_components + 1))
      if [[ -n "${version_lock_refs_csv}" ]]; then
        fail "${component_id}: mode 'none' must leave version_lock_refs_csv empty"
      fi
      if rg -n -F -m1 "${gap_marker}" "${issue_file}" >/dev/null 2>&1; then
        fail "${component_id}: ${issue_file} still carries ${gap_marker} but the component is marked none"
      fi
      ;;
    gap)
      gap_components=$((gap_components + 1))
      validate_refs "${component_id}" "${version_lock_refs_csv}" "${version_lock_mode}"
      if ! rg -n -F -m1 "${gap_marker}" "${issue_file}" >/dev/null 2>&1; then
        fail "${component_id}: ${issue_file} is marked gap but does not contain ${gap_marker}"
        continue
      fi
      if ! rg -n -F -m1 -- "${gap_line}" "${issue_file}" >/dev/null 2>&1; then
        fail "${component_id}: ${issue_file} has ${gap_marker} but is missing the standard gap-tracking line"
      fi
      ;;
    *)
      fail "${component_id}: invalid version_lock_mode '${version_lock_mode}' (expected direct|shared|none|gap)"
      ;;
  esac
done < <(
  awk -F'\t' '
    BEGIN { OFS = "\037" }
    NF == 0 || $1 ~ /^#/ { next }
    { print $1, $2, $3, $4, $5, $6, $7, $8, $9 }
  ' "${catalog_file}"
)

echo ""
echo "==> Summary"
echo "components checked: ${checked_components}"
echo "direct:             ${direct_components}"
echo "shared:             ${shared_components}"
echo "none:               ${none_components}"
echo "gap:                ${gap_components}"

if [[ "${failures}" -ne 0 ]]; then
  echo "version-lock component coverage FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "version-lock component coverage PASSED"
