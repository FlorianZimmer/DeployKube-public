# API Reference: `TenantProject` (`tenancy.darksite.cloud/v1alpha1`)

## Summary

- Group/version/kind: `tenancy.darksite.cloud/v1alpha1`, `TenantProject`
- Scope: cluster-scoped
- Reconciler/controller(s): `tools/tenant-provisioner` (project controllers)
- Installed from: `platform/gitops/components/platform/tenant-provisioner`

## When to use this

Use `TenantProject` to declare a project inside a tenant (`spec.tenantRef` + `spec.projectId`) and opt into project-level capabilities (Git org/repo wiring, egress proxy policy, Argo scoping mode).

## Spec (operator-relevant fields)

`spec.tenantRef.name` (string, required)
- References the owning `Tenant` by name.

`spec.projectId` (string, required)
- Stable project identifier (used in labels, namespaces, and Vault paths).

`spec.environments` (array, required)
- Environment IDs this project participates in (for example `dev`, `prod`).

`spec.git` (object, required)
- `repo` (required): tenant repo name
- Optional: `forgejoOrg`, `seedTemplate`

`spec.egress.httpProxy.allow` (optional)
- Allowlist entries for HTTP proxy egress, each with `type` (`exact`/`suffix`) and `value`.

`spec.argo.mode` (optional)
- `org-scoped` or `project-scoped`

## Status

`status.conditions`
- Standard Kubernetes conditions indicating reconciliation state.

`status.outputs`
- `forgejo`: derived org/repo/repoURL
- `egressProxy`: derived namespace/service and observe-only/proxyEnabled flags

> For the full schema, see the CRD: `platform/gitops/components/platform/tenant-provisioner/base/tenancy.darksite.cloud_tenantprojects.yaml`.

## Examples

Minimal example:

```yaml
apiVersion: tenancy.darksite.cloud/v1alpha1
kind: TenantProject
metadata:
  name: demo
spec:
  tenantRef:
    name: smoke
  projectId: demo
  environments:
    - prod
  git:
    repo: demo
```

