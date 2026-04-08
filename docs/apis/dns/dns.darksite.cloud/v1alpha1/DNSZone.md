# API Reference: `DNSZone` (`dns.darksite.cloud/v1alpha1`)

## Summary

- Group/version/kind: `dns.darksite.cloud/v1alpha1`, `DNSZone`
- Scope: cluster-scoped
- Reconciler/controller: `cloud-dns-zone` (in `tools/tenant-provisioner`)
- Installed from: `platform/gitops/components/platform/tenant-provisioner`

## When to use this

Use `DNSZone` to declare an authoritative DNS zone that the platform should host and keep converged (SOA/NS + optional A records + optional delegation).

## Spec (operator-relevant fields)

`spec.zoneName` (string, required)
- Zone FQDN hosted by the platform’s authoritative DNS.

`spec.zoneWriterRef` (optional)
- Secret reference to the authoritative backend writer (defaults to `dns-system/powerdns-api`).

`spec.authority.nameServers` (optional)
- Nameserver hostnames for the zone’s NS set. If omitted, the controller will derive defaults (implementation-defined).

`spec.authority.ip` (optional)
- Authoritative nameserver IP used for glue/extra records where applicable.

`spec.records.wildcardARecordIP` (optional)
- If set, controller ensures a wildcard A record points at this IP.

`spec.delegation` (optional)
- `mode`: `none`, `manual`, `auto`
- `parentZone`: required when `mode=auto`; must be a parent of `zoneName`
- Optional `writerRef`: credentials to reconcile parent-zone delegation (defaults to `zoneWriterRef`)

> For the full schema, see the CRD: `platform/gitops/components/platform/tenant-provisioner/base/dns.darksite.cloud_dnszones.yaml`.

## Status

`DNSZone` is currently treated as a desired-state object; the controller requeues periodically and relies on logs/alerts/evidence for convergence proof. Do not depend on `.status` unless explicitly added in a future API revision.

## Examples

Minimal example:

```yaml
apiVersion: dns.darksite.cloud/v1alpha1
kind: DNSZone
metadata:
  name: prod-internal
spec:
  zoneName: prod.internal.example.com
```

