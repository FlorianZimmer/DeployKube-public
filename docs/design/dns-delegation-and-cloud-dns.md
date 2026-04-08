# Design: Optional DNS Delegation + Cloud DNS

Last updated: 2026-03-14
Status: **implemented baseline** (manual + auto delegation, DNSZone API/controller, tenant workload-zone lifecycle, tenant-scoped Vault/ESO RFC2136 credential lifecycle, standalone mode, and DNSEndpoint writer portability implemented; tenant-dedicated authoritative instances are deferred to the future dedicated-cluster tier)

## Tracking

- Canonical tracker: `docs/component-issues/cloud-dns.md`

## Purpose

1. Add **optional DNS delegation** for a deployment’s `spec.dns.baseDomain`, configured via `DeploymentConfig`.
2. Reuse the same delegation machinery for a future **Cloud DNS** feature that can:
   - run “in platform mode” for DeployKube tenants/customers, and
   - run “standalone mode” in a generic Kubernetes cluster (public-cloud style).

## Implementation Status (2026-02-22)

- `DeploymentConfig` contract implemented for:
  - `spec.dns.authority.nameServers`
  - `spec.dns.delegation.mode|parentZone|writerRef`
  - `spec.dns.cloudDNS.tenantWorkloadZones.enabled|zoneSuffix`
- Manual delegation output is now published via `DeploymentConfig.status.dns.delegation`.
- Auto parent-zone delegation reconcile implemented via writer Secret backends:
  - `provider=powerdns`
  - `provider=dnsendpoint` (writes `DNSEndpoint` resources)
  - Additional backends remain intentionally out of scope until a concrete deployment requires them.
- Cloud DNS platform mode implemented:
  - per-tenant workload-zone lifecycle (`<orgId>.workloads.<baseDomain>`)
  - tenant RFC2136 credential lifecycle (Vault issue/rotate + tenant-scoped ESO projection)
- Cloud DNS standalone mode implemented:
  - explicit `dns.darksite.cloud/v1alpha1 DNSZone` reconciliation for arbitrary delegated zones.
- Runtime coverage in proxmox overlay includes a Cloud DNS tenant-zone smoke CronJob.

Traceability evidence:

## Repo Ground Truth (Current State)

DeployKube’s internal DNS chain today is intentionally forwarder-driven (not delegated):

- **CoreDNS** forwards `spec.dns.baseDomain` to PowerDNS (stub-domain).
- **PowerDNS** serves the authoritative zone (records stored in Postgres).
- **external-sync** updates zone glue records (SOA/NS + wildcard + platform endpoints) based on live Gateway VIPs.
- Operator/LAN resolution typically requires a forwarder (Pi-hole/dnsmasq) to forward the base domain to the PowerDNS VIP (`spec.network.vip.powerdnsIP`).

Key repo entrypoints:
- Deployment contract: `platform/gitops/deployments/<deploymentId>/config.yaml`, schema `platform/gitops/deployments/schema.json`
- DNS wiring controller: `tools/tenant-provisioner/internal/controllers/dns_wiring_controller.go`
- external-sync: `platform/gitops/components/dns/external-sync/`
- PowerDNS: `platform/gitops/components/dns/powerdns/`

## Definitions

- **Child zone**: the zone being delegated (in DeployKube: `DeploymentConfig.spec.dns.baseDomain`).
- **Parent zone**: the zone that contains the delegation records (typical: `internal.<domain>`).
- **Delegation**: parent zone `NS` records pointing at the child zone’s nameservers.
- **Glue**: parent zone `A/AAAA` records for in-bailiwick nameserver hostnames (e.g. `ns1.dev.internal.example.com`) required for resolvers to reach the nameservers.

## Goals

- Make delegation **optional** and **explicit** in `DeploymentConfig` (no “magic” defaults that work only in one environment).
- Keep bootstrap boundaries intact: GitOps + controllers converge state after Stage 0/1.
- Prefer KRM-native patterns (CRDs/controllers) over repo-side renderers.
- Support Cloud DNS evolution without cornering ourselves into the `.internal` convention.

## Non-Goals

- Replace CoreDNS stub-domain forwarding as the primary in-cluster resolution path.
- Require a specific parent-zone provider (Cloudflare/Route53/etc.) for first implementation.
- Overhaul the DNS data plane (PowerDNS + Postgres) as part of delegation work.

## Design: DeploymentConfig Extensions

### Contract changes (proposed)

Add two optional blocks under `DeploymentConfig.spec.dns`:

1) `spec.dns.authority` (authoritative identity for the child zone)

- Purpose: define the nameserver hostnames and the network endpoint that answers authoritative DNS for the child zone.
- This is required to make `SOA/NS` records correct and stable (even when delegation is off).

2) `spec.dns.delegation` (parent-zone delegation automation)

- Purpose: describe whether and how to publish delegation records into a parent zone.

Suggested shape (illustrative; final schema should be validated in `platform/gitops/deployments/schema.json` and the CRD):

