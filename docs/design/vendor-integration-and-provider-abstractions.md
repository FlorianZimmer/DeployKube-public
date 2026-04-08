# Design: Vendor Integration & Provider Abstractions (KRM-first)

## Tracking

- Canonical tracker: `docs/component-issues/cloud-productization-roadmap.md`

## Problem statement

DeployKube needs to integrate with “things outside Kubernetes” (storage appliances, BMCs/Redfish, HSMs, etc.) without baking vendor-specific APIs and semantics into the Kubernetes-facing contract.

Concrete trigger: the backup plane needs “snapshotting/retention” semantics, but today the actual backup target is a Synology NAS. Future installs may use a different NAS, an enterprise array, an HSM-backed key service, or an on-prem BMC fleet. If the platform API depends directly on any one vendor API, we create migration pain and operational lock-in.

## Goal

Provide a **stable KRM API surface** in the `darksite.cloud` domain that:
- expresses intent (what we want) rather than implementation (how vendor X does it),
- supports multiple vendor implementations under the hood,
- allows swapping providers with controlled migrations,
- keeps GitOps/evidence discipline intact (contracts, validation, and operational runbooks live in-repo).

## Non-goals

- Replace Kubernetes’ native vendor interfaces where they already exist (e.g. CSI for PV provisioning).
- Build a full “infrastructure as code” engine. The abstraction scope is limited to platform-owned integrations required for operating DeployKube safely.
- Promise perfect portability for semantics that are inherently vendor-specific. The platform contract must acknowledge capability differences explicitly.

## Reuse-first rule (do not wrap what Kubernetes already standardizes)

Before introducing a DeployKube-owned API, we explicitly walk this ladder:

1) **Kubernetes core (built-in) APIs** (e.g. `Service`, `Ingress`, `NetworkPolicy`, `StorageClass`, `PersistentVolumeClaim`)
2) **Kubernetes SIG-sponsored KRM APIs** (typically CRDs, but “standard”):
   - Gateway API (`gateway.networking.k8s.io`)
   - Volume Snapshots (`snapshot.storage.k8s.io`)
3) **Widely adopted vendor-agnostic KRM APIs** (not core, but stable and portable enough in practice):
   - cert-manager (`cert-manager.io`) for certificate intent and issuance workflows
   - External Secrets Operator (`external-secrets.io`) for secret materialization from Vault/other backends
   - Cluster API / Metal3 (for cluster + bare-metal lifecycle) when we actually want “cluster lifecycle as API”
4) **Only if none of the above fit:** define a DeployKube PAL API in `*.darksite.cloud`.

Design intent: if a vendor-agnostic KRM API already exists, we should *implement against it* (or adopt an upstream controller), not create a parallel DeployKube-specific CRD that re-states the same abstraction.

## Abstraction-layer catalog (full hardware implementation)

Goal: list the “types of abstraction layers” we will likely need if DeployKube grows into a full hardware-backed platform, while keeping the rule above: **prefer existing vendor-agnostic KRM APIs first**.

Each row is a candidate **abstraction layer type**. The “PAL fallback” column is what we would introduce *only if* no suitable vendor-agnostic KRM API exists for the intent.

