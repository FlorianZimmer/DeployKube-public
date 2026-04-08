#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expected_overlays=(
  mac-orbstack-single
  proxmox-talos
)

echo "==> Validating component overlay layout (repo-wide)"
echo "expected overlays: ${expected_overlays[*]}"

mapfile -t overlays_dirs < <(
  find platform/gitops/components -type d -name overlays -print | LC_ALL=C sort
)

if [[ "${#overlays_dirs[@]}" -eq 0 ]]; then
  echo "PASS (no overlays directories found)"
  exit 0
fi

check_set_equals() {
  local overlays_dir="$1"
  local base_dir="$2"

  if [[ ! -d "${base_dir}" ]]; then
    echo "FAIL: overlays dir ${overlays_dir} is missing required sibling base dir ${base_dir}" >&2
    return 1
  fi

  mapfile -t found < <(
    find "${overlays_dir}" -mindepth 1 -maxdepth 1 -type d -print \
      | sed 's|.*/||' \
      | LC_ALL=C sort
  )

  local expected
  expected="$(printf '%s\n' "${expected_overlays[@]}" | LC_ALL=C sort)"
  local got
  got="$(printf '%s\n' "${found[@]:-}" | LC_ALL=C sort)"

  if [[ "${expected}" != "${got}" ]]; then
    echo "FAIL: unexpected overlay set in ${overlays_dir}" >&2
    echo "expected:" >&2
    printf '  - %s\n' "${expected_overlays[@]}" >&2
    echo "got:" >&2
    if [[ "${#found[@]}" -eq 0 ]]; then
      echo "  (none)" >&2
    else
      printf '  - %s\n' "${found[@]}" >&2
    fi
    return 1
  fi

  return 0
}

failures=0

for overlays_dir in "${overlays_dirs[@]}"; do
  base_dir="$(dirname "${overlays_dir}")/base"
  if ! check_set_equals "${overlays_dir}" "${base_dir}"; then
    failures=$((failures + 1))
  fi
done

if [[ "${failures}" -ne 0 ]]; then
  echo "component overlay layout validation FAILED (${failures} dir(s))" >&2
  exit 1
fi

echo "PASS"
