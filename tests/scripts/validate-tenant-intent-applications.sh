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

check_dependency kustomize
check_dependency yq

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

check_overlay() {
  local overlay="$1"
  local expected_env="$2"

  echo "==> ${overlay}"
  local rendered
  if ! rendered="$(kustomize build "${overlay}" 2>/dev/null)"; then
    fail "kustomize build failed: ${overlay}"
    return 0
  fi

  local appprojects
  appprojects="$(
    printf '%s\n' "${rendered}" | yq eval -r '
      select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "AppProject") |
      (.metadata.name // "")
    ' - | sed '/^$/d' | sort -u
  )" || {
    fail "failed to parse rendered AppProjects: ${overlay}"
    return 0
  }

  local apps
  apps="$(
    printf '%s\n' "${rendered}" | yq eval -r '
      select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "Application") |
      [
        (.metadata.name // ""),
        (.metadata.labels."darksite.cloud/tenant-id" // ""),
        (.metadata.labels."darksite.cloud/project-id" // ""),
        (.spec.project // ""),
        (.spec.destination.name // ""),
        (.spec.destination.namespace // ""),
        (.spec.source.repoURL // ""),
        (.spec.source.targetRevision // ""),
        (.spec.source.path // "")
      ] | @tsv
    ' -
  )" || {
    fail "failed to parse rendered Applications: ${overlay}"
    return 0
  }

  if [[ -z "${apps}" ]]; then
    fail "no tenant intent Applications found in ${overlay}"
    return 0
  fi

  while IFS=$'\t' read -r name org_id project_id project dest_name dest_ns repo rev path; do
    [[ -n "${name}" ]] || continue

    if [[ -z "${org_id}" ]]; then
      fail "${overlay}: Application/${name} missing label darksite.cloud/tenant-id"
    fi

    local expected_project="tenant-intent-${org_id}-p-${project_id}"
    if [[ "${project}" != "${expected_project}" ]]; then
      fail "${overlay}: Application/${name} spec.project='${project}' (expected ${expected_project})"
    else
      if ! grep -qx "${expected_project}" <<<"${appprojects}"; then
        fail "${overlay}: Application/${name} references missing AppProject/${expected_project}"
      fi
    fi

    if [[ "${dest_name}" != "in-cluster" ]]; then
      fail "${overlay}: Application/${name} spec.destination.name='${dest_name}' (expected in-cluster)"
    fi

    local expected_dest_ns="t-${org_id}-p-${project_id}-${expected_env}-app"
    if [[ "${dest_ns}" != "${expected_dest_ns}" ]]; then
      fail "${overlay}: Application/${name} spec.destination.namespace='${dest_ns}' (expected ${expected_dest_ns})"
    fi

    if [[ "${repo}" != "https://forgejo-https.forgejo.svc.cluster.local/platform/cluster-config.git" ]]; then
      fail "${overlay}: Application/${name} spec.source.repoURL='${repo}' (expected platform/cluster-config.git)"
    fi

    if [[ "${rev}" != "main" ]]; then
      fail "${overlay}: Application/${name} spec.source.targetRevision='${rev}' (expected main)"
    fi

    if [[ "${path}" == platform/gitops/* ]]; then
      fail "${overlay}: Application/${name} spec.source.path must be relative to GitOps repo root (got '${path}')"
    fi

    if [[ "${path}" != tenants/*/projects/*/namespaces/"${expected_env}"* ]]; then
      fail "${overlay}: Application/${name} spec.source.path='${path}' (expected tenants/<orgId>/projects/<projectId>/namespaces/${expected_env}/...)"
    fi
  done <<<"${apps}"
}

echo "==> Validating tenant intent Applications (Argo wiring; no ApplicationSet)"

check_overlay "platform/gitops/apps/tenants/overlays/dev" "dev"
check_overlay "platform/gitops/apps/tenants/overlays/prod" "prod"

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "tenant intent Application validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant intent Application validation PASSED"
