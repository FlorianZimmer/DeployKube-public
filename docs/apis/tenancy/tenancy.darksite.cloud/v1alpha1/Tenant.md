# API Reference: `Tenant` (`tenancy.darksite.cloud/v1alpha1`)

## Summary

- Group/version/kind: `tenancy.darksite.cloud/v1alpha1`, `Tenant`
- Scope: cluster-scoped
- Reconciler/controller(s): `tools/tenant-provisioner` (Tenant controllers)
- Installed from: `platform/gitops/components/platform/tenant-provisioner`

## When to use this

Use `Tenant` to declare a tenant org boundary (`spec.orgId`) and its tier/lifecycle intent. Controllers reconcile downstream “platform-owned” resources for that tenant.

## Spec (operator-relevant fields)

`spec.orgId` (string, required)
- Stable tenant org identifier (used in labels, Vault paths, and GitOps tenant folder names).

`spec.tier` (enum, required)
- Tenancy tier (currently `S` or `D`).

`spec.lifecycle` (optional)
- `retentionMode`: `immediate`, `grace`, `legal-hold`
- `deleteFromBackups`: `retention-only`, `tenant-scoped`, `strict-sla`

## Status

`status.conditions`
- Standard Kubernetes conditions indicating reconciliation state.

`status.outputs`
- Derived resource references and resolved hostnames/DNSNames for tenant-facing networking surfaces.
- `outputs.resources` may include a list of downstream objects created/owned by the platform for this tenant.

> For the full schema, see the CRD: `platform/gitops/components/platform/tenant-provisioner/base/tenancy.darksite.cloud_tenants.yaml`.

## Examples

Minimal example:

```yaml
apiVersion: tenancy.darksite.cloud/v1alpha1
kind: Tenant
metadata:
  name: smoke
spec:
  orgId: smoke
  tier: S
```

## Upgrade / migration notes

- `v1alpha1` is incubating. Expect migrations when the tenancy model evolves (and record evidence).

