# Evidence (2026-01-29): Tenant provisioner scaffolding for renderer retirement

This change starts the implementation work to retire repo-side renderers by moving intent into CRDs and reconciling derived resources via controllers (KRM-native).

Status update (2026-01-29):
- The tenant egress proxy has since been cut over to controller-owned reconciliation. The specific cutover note is omitted from the public mirror.
- Platform ingress Certificates have since been cut over to controller-owned reconciliation. Evidence: `docs/evidence/2026-01-29-platform-ingress-certificates-controller-cutover.md`.

## What changed (repo)

### Tenant egress proxy (replacement for `render-egress-proxy.sh`)
- Extended the **Tenant API** `TenantProject` CRD (`deploykube.dev/v1alpha1`) with `spec.egress.httpProxy.allow[]` intent.
  - CRD: `platform/gitops/components/platform/tenant-provisioner/base/deploykube.dev_tenantprojects.yaml`
  - Types: `tools/tenant-provisioner/internal/api/v1alpha1/tenantproject_types.go`
- Added an **egress-proxy controller** that computes desired outputs from `TenantProject` and (when enabled) can reconcile the per-org/per-project proxy resources.
  - Controller: `tools/tenant-provisioner/internal/controllers/egress_proxy_controller.go`
  - Default posture: **observe-only** (status/outputs computed; no cluster writes).
- Seeded the smoke TenantProject with egress intent to match the existing allowlist fixture:
  - `platform/gitops/apps/tenant-api/base/tenant-smoke.yaml`

### Platform ingress Certificates (replacement for `render-certificates-ingress.sh`)
- Added an **observe-only controller** that computes the platform ingress `Certificate` set from the DeploymentConfig snapshot ConfigMap (`argocd/deploykube-deployment-config`).
  - Controller: `tools/tenant-provisioner/internal/controllers/platform_ingress_certificates_controller.go`
  - Default posture: **observe-only** (logs desired cert set; no cluster writes).

### Access-plane plumbing (required for eventual cutover)
- Updated controller RBAC to include `tenantprojects` read + status write and the resource verbs needed to reconcile egress-proxy objects when observe-only is turned off:
  - `platform/gitops/components/platform/tenant-provisioner/base/rbac.yaml`

## Safety posture (today)
- Egress proxy: cut over (controller-owned writes enabled; legacy renderer removed). The specific cutover note is omitted from the public mirror.
- Ingress certificates: cut over (controller-owned writes enabled; legacy renderer removed). Evidence: `docs/evidence/2026-01-29-platform-ingress-certificates-controller-cutover.md`.

## Follow-ups (next PRs)
- Repeat for DNS overlays, ingress-adjacent overlays, and Loki deployment-config rendering.
