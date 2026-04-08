# DNS Authority and Sync Design

Status: Design + implementation

## Tracking

- Canonical tracker: `docs/component-issues/powerdns.md`
- Related trackers:
  - `docs/component-issues/coredns.md`
  - `docs/component-issues/external-sync.md`
- Related planned work:
  - Optional delegation + Cloud DNS: `docs/design/dns-delegation-and-cloud-dns.md`
- Related docs:
  - `docs/design/deployment-config-contract.md`
  - `docs/design/multitenancy-networking.md`

## Purpose

Define the platform DNS chain, including in-cluster resolution (CoreDNS), authoritative zone management (PowerDNS), and external record synchronization.

## Scope

In scope:
- Resolution and authority boundaries among CoreDNS, PowerDNS, and external-sync.
- Deployment-config-driven DNS contracts.
- Operational smoke and drift-detection expectations.

Out of scope:
- End-user workstation DNS setup specifics (kept in operator guides).
- Tenant ingress policy contracts beyond DNS ownership assumptions.

## DNS topology

1. CoreDNS (cluster resolver):
- Handles `cluster.local` and forwards configured internal zones to authoritative DNS.
- GitOps seeds a marker-delimited stub-domain block in `ConfigMap/kube-system/coredns`; `tenant-provisioner` reconciles the live block from deployment config (`spec.dns.baseDomain`, `spec.network.vip.powerdnsIP`).

2. PowerDNS (authoritative):
- Owns internal platform zones and record API updates.
- Serves authoritative answers for platform base domain records.

3. External sync:
- Reconciles target records from platform intent into authoritative DNS state.
- Publishes wildcard/base records required by ingress and platform endpoints.

## Ownership boundaries

- CoreDNS is platform-internal DNS plumbing; consumers should not bypass it for in-cluster lookups.
- PowerDNS API and schema/bootstrap flows are platform-owned.
- DNS sync automation is platform-owned and should remain idempotent.

## Implementation map (repo)

- CoreDNS component: `platform/gitops/components/networking/coredns/`
- PowerDNS component: `platform/gitops/components/dns/powerdns/`
- External sync component: `platform/gitops/components/dns/external-sync/`
- DNS wiring controller: `tools/tenant-provisioner/internal/controllers/dns_wiring_controller.go`
- Deployment config DNS inputs: `platform/gitops/deployments/*/config.yaml`

## Invariants

- Deployment DNS hostnames and base domain are authoritative inputs for published records.
- CoreDNS forwarding for internal platform zones remains deterministic and non-circular.
- The committed CoreDNS manifest may keep placeholder stub-block values in Git, but only the marker-delimited block is mutated at runtime and the mutation path is repo-owned (`tenant-provisioner`), not manual.
- Phase 1 of the CoreDNS upgrade-drift plan keeps full ConfigMap replacement but requires the committed non-managed root block to match the curated baseline in `platform/gitops/components/networking/coredns/upstream-corefile-baseline.yaml`.
- DNS sync behavior remains safe to re-run and auditable via status/smokes.

## Validation and evidence

Primary signals:
- CoreDNS smoke validates cluster + forwarded name resolution.
- `./tests/scripts/validate-coredns-upstream-corefile-contract.sh` flags drift between the committed CoreDNS root block and the curated upstream baseline during review/CI.
- PowerDNS DNS/HTTP smoke validates authoritative API and record serving.
- external-sync verification asserts expected record values after reconcile.
