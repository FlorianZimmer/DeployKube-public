#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

echo "==> Validating Argo CD platform AppProject migration"

appproject_manifest="platform/gitops/apps/base/appproject-platform.yaml"
base_kustomization="platform/gitops/apps/base/kustomization.yaml"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL: missing required command: ${cmd}" >&2
    failures=$((failures + 1))
  fi
}

require_cmd rg
require_cmd yq
require_cmd sort

if [[ ! -f "${appproject_manifest}" ]]; then
  echo "FAIL: missing ${appproject_manifest}" >&2
  failures=$((failures + 1))
fi

if [[ ! -f "${base_kustomization}" ]]; then
  echo "FAIL: missing ${base_kustomization}" >&2
  failures=$((failures + 1))
else
  if ! rg -n "^[[:space:]]*-[[:space:]]*appproject-platform\\.yaml[[:space:]]*$" "${base_kustomization}" >/dev/null 2>&1; then
    echo "FAIL: ${base_kustomization} must include ${appproject_manifest}" >&2
    failures=$((failures + 1))
  fi
fi

if rg -n "^[[:space:]]*project:[[:space:]]*default[[:space:]]*$" platform/gitops/apps -S >/dev/null 2>&1; then
  echo "FAIL: platform apps must not use AppProject/default (project: default found under platform/gitops/apps):" >&2
  rg -n "^[[:space:]]*project:[[:space:]]*default[[:space:]]*$" platform/gitops/apps -S >&2
  failures=$((failures + 1))
fi

stage1_scripts=(
  "shared/scripts/bootstrap-mac-orbstack-stage1.sh"
  "shared/scripts/bootstrap-proxmox-talos-stage1.sh"
)

for script in "${stage1_scripts[@]}"; do
  if [[ ! -f "${script}" ]]; then
    echo "FAIL: missing stage 1 script: ${script}" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! rg -n "^[[:space:]]*project:[[:space:]]*platform[[:space:]]*$" "${script}" >/dev/null 2>&1; then
    echo "FAIL: stage 1 root Application must use project: platform (missing in ${script})" >&2
    failures=$((failures + 1))
  fi
  if ! rg -n "appproject-platform\\.yaml" "${script}" >/dev/null 2>&1; then
    echo "FAIL: stage 1 must apply AppProject/platform before root app (missing appproject-platform.yaml reference in ${script})" >&2
    failures=$((failures + 1))
  fi
done

if [[ -f "${appproject_manifest}" ]] && command -v yq >/dev/null 2>&1; then
  echo ""
  echo "==> Validating AppProject/platform sourceRepo allowlist covers platform apps"

  mapfile -t allowed_repos < <(
    yq eval -r '.spec.sourceRepos[]? // ""' "${appproject_manifest}" 2>/dev/null | rg -v '^[[:space:]]*$' || true
  )

  mapfile -t platform_app_repos < <(
    rg --files platform/gitops/apps -g '*.yml' -g '*.yaml' \
      | xargs -n 200 yq eval-all -r 'select(.kind == "Application" and .spec.project == "platform") | .spec.source.repoURL // ""' 2>/dev/null \
      | rg -v '^---$' \
      | rg -v '^[[:space:]]*$' \
      | sort -u
  )

  for repo in "${platform_app_repos[@]}"; do
    allowed=false
    for pattern in "${allowed_repos[@]}"; do
      # AppProject sourceRepos supports wildcard patterns; treat entries as bash globs here.
      if [[ "${repo}" == ${pattern} ]]; then
        allowed=true
        break
      fi
    done
    if [[ "${allowed}" != "true" ]]; then
      echo "FAIL: AppProject/platform must allow repoURL used by platform apps: ${repo}" >&2
      failures=$((failures + 1))
    fi
  done
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "Argo CD platform AppProject migration validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "Argo CD platform AppProject migration validation PASSED"
