#!/usr/bin/env bash
# validate-supply-chain-pinning.sh - Tier-0 pinning policy lint
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

policy_file="tests/fixtures/supply-chain-tier0-pinning.tsv"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

failures=0
checked=0
pins=0
exceptions=0
today="$(date -u +%Y-%m-%d)"

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

require_cmd rg

if [[ ! -f "${policy_file}" ]]; then
  echo "error: missing policy fixture ${policy_file}" >&2
  exit 1
fi

echo "==> Validating tier-0 supply-chain pinning policy"
echo "policy: ${policy_file}"
echo "date:   ${today}"

mapfile -t rows < "${policy_file}"

for idx in "${!rows[@]}"; do
  line_no=$((idx + 1))
  line="${rows[$idx]}"

  if [[ -z "${line//[[:space:]]/}" ]]; then
    continue
  fi
  if [[ "${line}" == \#* ]]; then
    continue
  fi

  checked=$((checked + 1))

  IFS=$'\t' read -r component_id rule_type file_path regex expires tracker_ref note <<<"${line}"

  if [[ -z "${component_id}" || -z "${rule_type}" || -z "${file_path}" || -z "${regex}" || -z "${tracker_ref}" ]]; then
    fail "line ${line_no}: expected tab-separated fields component_id/rule_type/file_path/regex/expires/tracker_ref/note"
    continue
  fi

  if [[ ! -f "${file_path}" ]]; then
    fail "line ${line_no}: missing file for ${component_id}: ${file_path}"
    continue
  fi

  if ! rg -n -m1 -e "${regex}" "${file_path}" >/dev/null 2>&1; then
    fail "line ${line_no}: pattern not found for ${component_id} in ${file_path} (regex: ${regex})"
  fi

  case "${rule_type}" in
    pin)
      pins=$((pins + 1))
      if [[ "${expires}" != "-" ]]; then
        fail "line ${line_no}: pin row for ${component_id} must set expires to '-'"
      fi
      ;;
    exception)
      exceptions=$((exceptions + 1))
      if [[ -z "${expires}" || ! "${expires}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        fail "line ${line_no}: exception ${component_id} requires expires in YYYY-MM-DD format"
        continue
      fi
      if [[ "${expires}" < "${today}" ]]; then
        fail "line ${line_no}: exception ${component_id} expired on ${expires} (today ${today})"
      fi
      ;;
    *)
      fail "line ${line_no}: unsupported rule_type '${rule_type}' for ${component_id} (expected pin|exception)"
      ;;
  esac
done

if [[ "${checked}" -eq 0 ]]; then
  fail "policy fixture had no data rows"
fi
if [[ "${pins}" -eq 0 ]]; then
  fail "policy fixture must contain at least one pin row"
fi

echo ""
echo "==> Summary"
echo "rows checked: ${checked}"
echo "pin rows:     ${pins}"
echo "exceptions:   ${exceptions}"

if [[ "${failures}" -ne 0 ]]; then
  echo "tier-0 supply-chain pinning validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tier-0 supply-chain pinning validation PASSED"