| Abstraction layer type | What it configures / owns | Prefer existing KRM API (if it exists) | PAL fallback (DeployKube-owned KRM) |
| --- | --- | --- | --- |
| Cluster lifecycle | Cluster create/scale/upgrade; control-plane and node pools | Cluster API (CAPI) | `hardware.darksite.cloud` cluster-lifecycle resources only if CAPI is insufficient |
| Bare-metal provisioning | Host enrollment, imaging, cleaning, PXE-ish flows | Metal3 / Ironic-style KRM (via CAPI provider-metal3) | `hardware.darksite.cloud` `BareMetalHost`-like contract + `HardwareProvider` drivers |
| Out-of-band mgmt (BMC) | Power on/off/cycle, boot device, inventory via Redfish/IPMI | (No Kubernetes standard KRM API; prefer Redfish as protocol standard) | `hardware.darksite.cloud` `BMC`, `PowerAction`, `BootPolicy`, `HardwareInventory` |
| Firmware + BIOS policy | BIOS settings, firmware versions, secure boot, TPM state | (No Kubernetes standard KRM API; prefer Redfish schema model where possible) | `hardware.darksite.cloud` `FirmwarePolicy`, `FirmwareUpdate`, `BiosPolicy`, `AttestationPolicy` |
| Server-local storage layout | RAID/HBA mode, boot disks, NVMe namespaces | (No Kubernetes standard KRM API) | `hardware.darksite.cloud` `DiskLayoutPolicy`, `RaidPolicy` |
| Device identity + access | Device accounts/roles (switch/BMC), RADIUS/TACACS, API tokens | (No Kubernetes standard KRM API) | `access.darksite.cloud` `DeviceIdentity`, `DeviceCredentialPolicy` (credentials always via Secret refs) |
| Physical networking (fabric) | Switch ports, VLANs, LAG/MLAG, EVPN/VXLAN, ACLs | (No Kubernetes standard KRM API) | `network.darksite.cloud` `Switch`, `SwitchPort`, `VLAN`, `FabricPolicy` |
| Routing + BGP policy | ToR/BGP peering, route policies, aggregates | (No Kubernetes standard KRM API; in-cluster BGP is typically via CNI/MetalLB APIs) | `network.darksite.cloud` `BGPPeer`, `BGPPolicy` (for *physical* network intent) |
| Load balancing (edge) | L4/L7 VIPs, pools, health checks at the edge | Prefer `Service`/`Ingress`/Gateway API + an implementation (MetalLB, gateway controller, etc.) | Avoid new PAL unless we truly need edge config that cannot be expressed via Gateway/Service; then: `network.darksite.cloud` `EdgeLoadBalancer` |
| IP address management | IP pools, reservations, DHCP scopes, static assignments | (No Kubernetes core IPAM KRM; CNI-specific IPAM is implementation detail) | `ipam.darksite.cloud` `IPPool`, `IPReservation`, `DHCPPolicy` |
| DNS zones + records | Authoritative zones, record lifecycle, delegation | Prefer ExternalDNS patterns / existing platform DNS controllers when sufficient | `dns.darksite.cloud` `DNSZone`, `DNSRecordSet` (if/when we need explicit zone ownership semantics) |
| PKI for infra devices | Device TLS certs, CA trust roots, rotation | Prefer cert-manager (`Certificate`, Issuer/ClusterIssuer) | Only if cert-manager cannot represent it: `pki.darksite.cloud` device-certificate intent resources |
| Storage provisioning | Block/file PV provisioning, snapshots, expansion | Prefer CSI + Volume Snapshot API | Avoid PAL for PV lifecycle; PAL may still exist for “backup targets” or array-side policies not covered by CSI |
| Object storage provisioning | Buckets, credentials, lifecycle policies | Prefer a vendor-agnostic KRM API if adopted (e.g. COSI-style bucket APIs) | `storage.darksite.cloud` `Bucket`, `BucketPolicy` (only if no acceptable vendor-agnostic KRM exists) |
| External backup targets | NAS/object-store endpoints used by the backup plane | (No core KRM API for “backup target”) | `storage.darksite.cloud` `BackupTarget`, `RetentionPolicy`, `SnapshotPolicy` + providers |
| Power distribution | PDUs, outlets, power budgets, remote reboot | (No Kubernetes standard KRM API) | `power.darksite.cloud` `PDU`, `Outlet`, `PowerBudget`, `PowerAction` |
| Environmental sensors | UPS, temp sensors, rack telemetry (mostly read-only) | (No Kubernetes standard KRM API) | `facility.darksite.cloud` `Sensor`, `SensorReading` (prefer read-only reconciliation) |
| Asset inventory + topology | Racks, locations, devices, cabling, ownership | (No Kubernetes standard KRM API; often handled by NetBox/CMDB) | `asset.darksite.cloud` `Rack`, `Device`, `Link`, `Location` (only if we want KRM to be the source of truth) |

Notes:
- Some rows are intentionally “prefer existing” rather than “invent new”: e.g. **load balancing and storage PV lifecycle** should stay expressed in Kubernetes-native APIs wherever possible.
- When a row says “no Kubernetes standard KRM API”, we still prefer a **protocol/industry standard** (e.g. Redfish) to reduce driver complexity and avoid binding the contract to any one vendor.

## Design principle: Provider Abstraction Layer (PAL)

