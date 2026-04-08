#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

echo "==> Validating tenant AppProject templates"

templates=(
  "platform/gitops/apps/tenants/_templates/appproject-tenant-org.yaml"
  "platform/gitops/apps/tenants/_templates/appproject-tenant-project.yaml"
)

require_role_group_placeholder() {
  local file="$1"
  local placeholder="$2"
  if ! rg -n "^[[:space:]]*- ${placeholder}[[:space:]]*$" "${file}" >/dev/null 2>&1; then
    echo "FAIL: template must bind expected group '${placeholder}' via spec.roles[].groups: ${file}" >&2
    return 1
  fi
  return 0
}

for f in "${templates[@]}"; do
  if [[ ! -f "${f}" ]]; then
    echo "FAIL: missing template: ${f}" >&2
    failures=$((failures + 1))
    continue
  fi

  if ! rg -n "^[[:space:]]*kind:[[:space:]]*AppProject[[:space:]]*$" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must be an AppProject: ${f}" >&2
    failures=$((failures + 1))
  fi

  if ! rg -n "^[[:space:]]*clusterResourceWhitelist:[[:space:]]*$" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must set clusterResourceWhitelist (deny cluster-scoped): ${f}" >&2
    failures=$((failures + 1))
  fi

  if ! rg -n "^[[:space:]]*roles:[[:space:]]*$" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must define spec.roles (tenant group-to-role mapping): ${f}" >&2
    failures=$((failures + 1))
  fi

  if [[ "${f}" == *"appproject-tenant-org.yaml" ]]; then
    require_role_group_placeholder "${f}" "dk-tenant-<orgId>-admins" || failures=$((failures + 1))
    require_role_group_placeholder "${f}" "dk-tenant-<orgId>-viewers" || failures=$((failures + 1))
  fi

  if [[ "${f}" == *"appproject-tenant-project.yaml" ]]; then
    require_role_group_placeholder "${f}" "dk-tenant-<orgId>-project-<projectId>-admins" || failures=$((failures + 1))
    require_role_group_placeholder "${f}" "dk-tenant-<orgId>-project-<projectId>-developers" || failures=$((failures + 1))
    require_role_group_placeholder "${f}" "dk-tenant-<orgId>-project-<projectId>-viewers" || failures=$((failures + 1))
  fi

  if rg -n "^[[:space:]]*group:[[:space:]]*\"\\*\"[[:space:]]*$" "${f}" >/dev/null 2>&1 || rg -n "^[[:space:]]*kind:[[:space:]]*\"\\*\"[[:space:]]*$" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must not allow wildcard resources: ${f}" >&2
    failures=$((failures + 1))
  fi

  if ! rg -n "tenant-<orgId>" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must include <orgId> placeholder: ${f}" >&2
    failures=$((failures + 1))
  fi

  if rg -n "platform/cluster-config\\.git" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must not allow platform repo: ${f}" >&2
    failures=$((failures + 1))
  fi

  if rg -n "^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$" "${f}" >/dev/null 2>&1; then
    echo "FAIL: template must not allow core/v1 Secret by default: ${f}" >&2
    failures=$((failures + 1))
  fi

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
      echo "FAIL: template must not grant Argo access-plane mutations (${a}): ${f}" >&2
      failures=$((failures + 1))
      break
    fi
  done

  # Sanity: deny obvious access-plane API groups in the allowlist.
  forbidden_groups=(
    "admissionregistration.k8s.io"
    "apiextensions.k8s.io"
    "argoproj.io"
    "external-secrets.io"
    "kyverno.io"
    "rbac.authorization.k8s.io"
  )
  for g in "${forbidden_groups[@]}"; do
    if rg -n "^[[:space:]]*group:[[:space:]]*${g}[[:space:]]*$" "${f}" >/dev/null 2>&1; then
      echo "FAIL: template must not allow access-plane group '${g}': ${f}" >&2
      failures=$((failures + 1))
      break
    fi
  done
done

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "tenant AppProject template validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant AppProject template validation PASSED"
