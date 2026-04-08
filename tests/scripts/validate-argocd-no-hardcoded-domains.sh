#!/usr/bin/env bash
set -euo pipefail

# validate-argocd-no-hardcoded-domains.sh - Guardrail for Argo CD component.
#
# Contract:
# - Deployment identity (domains/hostnames) must come from DeploymentConfig:
#   - platform/gitops/deployments/<deploymentId>/config.yaml
#   - published in-cluster as ConfigMap/argocd/deploykube-deployment-config
#
# Therefore, the Argo CD component must not hard-code *.internal.example.com
# in YAML/JSON/shell manifests.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

scope="platform/gitops/components/platform/argocd"
pattern="\\.internal\\.florianzimmer\\.me"

echo "==> Checking Argo CD component for hard-coded domains"
echo "scope: ${scope}"
echo "pattern: ${pattern}"

matches="$(
  rg --no-heading -n "${pattern}" \
    -g '*.yaml' -g '*.yml' -g '*.json' -g '*.sh' \
    "${scope}" 2>/dev/null || true
)"

if [[ -n "${matches}" ]]; then
  echo "FAIL: found hard-coded domain literals in ${scope}:" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "PASS"

