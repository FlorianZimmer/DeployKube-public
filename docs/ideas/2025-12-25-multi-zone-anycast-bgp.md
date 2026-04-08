# Idea: Three-Zone Kubernetes + Anycast/BGP (Native Multi-Zone Resilience)

Date: 2025-12-25
Status: Draft

## Problem statement

DeployKube’s long-term goal is a “cloud offering where cloud is not possible” that remains available and secure even if an entire **zone/site** fails.

This requires a **native multi-zone Kubernetes** model comparable to public cloud “regional clusters”:
- A single logical “region” spanning **three zones** (required for true multi-zone capabilities).
- No single-zone dependency for control-plane availability, ingress reachability, or critical shared services.
- Failover that is fast and operationally predictable, with **anycast + BGP** as the primary mechanism for “regional” virtual IP reachability.

Non-goal / realism note: “no packet loss” on zone failure is not achievable in general (existing in-flight packets and established TCP sessions will be disrupted). The goal is **minimal loss** and **fast convergence** with clearly defined expectations and testable SLOs.

This design must also:
- work in **single-zone** deployments (same contracts, just fewer zones)
- integrate with the managed cloud and provisioning ideas:
  - `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
  - `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`

## Why now / drivers

- Multi-zone constraints affect almost every subsystem: cluster lifecycle, networking, storage, identity/secrets, and operational runbooks.
- A wrong early assumption (e.g., “single NFS server is fine”) can block the long-term objective or force painful migrations.
- “Three zones required” must be an explicit contract to avoid ambiguous “two-zone HA” designs that cannot survive a full site loss without compromise.

## Proposed approach (high-level)

### 1) Zone model and requirements

Define a **zone** as a failure domain that can be lost entirely (power, ToR pair, uplinks, local storage).

Minimum zone requirements for “true multi-zone”:
- **Three zones**: `zone-a`, `zone-b`, `zone-c` (hard requirement).
- Independent ToR/border leaf redundancy per zone (at least a pair).
- Inter-zone connectivity with predictable latency/jitter and sufficient bandwidth.
- A consistent addressing model per zone (node subnets, VIP pools, service CIDRs).

Single-zone deployments still use the same labeling model (`topology.kubernetes.io/zone`) but only define one zone.

### 2) Kubernetes architecture: “regional” stretched cluster

Target model: a single Kubernetes cluster spanning three zones (“regional cluster”).

Core properties:
- **Control plane spread across zones**:
  - at least 3 control-plane nodes (1 per zone) with etcd membership spread across zones
  - explicitly define acceptable RTT between zones for etcd/control-plane health
- **Worker nodes in all zones**, labeled via `topology.kubernetes.io/zone`.
- **Scheduling defaults** for platform-critical components:
  - PodAntiAffinity / topology spread constraints across zones
  - PodDisruptionBudgets per critical deployment
  - node/pool isolation for dedicated-hardware tenants (when required)

This “stretched cluster” is the most cloud-like experience for tenants (one API, one region). However, it must be constrained to metro-scale latencies; otherwise multi-cluster becomes the safer pattern (see Alternatives).

### 3) Anycast + BGP for “regional VIPs”

Goal: provide stable, “regional” VIPs for ingress and other externally reachable endpoints, without DNS failover delays.

High-level design:
- Define a pool of “regional service VIPs” (per tenant/customer VRF where applicable).
- Advertise VIP routes via BGP from the platform side:
  - either from dedicated edge/LB nodes (preferred for determinism)
  - or from the Kubernetes nodes hosting the gateway service (MetalLB BGP / Cilium BGP)
- Use **BFD** and tuned BGP timers to withdraw routes quickly on zone failure.
- In steady state, VIPs may be advertised from multiple zones (ECMP/closest-exit), but only for services that are active in all those zones.

Operational contract:
- “Regional VIP” is available as long as at least one zone remains healthy.
- Established connections may still reset; application-layer resilience is required (retries, idempotency, client reconnection).

### 4) North–south routing and customer handoff

Multi-zone requires L3 routing clarity.

Preferred long-term:
- Customer core ↔ platform border leaf: **eBGP** with VRFs per tenant/customer and strict route policy.
- Platform advertises only approved prefixes:
  - “regional VIP” prefixes
  - any required tenant/service prefixes
- Customer advertises only approved prefixes back.

Small deployments (non-BGP) can use L2 handoff + static routing, but “true multi-zone” inherently assumes routed L3 between zones and to the customer core.

### 5) East–west networking between zones

Kubernetes networking must tolerate zone loss and avoid hidden single-zone dependencies:
- Pod-to-pod and node-to-node routing must continue if any one zone is lost.
- Decide explicitly whether to:
  - route pod CIDRs between zones using BGP/underlay routing, or
  - use an overlay suitable for multi-zone, or
  - use a multi-cluster model with controlled cross-cluster connectivity (see Alternatives)

The chosen approach must be testable with failure drills (kill zone, confirm remaining zones converge without manual intervention).

### 6) Storage in a three-zone world

True zone-loss resilience requires decisions per data class:
- **Platform state** (Vault, databases, Git, identity): must survive loss of one zone without data loss beyond the defined RPO.
- **Tenant state**: may have tiered options (synchronous replication across zones vs async replication/backup).

Implication: single-zone storage (e.g., “one NFS server”) is not compatible with the multi-zone goal for critical services. The platform must adopt a multi-zone storage strategy (distributed storage or explicit per-zone storage + replication + restore).

### 7) Validation doctrine (failure drills as a product requirement)

Multi-zone is not real unless it is exercised:
- a documented “zone failure drill” procedure
- measurable targets: detection time, BGP withdraw time, service recovery time, and post-failure steady-state behavior
- evidence capture pattern under `docs/evidence/` (Argo status + drill outputs)

## What is already implemented (repo reality)

- Kubernetes platform building blocks exist (Cilium, MetalLB, Istio/Gateway API, DNS, Vault/ESO, observability), but they are implemented as **single-cluster, single-site assumptions** today (`target-stack.md`).
- There is no repo-defined zone topology contract, no BGP peering model, and no anycast VIP design yet.
- Storage patterns are primarily single-site (e.g., RWX via NFS provisioner) and would need a multi-zone strategy for critical services.

## What is missing / required to make this real

### 1) Explicit zone and latency requirements
- Define maximum supported inter-zone RTT/jitter for the “stretched cluster” model.
- Define minimum hardware per zone (control-plane/worker counts, ToR redundancy).

### 2) A concrete anycast/BGP implementation choice
- Decide whether “regional VIPs” are advertised by:
  - dedicated edge/LB nodes, or
  - gateway nodes, or
  - an external appliance
- Define required routing features (BFD, ECMP, per-tenant VRFs, route policy).

### 3) Storage strategy for multi-zone platform state
- Pick an approach for multi-zone storage/replication for:
  - Vault (Raft / transit, recovery, quorum)
  - Postgres (CNPG multi-zone topology, replication, backup/restore)
  - Git/Forgejo storage
  - object storage (Garage multi-zone placement and durability goals)

### 4) Zone-aware defaults in GitOps manifests
- Baseline topology spread/PDB patterns for platform-critical components.
- “Regional vs zonal” service exposure contract (which endpoints are anycast/regional).

### 5) Operational runbooks and drills
- Zone-loss drill procedure and expected outcomes.
- Troubleshooting runbooks for BGP/anycast failures and split-brain prevention.

## Risks / weaknesses

- **Etcd/control-plane latency sensitivity**: stretched clusters only work reliably within bounded RTT; “three zones” may still be too far apart in some deployments.
- **Anycast operational complexity**: debugging and failure analysis is harder than single-site VIPs; clear tooling and runbooks are mandatory.
- **Connection semantics**: anycast improves reachability but does not preserve established flows across a hard failure; application behavior must be considered.
- **Data durability**: multi-zone storage is a major engineering stream; it will gate “true multi-zone”.

## Alternatives considered

- **Multi-cluster per zone + global routing**:
  - a workload cluster per zone and a higher-level “region” abstraction
  - avoids etcd RTT constraints but introduces multi-cluster app deployment and service discovery complexity
- **DNS/GSLB failover instead of anycast**:
  - simpler routing, but slower failover and more client caching edge cases
- **Two zones + witness**:
  - rejected for “true multi-zone” (requirement is three zones), but may exist as a transitional/unsupported topology

## Open questions

- What is the maximum supported inter-zone RTT for the stretched cluster SKU?
- Do we want a single management plane cluster spanning zones, or separate per-zone management clusters with a higher-level control plane?
- What endpoints must be “regional VIP” anycasted (ingress only, or also DNS, key services)?
- How do we define and enforce “regional VIP eligibility” (only advertise from zones where the service is healthy)?
- What is the minimum viable multi-zone storage story for platform-critical data?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A written **three-zone reference architecture** (network + control-plane + data placement) with explicit latency constraints.
- A chosen anycast/BGP implementation (routes, timers, health gating, and operational visibility).
- A multi-zone storage strategy for platform-critical state (RPO/RTO targets and test plan).
- A repeatable zone-failure drill with measurable acceptance criteria and evidence capture.

