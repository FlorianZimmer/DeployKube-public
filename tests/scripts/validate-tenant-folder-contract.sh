#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

tenant_root="platform/gitops/tenants"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency yq
check_dependency kustomize

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

validate_dns_label() {
  local label="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    fail "${label}: missing"
    return 1
  fi
  if [[ "${#value}" -gt 63 ]]; then
    fail "${label}: too long (>63): ${value}"
    return 1
  fi
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    fail "${label}: must be DNS-label-safe ([a-z0-9-], start/end alnum): ${value}"
    return 1
  fi
  return 0
}

echo "==> Validating tenant folder contract (platform/gitops/tenants)"

if [[ ! -d "${tenant_root}" ]]; then
  echo "error: missing ${tenant_root}" >&2
  exit 1
fi

mapfile -t tenant_dirs < <(
  find "${tenant_root}" -mindepth 1 -maxdepth 1 -type d \
    -not -name '_templates' \
    -not -name '.*' \
    | sort
)

if [[ "${#tenant_dirs[@]}" -eq 0 ]]; then
  echo "error: no tenants found under ${tenant_root} (expected at least one)" >&2
  exit 1
fi

for tenant_dir in "${tenant_dirs[@]}"; do
  org_id="$(basename "${tenant_dir}")"
  echo ""
  echo "==> ${org_id}"

  validate_dns_label "orgId folder" "${org_id}" || true

  meta="${tenant_dir}/metadata.yaml"
  if [[ ! -f "${meta}" ]]; then
    fail "${org_id}: missing metadata.yaml"
    continue
  fi

  meta_org_id="$(yq -r '.orgId // ""' "${meta}" 2>/dev/null || true)"
  if [[ "${meta_org_id}" != "${org_id}" ]]; then
    fail "${org_id}: metadata.yaml orgId='${meta_org_id}' (expected '${org_id}')"
  fi

  tier="$(yq -r '.tier // ""' "${meta}" 2>/dev/null || true)"
  case "${tier}" in
    S|D) ;;
    *)
      fail "${org_id}: metadata.yaml tier='${tier}' (expected S|D)"
      ;;
  esac

  retention_mode="$(yq -r '.retention.mode // ""' "${meta}" 2>/dev/null || true)"
  case "${retention_mode}" in
    immediate|grace|legal-hold) ;;
    *)
      fail "${org_id}: metadata.yaml retention.mode='${retention_mode}' (expected immediate|grace|legal-hold)"
      ;;
  esac

  grace_days="$(yq -r '.retention.gracePeriodDays // ""' "${meta}" 2>/dev/null || true)"
  if [[ "${retention_mode}" == "grace" ]]; then
    if [[ -z "${grace_days}" || "${grace_days}" == "null" ]]; then
      fail "${org_id}: retention.mode=grace requires retention.gracePeriodDays"
    elif ! [[ "${grace_days}" =~ ^[0-9]+$ ]]; then
      fail "${org_id}: retention.gracePeriodDays='${grace_days}' (expected integer)"
    fi
  else
    if [[ -n "${grace_days}" && "${grace_days}" != "null" ]]; then
      fail "${org_id}: retention.gracePeriodDays is set but retention.mode='${retention_mode}'"
    fi
  fi

  delete_from_backups="$(yq -r '.deletion.deleteFromBackups // ""' "${meta}" 2>/dev/null || true)"
  case "${delete_from_backups}" in
    retention-only|tenant-scoped|strict-sla) ;;
    *)
      fail "${org_id}: deletion.deleteFromBackups='${delete_from_backups}' (expected retention-only|tenant-scoped|strict-sla)"
      ;;
  esac

  projects_dir="${tenant_dir}/projects"
  if [[ ! -d "${projects_dir}" ]]; then
    echo "info: no projects/ dir (ok for now): ${projects_dir}"
    continue
  fi

  mapfile -t project_dirs < <(
    find "${projects_dir}" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort
  )
  for project_dir in "${project_dirs[@]}"; do
    project_id="$(basename "${project_dir}")"
    validate_dns_label "projectId folder (${org_id})" "${project_id}" || true

    namespaces_root="${project_dir}/namespaces"
    if [[ ! -d "${namespaces_root}" ]]; then
      continue
    fi

    # Ensure only dev/prod exist as namespace env roots.
    mapfile -t env_dirs < <(find "${namespaces_root}" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort)
    for env_dir in "${env_dirs[@]}"; do
      env="$(basename "${env_dir}")"
      case "${env}" in
        dev|prod) ;;
        *)
          fail "${org_id}/${project_id}: namespaces env '${env}' is invalid (expected dev|prod)"
          ;;
      esac
    done

    for env in dev prod; do
      env_dir="${namespaces_root}/${env}"
      if [[ ! -d "${env_dir}" ]]; then
        continue
      fi
      if [[ ! -f "${env_dir}/kustomization.yaml" ]]; then
        fail "${org_id}/${project_id}: missing kustomization.yaml in namespaces/${env}"
        continue
      fi

      if ! rendered="$(kustomize build "${env_dir}" 2>/dev/null)"; then
        fail "${org_id}/${project_id}: kustomize build failed: ${env_dir}"
        continue
      fi

      ns_lines="$(
        printf '%s\n' "${rendered}" | yq eval -r '
          select(.apiVersion == "v1" and .kind == "Namespace") |
          [
            (.metadata.name // ""),
            (.metadata.labels."darksite.cloud/rbac-profile" // ""),
            (.metadata.labels."darksite.cloud/tenant-id" // ""),
            (.metadata.labels."darksite.cloud/project-id" // ""),
            (.metadata.labels."observability.grafana.com/tenant" // "")
          ] | @tsv
        ' -
      )" || {
        fail "${org_id}/${project_id}: failed to parse rendered YAML from ${env_dir}"
        continue
      }

      while IFS=$'\t' read -r ns_name rbac_profile ns_org ns_project obs_tenant; do
        [[ -n "${ns_name}" ]] || continue
        [[ "${rbac_profile}" == "tenant" ]] || fail "${org_id}/${project_id}: Namespace/${ns_name} darksite.cloud/rbac-profile='${rbac_profile}' (expected tenant)"
        [[ "${ns_org}" == "${org_id}" ]] || fail "${org_id}/${project_id}: Namespace/${ns_name} darksite.cloud/tenant-id='${ns_org}' (expected ${org_id})"
        [[ "${ns_project}" == "${project_id}" ]] || fail "${org_id}/${project_id}: Namespace/${ns_name} darksite.cloud/project-id='${ns_project}' (expected ${project_id})"
        [[ "${obs_tenant}" == "${org_id}" ]] || fail "${org_id}/${project_id}: Namespace/${ns_name} observability.grafana.com/tenant='${obs_tenant}' (expected ${org_id})"
      done <<<"${ns_lines}"
    done
  done
done

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "tenant folder contract validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant folder contract validation PASSED"
