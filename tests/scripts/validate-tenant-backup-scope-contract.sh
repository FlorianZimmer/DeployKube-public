#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v yq >/dev/null 2>&1; then
  echo "error: yq not found (needed to parse YAML)" >&2
  exit 1
fi

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

mapfile -t yaml_files < <(
  find platform/gitops -type f -name '*.yaml' \
    -not -path '*/charts/*' \
    -not -path '*/helm/charts/*' \
    -not -path '*/templates/*' \
    | sort
)

if [ "${#yaml_files[@]}" -eq 0 ]; then
  echo "no YAML files found under platform/gitops (unexpected)" >&2
  exit 1
fi

for file in "${yaml_files[@]}"; do
  ns_lines="$(
    yq eval -r '
      select(has("apiVersion") and has("kind") and .apiVersion == "v1" and .kind == "Namespace") |
      [
        (.metadata.name // ""),
        (.metadata.labels."darksite.cloud/rbac-profile" // ""),
        (.metadata.labels."darksite.cloud/backup-scope" // "")
      ] | @tsv
    ' "${file}"
  )" || {
    fail "${file}: yq parse failed"
    continue
  }

  while IFS=$'\t' read -r ns_name rbac_profile backup_scope; do
    [ -n "${ns_name}" ] || continue
    [ -n "${backup_scope}" ] || continue

    if [ "${backup_scope}" != "enabled" ]; then
      fail "${file}: Namespace/${ns_name} darksite.cloud/backup-scope='${backup_scope}' (expected 'enabled')"
      continue
    fi

    if [ "${rbac_profile}" != "tenant" ]; then
      fail "${file}: Namespace/${ns_name} darksite.cloud/backup-scope=enabled requires darksite.cloud/rbac-profile=tenant (got '${rbac_profile:-<unset>}')"
      continue
    fi
  done <<<"${ns_lines}"
done

if [ "${failures}" -ne 0 ]; then
  echo "" >&2
  echo "tenant backup-scope contract validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant backup-scope contract validation PASSED"
