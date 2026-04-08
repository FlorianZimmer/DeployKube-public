# `tenancy.darksite.cloud` API group

Product-owned multitenancy intent APIs.

Controllers (implemented in `tools/tenant-provisioner`):
- `tenant-networking-controller` reconciles Tenant → tenant gateways/certificates and related resources.
- `tenant-cloud-dns` reconciles Tenant → tenant workload DNSZone objects (when enabled).
- `tenant-egress-proxy-controller` reconciles TenantProject → egress proxy namespace/service + policy.
- `tenant-forgejo-controller` reconciles TenantProject → Forgejo org/repo wiring (when enabled).

Installed from:
- CRDs: `platform/gitops/components/platform/tenant-provisioner/base/*.yaml`
- Controller(s): `platform/gitops/components/platform/tenant-provisioner`

Versions:
- `v1alpha1`

