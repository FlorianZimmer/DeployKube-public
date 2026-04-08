#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

echo "==> Validating tenant AppProject RBAC (spec.roles[].groups)"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency rg
check_dependency yq

failures=0

mapfile -t projects < <(
  rg --files "platform/gitops/apps/tenants/base" -g 'appproject-tenant-*.yaml' \
    | rg -v 'appproject-tenant-intent-' \
    | sort
)

if [[ "${#projects[@]}" -eq 0 ]]; then
  echo "error: no tenant AppProject manifests found under platform/gitops/apps/tenants/base" >&2
  exit 1
fi

for f in "${projects[@]}"; do
  name="$(yq -r '.metadata.name // ""' "${f}")"
  if [[ -z "${name}" ]]; then
    echo "FAIL: missing metadata.name: ${f}" >&2
    failures=$((failures + 1))
    continue
  fi

  org_id="$(yq -r '.metadata.labels["darksite.cloud/tenant-id"] // ""' "${f}")"
  project_id="$(yq -r '.metadata.labels["darksite.cloud/project-id"] // ""' "${f}")"
  if [[ -z "${org_id}" ]]; then
    echo "FAIL: missing darksite.cloud/tenant-id label: ${f}" >&2
    failures=$((failures + 1))
    continue
  fi

  roles_len="$(yq -r '.spec.roles | length' "${f}" 2>/dev/null || echo 0)"
  if [[ "${roles_len}" == "0" ]]; then
    echo "FAIL: missing spec.roles in tenant AppProject (tenant Argo RBAC must be per-AppProject): ${f}" >&2
    failures=$((failures + 1))
    continue
  fi

  groups="$(yq -r '.spec.roles[].groups[]? // ""' "${f}" | rg -v '^$' | sort -u || true)"
  if [[ -z "${groups}" ]]; then
    echo "FAIL: missing spec.roles[].groups in tenant AppProject: ${f}" >&2
    failures=$((failures + 1))
    continue
  fi

  expected=()
  if [[ -n "${project_id}" ]]; then
    expected+=(
      "dk-tenant-${org_id}-project-${project_id}-admins"
      "dk-tenant-${org_id}-project-${project_id}-developers"
      "dk-tenant-${org_id}-project-${project_id}-viewers"
    )
  else
    expected+=(
      "dk-tenant-${org_id}-admins"
      "dk-tenant-${org_id}-viewers"
    )
  fi

  for g in "${expected[@]}"; do
    if ! grep -qx "${g}" <<<"${groups}"; then
      echo "FAIL: ${f}: missing expected group binding '${g}' in spec.roles[].groups" >&2
      failures=$((failures + 1))
    fi
  done

  # Tenant Argo UI access must not permit bypassing the PR flow by editing Argo primitives.
  forbidden_rbac_actions=(
    "applications, create,"
    "applications, update,"
    "applications, delete,"
    "projects, create,"
    "projects, update,"
    "projects, delete,"
    "repositories, *,"
  )
  for a in "${forbidden_rbac_actions[@]}"; do
    if rg -n "${a}" "${f}" >/dev/null 2>&1; then
      echo "FAIL: ${f}: must not grant Argo access-plane mutations (${a})" >&2
      failures=$((failures + 1))
      break
    fi
  done
done

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "tenant AppProject RBAC validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant AppProject RBAC validation PASSED"
