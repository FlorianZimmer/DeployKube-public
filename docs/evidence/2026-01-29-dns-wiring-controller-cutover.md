# Evidence: DNS wiring cut over to controller-owned reconciliation

EvidenceFormat: v1

Date: 2026-01-29
Environment: repo-only

Scope / ground truth:
- Repo-side evidence only (GitOps sources + validators). No live cluster claims in this note.
- Goal: retire the repo-side "render then commit" workflow for DNS wiring (PowerDNS/CoreDNS/external-sync).
- DNS wiring is reconciled by the tenant provisioner controller from the DeploymentConfig snapshot ConfigMap.

Git:
- Commit: 81ae2f09

Argo:
- Root app: platform-apps
- Sync/Health: not verified (repo-only)
- Revision: not verified (repo-only)

## What changed

- Removed the repo-side renderer and drift validator:
  - deleted: `scripts/deployments/render-dns.sh`
  - deleted: `tests/scripts/validate-dns-overlays.sh`
- Updated DNS components to be controller-wired (no DeploymentConfig-rendered overlays):
  - CoreDNS: `components/networking/coredns` now uses a base `ConfigMap/coredns` with a stub-domain block; the stub-domain + forward target are patched by the controller.
  - PowerDNS: `components/dns/powerdns/base` now contains `ConfigMap/powerdns-config` + `Deployment/external-dns`; deployment-specific overlays remain for static deltas only (for example NetworkPolicies and MetalLB address-pool annotations).
  - External sync: `components/dns/external-sync` now reads `DNS_DOMAIN` + `DNS_SYNC_HOSTS` from `ConfigMap/deploykube-dns-wiring` (created/updated by the controller).
- Added controller-owned reconciliation:
  - `tools/tenant-provisioner/internal/controllers/dns_wiring_controller.go`
  - Enabled apply-mode in GitOps: `--dns-wiring-observe-only=false` in `platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml`
- Prevented Argo from fighting controller-owned DNS wiring:
  - `platform-apps` `ignoreDifferences` for controller-owned fields (PowerDNS VIP/domain, external-dns args, CoreDNS Corefile stub block)
  - env bundles re-rendered: `platform/gitops/apps/environments/*/overlay-apps.yaml`
- Added a cutover validator to prevent renderer regressions:
  - `tests/scripts/validate-dns-wiring-controller-cutover.sh` (wired via `tests/scripts/ci.sh` + `shared/scripts/preflight-gitops-seed-guardrail.sh`)

## Commands / outputs

```bash
./tests/scripts/ci.sh deployment-contracts | rg -n "(dns wiring controller cutover validation PASSED|overlay-apps validation PASSED)"
```

Output:

```text
548:overlay-apps validation PASSED
564:dns wiring controller cutover validation PASSED
```
