#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

examples_dir="platform/gitops/deployments/examples/provisioning-v0"
failures=0

for cmd in yq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${cmd}" >&2
    exit 1
  fi
done

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

contains_exact() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

validate_bundle() {
  local bundle_file="$1"

  echo ""
  echo "==> Validating: ${bundle_file}"

  local invalid_docs
  invalid_docs="$(
    yq eval -N '
      select(
        .kind != "DeploymentConfig" and
        .kind != "Tenant" and
        .kind != "TenantProject"
      ) |
      [(.apiVersion // ""), (.kind // ""), (.metadata.name // "")] | @tsv
    ' "${bundle_file}" | sed '/^$/d'
  )"
  if [[ -n "${invalid_docs}" ]]; then
    while IFS=$'\t' read -r api_version kind name; do
      fail "${bundle_file}: unexpected document apiVersion='${api_version}' kind='${kind}' name='${name}'"
    done <<< "${invalid_docs}"
  fi

  local deployment_count tenant_count project_count
  deployment_count="$(yq eval -N 'select(.kind == "DeploymentConfig") | .metadata.name' "${bundle_file}" | sed '/^$/d' | wc -l | tr -d ' ')"
  tenant_count="$(yq eval -N 'select(.kind == "Tenant") | .metadata.name' "${bundle_file}" | sed '/^$/d' | wc -l | tr -d ' ')"
  project_count="$(yq eval -N 'select(.kind == "TenantProject") | .metadata.name' "${bundle_file}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "${deployment_count}" != "1" ]]; then
    fail "${bundle_file}: expected exactly 1 DeploymentConfig, found ${deployment_count}"
  fi
  if [[ "${tenant_count}" -lt 1 ]]; then
    fail "${bundle_file}: expected at least 1 Tenant"
  fi
  if [[ "${project_count}" -lt 1 ]]; then
    fail "${bundle_file}: expected at least 1 TenantProject"
  fi

  local deployment_name deployment_id deployment_env
  deployment_name="$(yq eval -N 'select(.kind == "DeploymentConfig") | .metadata.name // ""' "${bundle_file}" | sed -n '1p')"
  deployment_id="$(yq eval -N 'select(.kind == "DeploymentConfig") | .spec.deploymentId // ""' "${bundle_file}" | sed -n '1p')"
  deployment_env="$(yq eval -N 'select(.kind == "DeploymentConfig") | .spec.environmentId // ""' "${bundle_file}" | sed -n '1p')"

  if [[ -z "${deployment_name}" || -z "${deployment_id}" ]]; then
    fail "${bundle_file}: DeploymentConfig metadata.name/spec.deploymentId must be set"
  elif [[ "${deployment_name}" != "${deployment_id}" ]]; then
    fail "${bundle_file}: DeploymentConfig metadata.name='${deployment_name}' must equal spec.deploymentId='${deployment_id}'"
  fi

  if [[ ! "${deployment_env}" =~ ^(dev|prod|staging)$ ]]; then
    fail "${bundle_file}: DeploymentConfig spec.environmentId must be dev|prod|staging (got '${deployment_env}')"
  fi

  local duplicate_tenants duplicate_projects
  duplicate_tenants="$(
    yq eval -N 'select(.kind == "Tenant") | .metadata.name // ""' "${bundle_file}" \
      | sed '/^$/d' | sort | uniq -d
  )"
  duplicate_projects="$(
    yq eval -N 'select(.kind == "TenantProject") | .metadata.name // ""' "${bundle_file}" \
      | sed '/^$/d' | sort | uniq -d
  )"
  if [[ -n "${duplicate_tenants}" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      fail "${bundle_file}: duplicate Tenant metadata.name '${name}'"
    done <<< "${duplicate_tenants}"
  fi
  if [[ -n "${duplicate_projects}" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      fail "${bundle_file}: duplicate TenantProject metadata.name '${name}'"
    done <<< "${duplicate_projects}"
  fi

  local tenant_lines tenant_names=()
  mapfile -t tenant_lines < <(
    yq eval -N '
      select(.kind == "Tenant") |
      [(.metadata.name // ""), (.spec.orgId // ""), (.spec.tier // "")] | @tsv
    ' "${bundle_file}" | sed '/^$/d'
  )
  local tenant_line tenant_name tenant_org_id tenant_tier
  for tenant_line in "${tenant_lines[@]}"; do
    IFS=$'\t' read -r tenant_name tenant_org_id tenant_tier <<< "${tenant_line}"
    tenant_names+=("${tenant_name}")

    if [[ -z "${tenant_name}" || -z "${tenant_org_id}" ]]; then
      fail "${bundle_file}: Tenant metadata.name/spec.orgId must be set"
      continue
    fi
    if [[ "${tenant_name}" != "${tenant_org_id}" ]]; then
      fail "${bundle_file}: Tenant metadata.name='${tenant_name}' must equal spec.orgId='${tenant_org_id}' for v0 examples"
    fi
    if [[ ! "${tenant_tier}" =~ ^(S|D)$ ]]; then
      fail "${bundle_file}: Tenant '${tenant_name}' spec.tier must be S|D (got '${tenant_tier}')"
    fi
  done

  local project_lines
  mapfile -t project_lines < <(
    yq eval -N '
      select(.kind == "TenantProject") |
      [
        (.metadata.name // ""),
        (.spec.tenantRef.name // ""),
        (.spec.projectId // ""),
        ((.spec.environments // []) | join(",")),
        (.spec.git.repo // "")
      ] | @tsv
    ' "${bundle_file}" | sed '/^$/d'
  )
  local project_line project_name project_tenant_ref project_id project_envs_csv project_repo
  local env_match
  for project_line in "${project_lines[@]}"; do
    IFS=$'\t' read -r project_name project_tenant_ref project_id project_envs_csv project_repo <<< "${project_line}"

    if [[ -z "${project_name}" || -z "${project_tenant_ref}" || -z "${project_id}" ]]; then
      fail "${bundle_file}: TenantProject metadata.name/spec.tenantRef.name/spec.projectId must be set"
      continue
    fi
    if ! contains_exact "${project_tenant_ref}" "${tenant_names[@]}"; then
      fail "${bundle_file}: TenantProject '${project_name}' references missing Tenant '${project_tenant_ref}'"
    fi
    if [[ -z "${project_repo}" ]]; then
      fail "${bundle_file}: TenantProject '${project_name}' spec.git.repo must be set"
    fi

    env_match=0
    IFS=',' read -r -a project_envs <<< "${project_envs_csv}"
    local project_env
    for project_env in "${project_envs[@]}"; do
      if [[ "${project_env}" == "${deployment_env}" ]]; then
        env_match=1
        break
      fi
    done
    if [[ "${env_match}" != "1" ]]; then
      fail "${bundle_file}: TenantProject '${project_name}' environments must include deployment environment '${deployment_env}'"
    fi
  done
}

mapfile -t bundle_files < <(find "${examples_dir}" -maxdepth 1 -name '*.yaml' -type f | sort)
if [[ "${#bundle_files[@]}" -eq 0 ]]; then
  echo "error: no provisioning bundle examples found under ${examples_dir}" >&2
  exit 1
fi

echo "==> Found ${#bundle_files[@]} provisioning bundle example(s)"

for bundle_file in "${bundle_files[@]}"; do
  validate_bundle "${bundle_file}"
done

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "provisioning bundle example validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "provisioning bundle example validation PASSED"
