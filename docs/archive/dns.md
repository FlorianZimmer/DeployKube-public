# Feature Request: DNS Delegation + "Cloud DNS"

Status: **implemented baseline** (2026-02-22; all Phase A-E acceptance criteria met, with proxmox deployment remaining on `spec.dns.delegation.mode=manual`)

## Summary

Add an **optional DNS delegation** feature that can be enabled via `DeploymentConfig`, so a deployment’s `spec.dns.baseDomain` can be resolved via normal DNS delegation (parent zone `NS` records) instead of relying on operator/LAN forwarders (Pi-hole/dnsmasq/CoreDNS stub-domain only).

Use the same delegation machinery later for a **Cloud DNS** capability:
- In “platform mode”, create a per-tenant/customer zone for workloads and let the tenant manage records safely.
- In “standalone mode” (public-cloud style), run Cloud DNS as an authoritative DNS service that can manage any zones delegated to it.

Tenancy model (explicit):
- v1 assumes **one shared Cloud DNS instance per deployment** with **per-tenant zones + per-tenant credentials**.
- “Per-tenant dedicated Cloud DNS instances” (separate authoritative servers per tenant) is possible later, but is not required for tenant DNS autonomy and materially increases ops complexity.

## Problems This Solves

- **Operator toil / drift:** today, workstation/LAN DNS forwarding (Pi-hole/dnsmasq) must be configured correctly per deployment; drift breaks access even when the platform is healthy.
- **Multi-customer enablement:** customers often want to delegate a sub-zone to the platform to manage app records themselves (or via automation like `external-dns`), without giving them access to the parent zone.
- **Portable Cloud DNS:** run the same feature in clusters that don’t share DeployKube’s internal `.internal` convention.

## Non-Goals

- Replace the existing internal DNS chain (CoreDNS → PowerDNS) or the `dns/external-sync` convergence logic immediately.
- Build a full DNS UI.
- Support every public DNS provider on day 1 (provider integrations should be incremental).

## Proposal (High Level)

1. **Make authoritative DNS identity explicit** in the deployment contract (nameserver hostnames + authoritative endpoint IP), and make PowerDNS’ zone `SOA/NS` reflect that.
2. **Optional delegation automation**:
   - `mode: manual`: compute and publish “records to create” for the parent zone (operator applies them).
   - `mode: auto`: reconcile delegation records in the parent zone via a provider integration.
3. **Cloud DNS**:
   - Provide a KRM-native API for declaring zones and who may update them.
   - For “tenant/customer workloads”, automatically provision a per-tenant zone and delegate it from the platform base zone (or from an external parent zone when configured).

## Implementation Plan (Phased)

### Phase A: DeploymentConfig Contract + DNS Record Correctness

- Extend `platform.darksite.cloud/v1alpha1 DeploymentConfig` with an optional DNS authority/delegation block:
  - `spec.dns.authority` (nameserver hostnames, authoritative IP source)
  - `spec.dns.delegation` (parent zone + mode + provider reference)
- Update the existing DNS reconcilers so the **child zone**’s `SOA/NS` is consistent with configured nameservers.
  - Today, `dns/external-sync` writes `SOA/NS` and also sets the nameserver `A` record using the Ingress IP; this must be split so:
    - app/service `A` records continue to point at the ingress VIP
    - nameserver `A` records (and delegation glue) point at the PowerDNS VIP (`spec.network.vip.powerdnsIP`)

Acceptance criteria:
- Internal resolution and existing smokes remain green.
- The zone’s `SOA/NS` becomes a stable “real” authority description (even if delegation is still off).

### Phase B: Delegation (Manual Mode)

- When `spec.dns.delegation.mode=manual`, compute the exact parent-zone records required and publish them as:
  - `DeploymentConfig.status` (preferred, once status is used broadly), and/or
  - a controller-owned `ConfigMap` for operator visibility (e.g. `argocd/deploykube-dns-delegation`).

Records required (typical):
- Parent zone `NS` record for `<baseDomain>` pointing at `<nameserver hostnames>`
- Parent zone `A/AAAA` “glue” records for any in-bailiwick nameserver hostnames

Acceptance criteria:
- Operator has copy/paste-able delegation instructions grounded in live deployment config values (no hand-rolled docs).

### Phase C: Delegation (Auto Mode, Provider Integrations)

- Add a provider-backed reconciler for parent zone updates.
- Integrations implemented:
  - `provider=powerdns` via `spec.dns.delegation.writerRef` Secret.
  - `provider=dnsendpoint` using `external-dns` CRD (`DNSEndpoint`) writer pattern for multi-provider portability.

Acceptance criteria:
- Enabling `spec.dns.delegation.mode=auto` results in parent-zone records converging without manual steps.

### Phase D: Cloud DNS (Platform Mode: Tenant/Customer Workloads)

- KRM API implemented: `dns.darksite.cloud/v1alpha1 DNSZone`.
- Platform mode reconciler derives per-tenant DNSZones from `Tenant` + `DeploymentConfig`.
- Controller provisions per-tenant workload zones in PowerDNS and hands out update credentials via Vault + ESO.

Baseline behavior (minimal viable):
- For tenant `<orgId>`, ensure zone: `<orgId>.workloads.<baseDomain>` exists in PowerDNS.
- Delegate that zone from the platform base zone (PowerDNS-to-PowerDNS internal delegation).
- Publish a tenant-scoped credential for RFC2136 updates (TSIG), so tenants can run their own `external-dns` (RFC2136 provider) in their namespace without cross-tenant blast radius.

Acceptance criteria:
- A tenant can create/update records in their own zone without being able to affect other tenants or the platform base zone.

### Phase E: Cloud DNS (Standalone Mode)

- Allow a cluster admin to declare arbitrary zones to host/manage, without DeployKube tenancy concepts.
- Delegation remains optional:
  - “manual delegation” instructions for registrars/parent zones
  - “auto delegation” when a provider integration exists

Acceptance criteria:
- Cloud DNS can run as a reusable component in a cluster that has no DeployKube `Tenant` resources and no `.internal` convention (implemented via explicit `DNSZone` resources).

## Acceptance Criteria Closure (2026-02-22)

- **Phase A — met**
  - Deployment contract + API implemented for `spec.dns.authority` and `spec.dns.delegation`.
  - `dns/external-sync` now uses explicit authority inputs (`SOA/NS` and nameserver `A`) decoupled from ingress VIP records.
  -
- **Phase B — met**
  - Manual mode output implemented via `ConfigMap/argocd/deploykube-dns-delegation`.
  -
- **Phase C — met**
  - Auto delegation parent-zone reconcile implemented for `provider=powerdns`.
  - Multi-backend portability implemented for `provider=dnsendpoint`.
  -
- **Phase D — met**
  - Platform mode derives per-tenant workload zones (`<orgId>.workloads.<baseDomain>`) and reconciles tenant RFC2136 credentials lifecycle through Vault + ESO.
  -
- **Phase E — met**
  - Standalone mode works via explicit `DNSZone` resources in clusters independent of DeployKube `Tenant` CRs.
  -

## Tracking

- Tracker: `docs/component-issues/cloud-dns.md`
- Related current DNS design: `docs/design/dns-authority-and-sync.md`
