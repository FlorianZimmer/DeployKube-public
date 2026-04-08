#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency yq
check_dependency kustomize
check_dependency comm

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

registry="platform/gitops/apps/tenants/base/tenant-registry.yaml"
tenant_root="platform/gitops/tenants"
overlay_dev="platform/gitops/apps/tenants/overlays/dev"
overlay_prod="platform/gitops/apps/tenants/overlays/prod"

echo "==> Validating tenant intent surface coherence (registry ↔ folders ↔ Argo Applications)"

if [[ ! -f "${registry}" ]]; then
  echo "error: missing tenant registry: ${registry}" >&2
  exit 1
fi
if [[ ! -d "${tenant_root}" ]]; then
  echo "error: missing tenant root: ${tenant_root}" >&2
  exit 1
fi
if [[ ! -d "${overlay_dev}" ]]; then
  echo "error: missing tenants dev overlay: ${overlay_dev}" >&2
  exit 1
fi
if [[ ! -d "${overlay_prod}" ]]; then
  echo "error: missing tenants prod overlay: ${overlay_prod}" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}" || true; }
trap cleanup EXIT INT TERM

registry_orgs="${tmpdir}/registry-orgs.txt"
registry_pairs="${tmpdir}/registry-pairs.txt"
actual_orgs="${tmpdir}/actual-orgs.txt"
actual_pairs="${tmpdir}/actual-pairs.txt"
dev_pairs="${tmpdir}/dev-app-pairs.txt"
prod_pairs="${tmpdir}/prod-app-pairs.txt"
expected_appprojects="${tmpdir}/expected-appprojects.txt"
actual_appprojects="${tmpdir}/actual-appprojects.txt"

# Registry sets
if ! yq -r '.tenants[].orgId // ""' "${registry}" | sed '/^$/d' | sort -u >"${registry_orgs}"; then
  echo "error: failed to parse registry orgIds: ${registry}" >&2
  exit 1
fi
if ! yq -r '.tenants[] | .orgId as $o | .projects[]? | .projectId as $p | select(($o // "") != "" and ($p // "") != "") | "\($o)\t\($p)"' "${registry}" | sort -u >"${registry_pairs}"; then
  echo "error: failed to parse registry orgId/projectId pairs: ${registry}" >&2
  exit 1
fi

if [[ ! -s "${registry_orgs}" ]]; then
  echo "error: tenant registry contains no tenants: ${registry}" >&2
  exit 1
fi

# Tenant registry base must instantiate the tenant AppProjects (intent + workload).
rendered_registry="$(
  kustomize build platform/gitops/apps/tenants/base 2>/dev/null || true
)"
if [[ -z "${rendered_registry}" ]]; then
  fail "kustomize build failed for tenant registry base: platform/gitops/apps/tenants/base"
