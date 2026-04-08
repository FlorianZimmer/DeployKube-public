#!/usr/bin/env bash
# validate-bootstrap-contract.sh - Repo-only Stage 0/1 contract checks
#
# Purpose:
# - Catch "Stage 1 can't hand off to GitOps" failures without requiring a live cluster.
# - Validate that each deployment has the repo inputs Stage 1 expects (Forgejo seed + root app path).
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

require_file() {
  local path="$1"
  if [ ! -f "${path}" ]; then
    fail "missing file: ${path}"
    return 1
  fi
  return 0
}

require_dir() {
  local path="$1"
  if [ ! -d "${path}" ]; then
    fail "missing directory: ${path}"
    return 1
  fi
  return 0
}

extract_default_from_param_expansion() {
  # Extract the default value from a line like:
  #   VAR="${VAR:-default/value}"
  local line="$1"
  local out=""
  if [[ "${line}" =~ :-([^}]+)\} ]]; then
    out="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${out}"
}

echo "==> Validating bootstrap contract (repo-only)"

# Guardrail: platform/gitops must not become a nested git repository.
if [ -d "platform/gitops/.git" ]; then
  fail "nested git repository detected: platform/gitops/.git (forbidden)"
fi

# Required scripts / helpers.
require_file "shared/scripts/forgejo-seed-repo.sh" || true
require_file "shared/scripts/bootstrap-mac-orbstack-stage1.sh" || true
require_file "shared/scripts/bootstrap-proxmox-talos-stage1.sh" || true

# Forgejo seeding must snapshot git HEAD (not the working tree).
if [ -f "shared/scripts/forgejo-seed-repo.sh" ]; then
  if ! rg -n -q "rev-parse HEAD" shared/scripts/forgejo-seed-repo.sh; then
    fail "forgejo seeding script does not reference git HEAD (rev-parse HEAD): shared/scripts/forgejo-seed-repo.sh"
  fi
  if ! rg -n -q "\\bgit\\b.*\\barchive\\b" shared/scripts/forgejo-seed-repo.sh; then
    fail "forgejo seeding script does not appear to use git archive snapshots: shared/scripts/forgejo-seed-repo.sh"
  fi
fi

# Bootstrap file inputs referenced by Stage 1.
require_file "bootstrap/mac-orbstack/forgejo/values-bootstrap.yaml" || true
require_file "bootstrap/mac-orbstack/argocd/values-bootstrap.yaml" || true
require_file "bootstrap/proxmox-talos/config.yaml" || true

# Stage 1 root app path defaults should point at existing env bundles.
if [ -f "shared/scripts/bootstrap-mac-orbstack-stage1.sh" ]; then
  line="$(rg --no-heading '^ARGO_APP_PATH=' shared/scripts/bootstrap-mac-orbstack-stage1.sh | head -n 1 || true)"
  default_path="$(extract_default_from_param_expansion "${line}")"
  if [ -z "${default_path}" ]; then
    fail "could not extract default ARGO_APP_PATH from shared/scripts/bootstrap-mac-orbstack-stage1.sh"
  else
    require_dir "platform/gitops/${default_path}" || true
    require_file "platform/gitops/${default_path}/kustomization.yaml" || true
  fi
fi

if [ -f "shared/scripts/bootstrap-proxmox-talos-stage1.sh" ]; then
  line="$(rg --no-heading '^GITOPS_OVERLAY=' shared/scripts/bootstrap-proxmox-talos-stage1.sh | head -n 1 || true)"
  default_overlay="$(extract_default_from_param_expansion "${line}")"
  if [ -z "${default_overlay}" ]; then
    fail "could not extract default GITOPS_OVERLAY from shared/scripts/bootstrap-proxmox-talos-stage1.sh"
  else
    require_dir "platform/gitops/apps/environments/${default_overlay}" || true
    require_file "platform/gitops/apps/environments/${default_overlay}/kustomization.yaml" || true
  fi
fi

# For every deployment config, require a matching environment bundle directory.
deployments_dir="platform/gitops/deployments"
require_dir "${deployments_dir}" || true
mapfile -t deployment_configs < <(find "${deployments_dir}" -maxdepth 2 -name 'config.yaml' -type f | sort)
if [ "${#deployment_configs[@]}" -eq 0 ]; then
  fail "no deployments found under ${deployments_dir} (expected at least one */config.yaml)"
else
  echo "==> Found ${#deployment_configs[@]} deployment config(s)"
fi

for cfg in "${deployment_configs[@]}"; do
  dep_id="$(basename "$(dirname "${cfg}")")"
  env_dir="platform/gitops/apps/environments/${dep_id}"
  echo ""
  echo "==> Deployment: ${dep_id}"
  require_dir "${env_dir}" || true
  require_file "${env_dir}/kustomization.yaml" || true
  require_file "${env_dir}/deployment-secrets-bundle.yaml" || true
  # Platform apps are now controller-owned; each deployment must have a matching overlay patch.
  require_file "platform/gitops/components/platform/platform-apps-controller/overlays/${dep_id}/kustomization.yaml" || true
  require_file "platform/gitops/components/platform/platform-apps-controller/overlays/${dep_id}/patch-platformapps.yaml" || true
done

echo ""
if [ "${failures}" -ne 0 ]; then
  echo "bootstrap contract validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "bootstrap contract validation PASSED"
