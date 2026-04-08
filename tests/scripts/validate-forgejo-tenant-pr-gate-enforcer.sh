#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

echo "==> Validating Forgejo tenant PR gate enforcement (branch protection controller)"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency kustomize
check_dependency yq

rendered="$(kustomize build platform/gitops/components/shared/rbac/base)"

cronjob_name="forgejo-tenant-pr-gate-enforcer"

cronjob="$(
  printf '%s\n' "${rendered}" \
    | yq -o=json -I=0 'select(.apiVersion=="batch/v1" and .kind=="CronJob" and .metadata.name=="'"${cronjob_name}"'")'
)"

if [[ -z "${cronjob}" ]]; then
  echo "FAIL: missing CronJob/${cronjob_name} in shared/rbac base render" >&2
  exit 1
fi

contexts="$(
  printf '%s\n' "${cronjob}" \
    | yq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]? | select(.name=="REQUIRED_CONTEXTS_CSV") | .value // ""'
)"
if [[ "${contexts}" != "tenant-pr-gates" ]]; then
  echo "FAIL: CronJob/${cronjob_name} must require REQUIRED_CONTEXTS_CSV=tenant-pr-gates (got: ${contexts:-<empty>})" >&2
  exit 1
fi

registry_cm="$(
  printf '%s\n' "${cronjob}" \
    | yq -r '.spec.jobTemplate.spec.template.spec.volumes[]? | select(.name=="tenant-registry") | .configMap.name // ""'
)"
if [[ "${registry_cm}" != "deploykube-tenant-registry" ]]; then
  echo "FAIL: CronJob/${cronjob_name} must mount ConfigMap deploykube-tenant-registry (got: ${registry_cm:-<empty>})" >&2
  exit 1
fi

echo "forgejo tenant PR gate enforcement validation PASSED"

