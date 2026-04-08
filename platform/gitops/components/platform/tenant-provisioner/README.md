# Tenant provisioner (v1alpha1) — controller scaffolding

Status: **early implementation**

This component will host the DeployKube **Tenant API** (CRDs) and the **tenant provisioner** controllers.

API group:
- Canonical: `tenancy.darksite.cloud/v1alpha1` (`Tenant`, `TenantProject`)

Initial milestone (Queue #11 / Tier S):
- Replace the repo-rendered Istio `Gateway` overlays with controller-owned `Gateway` reconciliation.
- Replace per-tenant wildcard `Certificate` overlays with controller-owned `Certificate` reconciliation.
- Provision Forgejo tenant orgs/repos from `TenantProject` and seed a minimal repo skeleton.
- Canary tenant: `factorio`.

Cloud DNS additions (2026-02-22):
- `dns.darksite.cloud/v1alpha1 DNSZone` CRD/controller for standalone zone lifecycle.
- Tenant platform-mode Cloud DNS reconciler:
  - derives `<orgId>.workloads.<baseDomain>` zones from `Tenant` + `DeploymentConfig`,
  - auto-delegates from `<baseDomain>`,
  - manages tenant DNS credential projection via `ClusterExternalSecret`.

Design / tracker:
- `docs/design/tenant-provisioning-controller.md`
- `docs/component-issues/tenant-provisioner.md`
