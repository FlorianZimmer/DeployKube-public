#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR:-${REPO_ROOT}/platform/gitops/deployments}"

DEPLOYMENT_ID=""

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/deployments/bundle-sync.sh --deployment-id <id>

What it does:
  - Scans platform/gitops/deployments/<id>/secrets/*.secret.sops.yaml
  - Rewrites platform/gitops/deployments/<id>/kustomization.yaml so
    argocd/deploykube-deployment-secrets contains the same file list.
  - Ensures config.yaml is applied as a DeploymentConfig CR (resources: [config.yaml]).

Notes:
  - This does not create/encrypt secrets; it only keeps the bundle file list in sync.
  - Run ./tests/scripts/validate-deployment-secrets-bundle.sh afterwards.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" ]]; then
  echo "missing --deployment-id" >&2
  usage
  exit 1
fi

dep_dir="${DEPLOYMENTS_DIR}/${DEPLOYMENT_ID}"
secrets_dir="${dep_dir}/secrets"
out="${dep_dir}/kustomization.yaml"

if [[ ! -d "${dep_dir}" ]]; then
  echo "deployment directory missing: ${dep_dir}" >&2
  exit 1
fi
if [[ ! -d "${secrets_dir}" ]]; then
  echo "secrets directory missing: ${secrets_dir}" >&2
  exit 1
fi

mapfile -t files < <(find "${secrets_dir}" -maxdepth 1 -type f -name '*.secret.sops.yaml' -print | sort)
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "no bundle files found under ${secrets_dir} (*.secret.sops.yaml)" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT INT TERM

{
  cat <<'HEADER'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd

resources:
  - config.yaml

generatorOptions:
  disableNameSuffixHash: true

configMapGenerator:
  - name: deploykube-deployment-secrets
    files:
HEADER

  for f in "${files[@]}"; do
    base="$(basename "${f}")"
    printf '      - %s=secrets/%s\n' "${base}" "${base}"
  done

} >"${tmp}"

mv "${tmp}" "${out}"
trap - EXIT INT TERM

echo "wrote ${out}" >&2