```yaml
spec:
  dns:
    baseDomain: dev.internal.example.com

    authority:
      # Nameserver FQDNs that should appear in the child zone's NS set.
      # If these are within the parent zone, they can also be used as glue targets.
      nameServers:
        - ns1.dev.internal.example.com
        - ns2.dev.internal.example.com

      # Where those nameserver hostnames should resolve to (authoritative service endpoints).
      # v1: keep it simple and derive from the pinned PowerDNS VIP.
      endpoints:
        - ipFrom:
            fieldRef: spec.network.vip.powerdnsIP

    delegation:
      mode: manual  # none|manual|auto
      parentZone: internal.example.com

      # For 'auto' mode: reference a record-writer backend.
      # This must not inline secrets (credentials live in Vault and are projected via ESO).
      writerRef:
        name: parent-zone-writer
        namespace: dns-system
```

Notes:
- `authority.nameServers` must be treated as **API surface**: changing it is a breaking operational change if delegation is active.
- `authority.endpoints` is intentionally constrained for v1 (use PowerDNS VIP) to avoid a sprawling “dynamic endpoint discovery” contract.

### Why this belongs in DeploymentConfig

Delegation is a deployment identity concern:
- it defines how the platform is discovered from outside the cluster, and
- it must be consistent across every component that publishes DNS-related records or smokes.

Keeping it in `DeploymentConfig` ensures:
- consistent behavior between dev/prod deployments,
- consistent validation and CI guardrails, and
- predictable ownership (controllers reconcile; no ad-hoc scripts).

## Design: Correctness Fixes Required Before Delegation

Before we can delegate `baseDomain`, the child zone’s authority records must reflect reality:

- `external-sync` currently writes `SOA/NS` and also writes the nameserver `A` record using the **Ingress Gateway** IP.
- For delegation, the nameserver host(s) must resolve to the **PowerDNS** VIP (`spec.network.vip.powerdnsIP`), not the ingress IP.

Required refactor:
- Continue writing platform/service `A` records to the ingress VIP (as today).
- Write `SOA/NS` based on `spec.dns.authority.nameServers`.
- Write nameserver `A/AAAA` based on `spec.network.vip.powerdnsIP` (or `spec.dns.authority.endpoints`).

This change is valuable even without delegation:
- it makes DNS data internally coherent,
- it prevents “fake authority” records that will break the moment delegation is enabled.

## Delegation Implementation Strategy

### Phase 1: Manual delegation (no provider dependencies)

When `spec.dns.delegation.mode=manual`, the platform should publish a computed “delegation bundle”:

- Parent zone record set:
  - `NS` record for `<baseDomain>` pointing at `authority.nameServers[]`
  - `A/AAAA` records for each nameserver hostname that is within the parent zone (glue)

Published surface:
- `DeploymentConfig.status.dns.delegation`
  - structured fields for `mode`, `parentZone`, `nameServers`, `authoritativeDNSIP`, and computed parent-zone record sets
  - `manualInstructions[]` only when `mode=manual`

### Phase 2: Auto delegation via record writers

Auto delegation requires writing records into the parent zone.

Current implementation (first backend):
- `spec.dns.delegation.mode=auto` now reconciles parent-zone records through a writer Secret referenced by `spec.dns.delegation.writerRef`.
- Supported writer backend today: `provider=powerdns` via PowerDNS HTTP API.
- Reconciled records:
  - parent-zone `NS` rrset for `<baseDomain>`
  - parent-zone glue `A` rrsets for in-bailiwick nameserver hosts

Writer Secret contract (v1):
- required: `apiUrl`, `apiKey`
- optional: `provider` (`powerdns` default), `serverId` (`localhost` default), `nsTTL` (default `300`), `glueTTL` (default `300`)

Follow-up direction:
- Additional writer backend now implemented: `provider=dnsendpoint` (controller writes `externaldns.k8s.io/v1alpha1 DNSEndpoint` resources for external-dns to publish).
- Keep the same `writerRef` contract shape at the deployment layer.
- Do not add more provider backends until a concrete deployment requires them; today the supported set is intentionally `powerdns|dnsendpoint`.

## Cloud DNS: What It Is (Proposed)

Cloud DNS is a platform capability that provisions and manages authoritative DNS zones and safely delegates update authority to tenants/customers.

### Tenancy Model (Shared vs Per-Tenant Instances)

This document uses **instance** to mean: an authoritative DNS data plane (PowerDNS + zone store) plus the control-plane reconciliation that provisions zones and credentials.

For the initial design, the model is:
- **One Cloud DNS instance per DeployKube deployment (shared)**.
- **Per-tenant isolation via per-tenant zones + per-tenant credentials**, not by running separate authoritative servers per tenant.

If we want “each tenant can have its own Cloud DNS instance” (tenant-dedicated authoritative servers), that is a separate future mode and is intentionally deferred:
- It should not be implemented as an intermediate isolation layer inside the current shared cluster.
- DeployKube’s high-paranoia isolation story is expected to come from fully separate dedicated clusters on dedicated hardware, not from per-tenant PowerDNS instances sharing the same cluster control plane, nodes, and storage.
- Revisit this mode only when the dedicated-cluster product tier exists and Cloud DNS can be designed in that context.