We standardize on a pattern:

1) **Vendor-agnostic CRDs (“the contract”)** define desired state and status in a single, stable API group.
2) **Provider CRDs (“the wiring”)** describe how to talk to an external system (endpoint, auth reference, capabilities, policy).
3) **Provider controllers (“the drivers”)** reconcile the vendor-agnostic CRDs by calling the vendor API, but only through the PAL contract.

This gives us the same shape across domains:
- storage snapshotting / backup targets,
- hardware management (Redfish/BMC power, firmware inventory),
- HSM/key custody (key generation, signing, rotation, deletion semantics),
- and future vendor APIs we adopt.

## API groups and naming

Follow DeployKube’s API-group scheme: `<area>.darksite.cloud`.

Rule: **one API group per abstraction layer type** (storage vs hardware vs power, etc.). Avoid “one giant infra API” that mixes concerns.

Common candidates (illustrative, not exhaustive):
- `storage.darksite.cloud` — backup targets, retention/snapshot intent not covered by CSI
- `hardware.darksite.cloud` — BMC/Redfish intent (power, boot policy, firmware, inventory)
- `network.darksite.cloud` — fabric/switch/routing intent for *physical* network configuration
- `ipam.darksite.cloud` — IP pools/reservations/DHCP intent
- `power.darksite.cloud` — PDU/UPS/power actions and budgets
- `asset.darksite.cloud` — inventory/topology (only if we choose KRM as source of truth)

Examples (illustrative, not exhaustive):
- `storage.darksite.cloud/v1alpha1`:
  - `StorageProvider` (the wiring)
  - `BackupTarget` (NFS/S3-compatible backup destinations as “targets”, not a specific appliance)
  - `SnapshotPolicy` / `RetentionPolicy`
  - `Snapshot` / `Restore` (long-running operations as resources)

If we need key custody beyond “use Vault + ESO”:
- `keys.darksite.cloud/v1alpha1`:
  - `KeyProvider` (HSM/backends)
  - `Key`, `KeyPolicy`, `SigningRequest`, `KeyRotation` (names illustrative)

## Capability-aware contracts (portability without lying)

Portability only works if the contract can represent differences.

Pattern:
- Provider advertises `status.capabilities` (e.g. `supportsSnapshots`, `supportsWORM`, `supportsImmutableRetention`, `supportsObjectLock`, `supportsPowerCycle`, `supportsAttestation`).
- Reconciler sets conditions on vendor-agnostic resources (`Supported`, `Ready`, `Degraded`, `Blocked`) with explicit `reason`/`message`.
- The API contract defines **required vs optional** features per use case (e.g. backups must be restorable; WORM is optional until later).

This prevents the “partial portability trap” where a vendor swap silently degrades a safety property.

## Secrets and credentials

Provider resources must not embed credentials.

Standard pattern:
- Provider spec references a Kubernetes `Secret` projected via ESO+Vault (or other approved custody path).
- Controllers use those credentials at runtime; the KRM resources remain non-secret.
- Breakglass or offline keys remain separate and must follow existing custody/runbook discipline.

## Reconciliation model

Two supported implementation styles (choose per domain):

1) **Single reconciler with pluggable providers** (one controller binary, multiple provider backends):
   - Pros: shared logic, consistent status, fewer moving parts.
   - Cons: larger binary, more complex release cadence.

2) **Multiple reconcilers keyed by provider type** (separate controllers per vendor or per domain):
   - Pros: isolation, independent rollout.
   - Cons: harder to guarantee identical status semantics; requires strict interface tests.

In both styles, the vendor-agnostic resources select a provider explicitly (e.g. `spec.providerRef`).

## GitOps and evidence discipline

Vendor integrations must remain GitOps-first:
- CRDs and controllers are installed via a platform-owned GitOps component (CRDs before CRs).
- Changes to contracts (CRDs) require migration planning and evidence.
- Runtime invariants are validated via validation jobs/smokes where possible (e.g. “snapshot/restore completes”, “power cycle works in a safe sandbox”, “key deletion is irreversible”).

## Example: “snapshotting” without a vendor API leak

Desired platform behavior:
- periodic “recovery points”,
- deterministic retention (`hourly 24h`, `daily 7d`, `weekly 8w`),
- restores consume a stable layout (or stable object identities), not vendor-specific snapshot IDs.

