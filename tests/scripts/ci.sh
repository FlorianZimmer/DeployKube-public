#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/ci.sh [suite...]

Suites:
  all                  Run all suites (default)
  deployment-contracts Run deployment contract validators (repo-only)
  validation-jobs      Run validation-jobs doctrine checks

Notes:
  - This runner is the source of truth for what CI executes.
  - Keep individual scripts small and callable directly; add them to a suite here.
  - Some suites require Helm v3 for Kustomize Helm rendering; set HELM_BIN accordingly.
EOF
}

run() {
  echo ""
  echo "==> $*"
  "$@"
}

suite_deployment_contracts() {
  # Keep learning backlog healthy: fail when pending entries have gone stale.
  run ./scripts/dev/learnings-distill.sh --check
  run ./tests/scripts/validate-doc-taxonomy.sh
  run ./tests/scripts/validate-api-reference-docs.sh
  run ./tests/scripts/validate-deployment-config.sh
  run ./tests/scripts/validate-deployment-config-api.sh
  run ./tests/scripts/validate-provisioning-bundle-examples.sh
  run ./tests/scripts/validate-deployment-secrets-bundle.sh
  run ./tests/scripts/validate-environment-dsb-wiring.sh
  run ./tests/scripts/validate-platform-tenant-separation.sh
  run ./tests/scripts/validate-pvc-backup-labels.sh
  run ./tests/scripts/validate-backup-system-deployment-config-snapshot.sh
  run ./tests/scripts/validate-backup-system-proxmox-bootstrap-tools-mirror.sh
  run ./tests/scripts/validate-backup-system-proxmox-tenant-permissions-hook.sh
  run ./tests/scripts/validate-backup-system-full-restore-ignore-healthcheck.sh
  run ./tests/scripts/validate-backup-system-proxmox-set-permissions-hook.sh
  run ./tests/scripts/validate-loki-limits-controller-cutover.sh
  run ./tests/scripts/validate-cronjob-schedule-deherd.sh
  run ./tests/scripts/validate-tenant-backup-scope-contract.sh
  run ./tests/scripts/validate-tenant-folder-contract.sh
  run ./tests/scripts/validate-support-sessions.sh
  run ./tests/scripts/validate-tenant-intent-applications.sh
  run ./tests/scripts/validate-tenant-intent-surface.sh
  run ./tests/scripts/validate-resource-contract.sh
  run ./tests/scripts/validate-ha-three-node-deadlock-contract.sh
  run ./tests/scripts/validate-design-doc-tracking.sh
  run ./tests/scripts/validate-no-temp-identity-markers.sh
  run ./tests/scripts/validate-evidence-notes.sh
  run ./tests/scripts/validate-full-restore-evidence-policy.sh
  run ./tests/scripts/validate-backup-alerting-routing-contract.sh
  run ./tests/scripts/validate-backup-target-confidentiality-contract.sh
  run ./tests/scripts/validate-bootstrap-contract.sh
  run ./tests/scripts/validate-offline-bootstrap-contract.sh
  run ./tests/scripts/validate-version-lock.sh
  run ./tests/scripts/validate-version-lock-component-coverage.sh
  run ./tests/scripts/validate-supply-chain-pinning.sh
  run ./tests/scripts/validate-access-guardrails-supply-chain-contract.sh
  run ./tests/scripts/validate-certificates-smoke-tests-contract.sh
  run ./tests/scripts/validate-cert-manager-supply-chain-contract.sh
  run ./tests/scripts/validate-security-scanning-contract.sh
  run ./tests/scripts/validate-trivy-repo-owned-image-coverage.sh
  run ./tests/scripts/validate-platform-apps-controller.sh
  run ./tests/scripts/validate-component-assessment-runtime-e2e-coverage.sh
  run ./tests/scripts/validate-certificates-ingress-controller-cutover.sh
  run ./tests/scripts/validate-istio-gateway.sh
  run ./tests/scripts/validate-egress-proxy-controller-cutover.sh
  run ./tests/scripts/validate-ingress-adjacent-controller-cutover.sh
  run ./tests/scripts/validate-dns-wiring-controller-cutover.sh
  run ./tests/scripts/validate-coredns-upstream-corefile-contract.sh
  run ./tests/scripts/check-hardcoded-domains.sh
  run ./tests/scripts/validate-argocd-platform-project-migration.sh
  run ./tests/scripts/validate-argocd-default-project-lockdown.sh
  run ./tests/scripts/validate-tenant-prohibited-kinds.sh
  run ./tests/scripts/validate-tenant-eso-deny-policy.sh
  run ./tests/scripts/validate-tenant-registry-configmaps.sh
  run ./tests/scripts/validate-keycloak-tenant-registry-wiring.sh
  run ./tests/scripts/validate-vault-oidc-config.sh
  run ./tests/scripts/validate-vault-tenant-rbac-config.sh
  run ./tests/scripts/validate-vault-tenant-eso-config.sh
  run ./tests/scripts/validate-tenant-scoped-eso-stores.sh
  run ./tests/scripts/validate-tenant-appproject-templates.sh
  run ./tests/scripts/validate-tenant-appproject-rbac.sh
  run ./tests/scripts/validate-tenant-pr-gates.sh
  run ./tests/scripts/validate-tenant-repo-ci-template.sh
  run ./tests/scripts/validate-forgejo-tenant-pr-gate-enforcer.sh
  run ./tests/scripts/validate-argocd-no-hardcoded-domains.sh
  run ./tests/scripts/validate-component-overlay-layout.sh
  run ./tests/scripts/test-forgejo-switch-gitops-remote.sh
}

suite_validation_jobs() {
  run ./tests/scripts/validate-validation-jobs.sh
  run ./tests/scripts/validate-scim-bridge-image-wiring.sh
  run ./tests/scripts/validate-tenant-provisioner-image-wiring.sh
  run ./tests/scripts/lint-proxmox-talos-bootstrap-tools-overrides.sh
  run bash -n ./tests/scripts/e2e-cert-modes-matrix.sh
  run bash -n ./tests/scripts/e2e-iam-modes-matrix.sh
  run bash -n ./tests/scripts/e2e-idlab-poc.sh
  run bash -n ./tests/scripts/e2e-release-runtime-smokes.sh
  run bash -n ./tests/scripts/e2e-dns-delegation-modes-matrix.sh
  run bash -n ./tests/scripts/e2e-root-of-trust-modes-matrix.sh
  run python3 -m py_compile ./tests/scripts/lib/dns_delegation_writer_sim.py ./tests/scripts/lib/kms_shim_external_proxy_sim.py
}

if [[ $# -eq 0 ]]; then
  set -- all
fi

for suite in "$@"; do
  case "${suite}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    all)
      suite_deployment_contracts
      suite_validation_jobs
      ;;
    deployment-contracts)
      suite_deployment_contracts
      ;;
    validation-jobs)
      suite_validation_jobs
      ;;
    *)
      echo "error: unknown suite '${suite}'" >&2
      usage >&2
      exit 2
      ;;
  esac
done