else
  printf '%s\n' "${rendered_registry}" | yq eval -r '
    select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "AppProject") |
    (.metadata.name // "")
  ' - | sed '/^$/d' | sort -u | grep -E '^tenant-' >"${actual_appprojects}" || true

  : >"${expected_appprojects}"
  while IFS= read -r org; do
    [[ -n "${org}" ]] || continue
    printf 'tenant-%s\n' "${org}" >>"${expected_appprojects}"
  done <"${registry_orgs}"
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    printf 'tenant-%s-p-%s\n' "${org}" "${project}" >>"${expected_appprojects}"
    printf 'tenant-intent-%s-p-%s\n' "${org}" "${project}" >>"${expected_appprojects}"
  done <"${registry_pairs}"
  sort -u -o "${expected_appprojects}" "${expected_appprojects}"

  if missing_appprojects="$(comm -13 "${actual_appprojects}" "${expected_appprojects}")" && [[ -n "${missing_appprojects}" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      fail "tenant registry base missing AppProject: ${name} (expected in platform/gitops/apps/tenants/base)"
    done <<<"${missing_appprojects}"
  fi

  if extra_appprojects="$(comm -23 "${actual_appprojects}" "${expected_appprojects}")" && [[ -n "${extra_appprojects}" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      fail "tenant registry base has unexpected AppProject (not in registry): ${name}"
    done <<<"${extra_appprojects}"
  fi
fi

# Folder sets
find "${tenant_root}" -mindepth 1 -maxdepth 1 -type d \
  -not -name '_templates' \
  -not -name '.*' \
  | sed 's|.*/||' | sort -u >"${actual_orgs}"

while IFS= read -r project_dir; do
  [[ -n "${project_dir}" ]] || continue
  project_id="$(basename "${project_dir}")"
  org_id="$(basename "$(dirname "$(dirname "${project_dir}")")")"
  printf '%s\t%s\n' "${org_id}" "${project_id}"
done < <(
  find "${tenant_root}" -mindepth 3 -maxdepth 3 -type d -path "${tenant_root}/*/projects/*" -not -name '.*' | sort
) | sort -u >"${actual_pairs}"

# Folders must not introduce tenants/projects not in registry.
if extra_orgs="$(comm -23 "${actual_orgs}" "${registry_orgs}")" && [[ -n "${extra_orgs}" ]]; then
  while IFS= read -r org; do
    [[ -n "${org}" ]] || continue
    fail "tenant folder exists but is missing from registry: orgId=${org} (${tenant_root}/${org})"
  done <<<"${extra_orgs}"
fi

if missing_orgs="$(comm -13 "${actual_orgs}" "${registry_orgs}")" && [[ -n "${missing_orgs}" ]]; then
  while IFS= read -r org; do
    [[ -n "${org}" ]] || continue
    fail "registry tenant missing folder: orgId=${org} (expected ${tenant_root}/${org}/metadata.yaml)"
  done <<<"${missing_orgs}"
fi

if extra_pairs="$(comm -23 "${actual_pairs}" "${registry_pairs}")" && [[ -n "${extra_pairs}" ]]; then
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    fail "tenant project folder exists but is missing from registry: ${org}/${project} (${tenant_root}/${org}/projects/${project})"
  done <<<"${extra_pairs}"
fi

if missing_pairs="$(comm -13 "${actual_pairs}" "${registry_pairs}")" && [[ -n "${missing_pairs}" ]]; then
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    fail "registry tenant project missing folder: ${org}/${project} (expected ${tenant_root}/${org}/projects/${project})"
  done <<<"${missing_pairs}"
fi

# Registry projects must have dev+prod namespace roots that are kustomize-buildable.
while IFS=$'\t' read -r org project; do
  [[ -n "${org}" ]] || continue
  for env in dev prod; do
    env_dir="${tenant_root}/${org}/projects/${project}/namespaces/${env}"
    if [[ ! -d "${env_dir}" ]]; then
      fail "missing namespaces/${env} for ${org}/${project}: ${env_dir}"
      continue
    fi
    if [[ ! -f "${env_dir}/kustomization.yaml" ]]; then
      fail "missing kustomization.yaml for ${org}/${project} namespaces/${env}: ${env_dir}/kustomization.yaml"
      continue
    fi
    if ! kustomize build "${env_dir}" >/dev/null 2>&1; then
      fail "kustomize build failed for ${org}/${project} namespaces/${env}: ${env_dir}"
    fi
  done
done <"${registry_pairs}"

# Extract tenant intent Application org/project labels per overlay and validate they match the registry.
extract_app_pairs() {
  local overlay="$1"
  local expected_env="$2"
  local out="$3"

  local rendered
  if ! rendered="$(kustomize build "${overlay}" 2>/dev/null)"; then
    fail "kustomize build failed: ${overlay}"
    return 0
  fi

  local lines
  lines="$(
    printf '%s\n' "${rendered}" | yq eval -r '
      select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "Application") |
      [
        (.metadata.name // ""),
        (.metadata.labels."darksite.cloud/tenant-id" // ""),
        (.metadata.labels."darksite.cloud/project-id" // ""),
        (.spec.source.path // "")
      ] | @tsv
    ' -
  )" || {
    fail "failed to parse Applications from overlay: ${overlay}"
    return 0
  }

  : >"${out}"
  while IFS=$'\t' read -r name org_id project_id path; do
    [[ -n "${name}" ]] || continue
    if [[ -z "${org_id}" || -z "${project_id}" ]]; then
      fail "${overlay}: Application/${name} must set labels darksite.cloud/tenant-id and darksite.cloud/project-id"
      continue
    fi
    if [[ "${path}" != "tenants/${org_id}/projects/${project_id}/namespaces/${expected_env}" ]]; then
      fail "${overlay}: Application/${name} spec.source.path='${path}' (expected tenants/${org_id}/projects/${project_id}/namespaces/${expected_env})"
    fi
    printf '%s\t%s\n' "${org_id}" "${project_id}" >>"${out}"
  done <<<"${lines}"

  sort -u -o "${out}" "${out}"
}

extract_app_pairs "${overlay_dev}" "dev" "${dev_pairs}"
extract_app_pairs "${overlay_prod}" "prod" "${prod_pairs}"

if missing_dev="$(comm -13 "${dev_pairs}" "${registry_pairs}")" && [[ -n "${missing_dev}" ]]; then
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    fail "registry tenant project missing dev tenant intent Application: ${org}/${project}"
  done <<<"${missing_dev}"
fi
if extra_dev="$(comm -23 "${dev_pairs}" "${registry_pairs}")" && [[ -n "${extra_dev}" ]]; then
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    fail "dev tenant intent Application exists but is not in registry: ${org}/${project}"
  done <<<"${extra_dev}"
fi

if missing_prod="$(comm -13 "${prod_pairs}" "${registry_pairs}")" && [[ -n "${missing_prod}" ]]; then
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    fail "registry tenant project missing prod tenant intent Application: ${org}/${project}"
  done <<<"${missing_prod}"
fi
if extra_prod="$(comm -23 "${prod_pairs}" "${registry_pairs}")" && [[ -n "${extra_prod}" ]]; then
  while IFS=$'\t' read -r org project; do
    [[ -n "${org}" ]] || continue
    fail "prod tenant intent Application exists but is not in registry: ${org}/${project}"
  done <<<"${extra_prod}"
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "tenant intent surface validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant intent surface validation PASSED"