PAL approach:
- `SnapshotPolicy` declares cadence + retention.
- `Snapshot` resources are produced with consistent status (`CreatedAt`, `ExpiresAt`, `Integrity`, `RestoreTestedAt`).
- The backing provider may implement snapshots via:
  - filesystem copy + content addressing,
  - vendor snapshots,
  - object-store versioning / replication,
  - or other mechanisms.

The platform’s restore tooling consumes the PAL contract, not the vendor API.

## Multi-zone (failure domains as first-class contract)

Provider abstractions must not assume a single failure domain.

Contract expectations:
- Every vendor-agnostic resource that represents stateful durability must be able to express a **failure domain**:
  - `spec.failureDomain` (e.g., `zone-a`, `zone-b`, `site-1`) or `spec.failureDomains[]` for replicated intent.
- Providers must advertise zone-/site-aware capabilities in `status.capabilities`, for example:
  - `replication.modes` (`none`, `async`, `sync`),
  - `replication.failureDomains` supported,
  - `rpoFloor`, `rtoAssumptions`,
  - `supportsCrossZoneReadOnlyMount` (when relevant).
- Reconciliation must surface “zone safety” explicitly via conditions:
  - `ReplicationHealthy`, `FailureDomainSatisfied`, `ZoneLossSurvivable` (or an explicit `NotZoneLossSurvivable` reason).

Design rule:
- If the platform requires “zone-loss survivable” durability for a tier, it must be expressed as intent (policy) and validated by status + smokes, not assumed as an implementation detail.

Operational implication:
- Restore and DR workflows must be able to select the correct replica/source based on failure domain status, not on vendor identifiers.

## Multi-tenancy (scoping, isolation, and custody boundaries)

Provider abstractions must be safe in a multi-tenant cluster.

Scoping model (recommended default):
- **Provider wiring resources** are platform-owned and live in a platform namespace (e.g., `infra-system`) or are cluster-scoped when unavoidable.
- **Tenant intent resources** are namespaced and live with the tenant (e.g., `t-<orgId>-...`), and reference providers via `spec.providerRef` only when allowed by policy.

Isolation and custody rules:
- Tenants must never need access to shared platform credentials. Provider resources reference credentials via Kubernetes `Secret` objects that are platform-owned and projected via ESO/Vault.
- Cross-namespace reconciliation is allowed only when the platform explicitly opts into it and can enforce it:
  - strict namespace allowlists,
  - explicit ownership labels/annotations,
  - admission guardrails that prevent a tenant from binding to a provider they do not own.
- Provider controllers must treat tenant inputs as hostile:
  - validate resource sizes and rates,
  - enforce quotas and per-tenant concurrency caps,
  - ensure status does not leak other tenants’ identifiers.

Contract expectations:
- Vendor-agnostic resources should carry an explicit `spec.scope` or `spec.tenantRef` when tenant-scoped semantics matter (e.g., snapshot/retention for a tenant dataset).
- Providers should report per-tenant limits in `status.capabilities` where applicable (quotas, rate limits, max datasets), so the platform can fail early and predictably.

GitOps/evidence implication:
- Any new cross-namespace reconciliation capability requires:
  - admission guardrails/policy updates,
  - at least one smoke validating isolation invariants (e.g., “tenant A cannot mutate tenant B’s external resources via provider refs”),
  - evidence note capturing the contract and the test.

## Rollout strategy (incremental)

1) Document PAL contract for one domain (start with storage/backup targets).
2) Implement one reference provider (Synology or “generic NFS/S3”) behind the contract.
3) Add a second provider (even if mocked) to force portability (and avoid accidental vendor leakage).
4) Add conformance tests/validation jobs that assert contract semantics across providers.

## Open questions

- Where to draw boundaries between PAL groups (e.g. `storage.darksite.cloud`, `hardware.darksite.cloud`) and existing platform APIs (e.g. `platform.darksite.cloud/DeploymentConfig`) so ownership is clear.
- How far to go vs reusing upstream projects (e.g. Cluster API for hardware lifecycle, cert-manager integrations for HSM-backed issuance).
- What “hard” security guarantees we need (WORM / object lock) and how we evidence them.
