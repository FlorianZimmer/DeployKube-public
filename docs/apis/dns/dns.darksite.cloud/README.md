# `dns.darksite.cloud` API group

Product-owned DNS intent APIs (authoritative zones + delegation).

Controllers (implemented in `tools/tenant-provisioner`):
- `cloud-dns-zone` reconciles `DNSZone` objects into an authoritative backend (PowerDNS today) and optional parent-zone delegation.

Installed from:
- CRD: `platform/gitops/components/platform/tenant-provisioner/base/dns.darksite.cloud_dnszones.yaml`
- Controller: `platform/gitops/components/platform/tenant-provisioner`

Versions:
- `v1alpha1`

