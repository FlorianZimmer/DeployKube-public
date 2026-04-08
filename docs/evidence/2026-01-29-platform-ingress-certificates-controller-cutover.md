# Evidence: Platform ingress Certificates cutover to controller-owned reconciliation

EvidenceFormat: v1

Date: 2026-01-29
Environment: repo-only

Scope / ground truth:
- Repo-side evidence only (GitOps sources + validators). No live cluster claims in this note.
- Goal: retire repo-side "render then commit" overlays for platform ingress Certificates.
- Platform ingress Certificates are reconciled by the tenant provisioner controller from the DeploymentConfig snapshot ConfigMap.

Git:
- Commit: 8faaa1c8

Argo:
- Root app: platform-apps
- Sync/Health: not verified (repo-only)
- Revision: not verified (repo-only)

## What changed

- Enabled controller apply-mode for platform ingress Certificates:
  - `platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml` includes `--platform-ingress-certs-observe-only=false`
- Disabled the legacy Argo app in all supported deployments:
  - `platform/gitops/apps/environments/mac-orbstack/values-overlay.yaml`
  - `platform/gitops/apps/environments/mac-orbstack-single/values-overlay.yaml`
  - `platform/gitops/apps/environments/proxmox-talos/values-overlay.yaml`
- Removed repo-side renderer artifacts:
  - deleted: `scripts/deployments/render-certificates-ingress.sh`
  - deleted: `platform/gitops/components/certificates/ingress/overlays/<deploymentId>/*.yaml`
  - deleted: `tests/scripts/validate-certificates-ingress.sh`
- Replaced drift validator with controller cutover validator:
  - added: `tests/scripts/validate-certificates-ingress-controller-cutover.sh`
  - wired via: `tests/scripts/ci.sh` (deployment-contracts suite)

## Commands / outputs

```bash
./tests/scripts/ci.sh deployment-contracts
```

Output:

```text
evidence note lint PASSED
overlay-apps validation PASSED
certificates/ingress controller cutover validation PASSED
```