Two modes:

1) **Platform mode (DeployKube tenancy-integrated)**
- Source of truth: `Tenant` / `TenantProject` + `DeploymentConfig`.
- Outcome: a per-tenant/customer zone intended for workload records.

2) **Standalone mode (generic Kubernetes cluster)**
- Source of truth: explicit `DNSZone` objects.
- Outcome: manage any zones you delegate to the cluster’s authoritative DNS endpoints.

## Cloud DNS: Tenant/Customer Workloads Zone

Minimal viable model (platform mode):

- For each tenant `<orgId>`, create a delegated zone:
  - `<orgId>.workloads.<baseDomain>`
- Delegate it from the platform base zone (internal delegation within PowerDNS):
  - Parent: `<baseDomain>` (PowerDNS-hosted)
  - Child: `<orgId>.workloads.<baseDomain>` (PowerDNS-hosted)
- Provide a tenant-scoped credential to update *only* that zone:
  - TSIG key for RFC2136 dynamic updates (stored in Vault path `secret/tenants/<orgId>/sys/dns/rfc2136`, projected via tenant-scoped `ClusterSecretStore/vault-tenant-<orgId>-cloud-dns`)
  - Tenants run `external-dns` (RFC2136 provider) in their own namespace using that TSIG secret.

Why this is a good first cut:
- isolates tenant blast radius by zone boundary,
- uses a standard update protocol (RFC2136) and a standard automation tool (external-dns),
- keeps the platform controller simple (zone lifecycle + credential issuance).

Migration note:
- Today, `dns/external-sync` writes per-tenant wildcard records into the platform base zone.
- Enabling per-tenant zones requires:
  - removing those wildcard records for tenants that are “Cloud DNS enabled”, and
  - (optionally) seeding an initial wildcard in the tenant zone to preserve old behavior until they customize records.

## KRM APIs (Implemented Baseline + Planned Extensions)

To keep this KRM-native, the end-state is CRDs + controllers (no repo-side YAML rendering).

Candidate CRDs (names and groups must follow the `darksite.cloud` API-domain contract):

- `DNSDelegation` (platform-owned; expresses parent/child delegation intent)
- `DNSZone` (standalone mode; expresses a zone hosted by the Cloud DNS service)
- `TenantDNSZone` (platform mode; expresses the per-tenant zone intent, derived or explicit)

Current implementation:
- `DNSZone` (`dns.darksite.cloud/v1alpha1`) is implemented and reconciled by tenant-provisioner.
- Platform mode derives per-tenant `DNSZone` resources from `Tenant` + `DeploymentConfig`.

## Ops / Security Considerations

- Delegation is disabled unless explicitly configured.
  - `spec.dns.delegation.mode` normalizes to `none` when unset.
  - Current deployment profiles pin `mode=manual`; they do not auto-publish parent-zone records.
- Delegating a zone means exposing authoritative DNS (UDP/TCP 53) to whatever clients the parent zone serves.
  - For home-lab/LAN this is fine with explicit NetworkPolicy and firewalling.
  - For internet-exposed usage, rate limiting and broader hardening are required (out of scope for initial plan).
- Current proxmox baseline is deliberately narrow:
  - DNS ingress is limited by `NetworkPolicy/dns-system/powerdns-allow-lan-dns` to explicit LAN/VPN CIDRs.
  - PowerDNS API ingress is limited by `NetworkPolicy/dns-system/powerdns-allow-api` to specific in-cluster reconcilers and smokes.
  - Any deployment that wants broader delegated-authority reachability must add deployment-specific firewall policy and abuse controls as an explicit change with evidence.
- Credentials:
  - Parent-zone provider tokens (for auto delegation) must live in Vault, projected via ESO.
  - Tenant update credentials must be per-zone, not shared, and rotated with evidence.
  - Tenant RFC2136 credentials now use a tenant-scoped Vault policy/store path (`vault-tenant-<orgId>-cloud-dns`).
- Avoid IP ambiguity:
  - `spec.network.vip.powerdnsIP` must be stable and non-conflicting (MetalLB pool collisions are a known class of failure).

## Validation / Evidence Plan

Repo/CI:
- Extend `tests/scripts/validate-deployment-config*.sh` to validate new schema fields (once implemented).

Runtime:
- Add/extend smoke jobs to verify:
  - `SOA/NS` correctness (nameserver hostnames match `DeploymentConfig`)
  - nameserver `A/AAAA` points at PowerDNS VIP (not ingress VIP)
  - (when delegation is enabled) resolution works via the parent-zone resolver path (optional and environment-specific)

Evidence:
- Each behavioral cutover ships with `docs/evidence/YYYY-MM-DD-...md` referencing:
  - config contract changes,
  - reconciler changes,
  - smoke output verifying the new invariants.
