#!/usr/bin/env bash
# validate-offline-bootstrap-contract.sh - Repo-only offline guardrails (Phase 0)
#
# Purpose:
# - Prevent regressions where Stage 0/Stage 1 (or GitOps apps) silently reintroduce
#   implicit network fetches that break offline bootstrap and "first reconcile".
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

echo "==> Validating offline bootstrap guardrails (repo-only)"

# 1) Bootstrap scripts must not apply remote manifests (Phase 0 baseline).
if rg -n "kubectl( --context [^ ]+)? apply -f https?://" shared/scripts/bootstrap-*stage0.sh shared/scripts/bootstrap-*stage1.sh >/dev/null 2>&1; then
  rg -n "kubectl( --context [^ ]+)? apply -f https?://" shared/scripts/bootstrap-*stage0.sh shared/scripts/bootstrap-*stage1.sh >&2 || true
  fail "bootstrap scripts apply remote manifests via kubectl apply -f https:// (offline-hostile)"
fi

# 2) GitOps apps must not rely on public endpoints at sync time.
# Repo URLs for Argo Applications should be in-cluster endpoints (typically Forgejo).
# Allow in-cluster HTTPS (`*.svc.cluster.local`), but flag other HTTPS endpoints.
if rg -n "repoURL: https://" platform/gitops/apps | rg -v "\\.svc\\.cluster\\.local" >/dev/null 2>&1; then
  rg -n "repoURL: https://" platform/gitops/apps | rg -v "\\.svc\\.cluster\\.local" >&2 || true
  fail "GitOps Argo Applications reference non-cluster-internal https:// repoURL (offline-hostile)"
fi
# Allow http:// for in-cluster services only. Any other http:// repoURL is suspect (offline-hostile).
if rg -n "repoURL: http://" platform/gitops/apps | rg -v "\\.svc\\.cluster\\.local" >/dev/null 2>&1; then
  rg -n "repoURL: http://" platform/gitops/apps | rg -v "\\.svc\\.cluster\\.local" >&2 || true
  fail "GitOps Argo Applications reference non-cluster-internal http:// repoURL (offline-hostile)"
fi
if rg -n "repoURL: oci://" platform/gitops/apps >/dev/null 2>&1; then
  rg -n "repoURL: oci://" platform/gitops/apps >&2 || true
  fail "GitOps Argo Applications reference oci:// repoURL (public OCI registry dependency at sync time)"
fi

# 3) Curated artifact index should exist (Phase 0 minimal bootstrap list).
if [[ ! -f "platform/gitops/artifacts/package-index.yaml" ]]; then
  fail "missing curated artefact index: platform/gitops/artifacts/package-index.yaml"
fi
if [[ ! -f "platform/gitops/artifacts/runtime-artifact-index.yaml" ]]; then
  fail "missing curated runtime artefact index: platform/gitops/artifacts/runtime-artifact-index.yaml"
fi

# 4) Vendored Helm charts referenced by the boot-critical Argo apps must exist.
require_chart() {
  local relpath="$1"
  if [[ ! -f "platform/gitops/${relpath}/Chart.yaml" ]]; then
    fail "missing vendored Helm chart at platform/gitops/${relpath} (Chart.yaml not found)"
  fi
}

require_chart "components/networking/metallb/helm/charts/metallb-0.15.2/metallb"
require_chart "components/storage/nfs-provisioner/helm/charts/nfs-subdir-external-provisioner-4.0.18/nfs-subdir-external-provisioner"

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "offline bootstrap guardrails FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "offline bootstrap guardrails PASSED"
