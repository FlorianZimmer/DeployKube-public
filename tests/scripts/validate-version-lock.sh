#!/usr/bin/env bash
# validate-version-lock.sh - Validate the curated machine-readable version lock against repo pin sites.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

lock_file="versions.lock.yaml"

failures=0
checked_components=0
checked_references=0

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

template_value() {
  local template="$1"
  local version="$2"
  printf '%s' "${template//__VERSION__/${version}}"
}

require_cmd jq
require_cmd rg
require_cmd yq

if [[ ! -f "${lock_file}" ]]; then
  echo "error: missing ${lock_file}" >&2
  exit 1
fi

echo "==> Validating curated version lock"
echo "lock: ${lock_file}"

lock_json="$(yq -o=json '.' "${lock_file}")"

class_count="$(printf '%s' "${lock_json}" | jq '.classes | length')"
component_count="$(printf '%s' "${lock_json}" | jq '.components | length')"

if [[ "${class_count}" -eq 0 ]]; then
  fail "versions.lock.yaml must define at least one class"
fi
if [[ "${component_count}" -eq 0 ]]; then
  fail "versions.lock.yaml must define at least one component"
fi

duplicate_classes="$(printf '%s' "${lock_json}" | jq -r '.classes | group_by(.id)[] | select(length > 1) | .[0].id')"
if [[ -n "${duplicate_classes}" ]]; then
  while IFS= read -r class_id; do
    [[ -z "${class_id}" ]] && continue
    fail "duplicate class id: ${class_id}"
  done <<<"${duplicate_classes}"
fi

duplicate_components="$(printf '%s' "${lock_json}" | jq -r '.components | group_by(.id)[] | select(length > 1) | .[0].id')"
if [[ -n "${duplicate_components}" ]]; then
  while IFS= read -r component_id; do
    [[ -z "${component_id}" ]] && continue
    fail "duplicate component id: ${component_id}"
  done <<<"${duplicate_components}"
fi

mapfile -t components < <(printf '%s' "${lock_json}" | jq -c '.components[]')

for component in "${components[@]}"; do
  component_id="$(printf '%s' "${component}" | jq -r '.id')"
  class_id="$(printf '%s' "${component}" | jq -r '.class')"
  version="$(printf '%s' "${component}" | jq -r '.version')"

  checked_components=$((checked_components + 1))

  if ! printf '%s' "${lock_json}" | jq -e --arg class_id "${class_id}" '.classes[] | select(.id == $class_id)' >/dev/null 2>&1; then
    fail "${component_id}: references unknown class '${class_id}'"
  fi

  ref_count="$(printf '%s' "${component}" | jq '.references | length')"
  if [[ "${ref_count}" -eq 0 ]]; then
    fail "${component_id}: must define at least one reference"
    continue
  fi

  mapfile -t references < <(printf '%s' "${component}" | jq -c '.references[]')
  for reference in "${references[@]}"; do
    ref_type="$(printf '%s' "${reference}" | jq -r '.type')"
    ref_path="$(printf '%s' "${reference}" | jq -r '.path')"

    checked_references=$((checked_references + 1))

    if [[ ! -f "${ref_path}" ]]; then
      fail "${component_id}: missing referenced file ${ref_path}"
      continue
    fi

    case "${ref_type}" in
      yaml_scalar)
        selector="$(printf '%s' "${reference}" | jq -r '.selector')"
        actual="$(yq -r "${selector}" "${ref_path}")"
        if [[ "${actual}" != "${version}" ]]; then
          fail "${component_id}: ${ref_path} selector ${selector} expected '${version}', got '${actual}'"
        fi
        ;;
      literal_fragment)
        template="$(printf '%s' "${reference}" | jq -r '.template')"
        expected="$(template_value "${template}" "${version}")"
        if ! rg -n -F -m1 -- "${expected}" "${ref_path}" >/dev/null 2>&1; then
          fail "${component_id}: ${ref_path} missing fragment '${expected}'"
        fi
        ;;
      *)
        fail "${component_id}: unsupported reference type '${ref_type}'"
        ;;
    esac
  done
done

echo ""
echo "==> Summary"
echo "classes:     ${class_count}"
echo "components:  ${checked_components}"
echo "references:  ${checked_references}"

if [[ "${failures}" -ne 0 ]]; then
  echo "curated version lock validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "curated version lock validation PASSED"
