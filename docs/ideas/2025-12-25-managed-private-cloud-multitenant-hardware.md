# Idea: Managed Private Cloud-in-a-Box (Multitenancy + Hardware-to-Kubernetes)

Date: 2025-12-25
Status: Draft

## Problem statement

Extend DeployKube from “a Kubernetes platform stack” into a **sellable private cloud offering** for environments where public cloud is not acceptable (regulation, sovereignty, defense, medical, high paranoia).

Requirements and constraints:
- **Customer connectivity model**: the only on-prem integration should be connecting our **border leaf switch** to the **customer core switch**. We must support:
  - **L2 handoff** (VLAN(s) + static routing), because small deployments often do not run BGP.
  - **L3 handoff (eBGP)** as the preferred scalable path (VRFs, policy, multi-zone/anycast readiness).
- **Multitenancy / multi-customer**: a deployment may be **dedicated to one customer** or **host multiple customers**. Isolation must be strong, and must support **physical separation** (dedicated servers/racks per customer/tenant) for side-channel resistance.
- **Scales down and up**:
  - minimal cost, single tenant, single zone (still HA on server/switch level)
  - large footprint with many servers and many tenants
- **Security + High Availability are top priorities** (not optional add-ons).
- **Multi-zone awareness from day 0**: the architecture must be compatible with “public cloud style” zones and zone-loss redundancy. The multi-zone/anycast+BGP idea is captured in `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`, and this doc must not paint us into a single-zone corner.
- **Provisioning as a product capability**: new deployments and tenants must be creatable from a single declarative YAML contract (UI-wrappable), with a unified bootstrap procedure. See `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`.

## Why now / drivers

- DeployKube already has the “platform core” (GitOps + identity + secrets + TLS + mesh + observability) that private clouds typically struggle to standardize.
- Regulated environments often want a **single-vendor, repeatable appliance-like** stack with strong operational discipline and auditability.
- The repo is already oriented around “bootstrap only gets us to GitOps; everything else is declarative”, which is a good foundation for fleet-scale repeatability.

## Proposed approach (high-level)

### 0) Terminology (for this doc)

- **Cloud deployment**: one DeployKube-based private cloud installation (a “cloud-in-a-box”) running on owned hardware.
- **Customer**: an external customer (in a hosted multi-customer scenario) *or* the owning organization (in a dedicated deployment).
- **Tenant**: a top-level isolation boundary in the cloud deployment. In hosted mode, tenant ~= customer. In dedicated mode, tenant may represent internal security/workload domains.
- **Workload cluster**: a Kubernetes cluster intended primarily for running tenant workloads (not necessarily running the shared management plane).
- **Management plane cluster**: the Kubernetes cluster that hosts GitOps/identity/secrets/observability and provisions/manages workload clusters.

### 1) Product shape: dedicated or hosted (multi-customer) using the same core architecture

This offering should support two deployment shapes without forking the architecture:

1. **Dedicated deployment (single-customer)**: installed inside a customer’s premises / sovereign DC.
2. **Hosted deployment (multi-customer)**: a single cloud deployment can host multiple customers as tenants, with strong isolation.

Principle: “Dedicated” should be a **special case** of “Hosted” (hosted with exactly one customer), so early work on small dedicated installs does not block the long-term multi-customer goal.

Deliverables per customer:
- A **management plane** (GitOps/identity/secrets/observability + infra lifecycle controllers).
- One or more **workload clusters** (or tenancy boundaries inside a shared cluster, depending on the tier).
- A standard **network demarcation**: border leaf ↔ customer core.

### 2) Tenancy tiers (to support “cheap → hardcore”)

Offer three explicit tenancy tiers to avoid pretending one model fits all:

1. **Shared cluster / namespace tenancy (lowest cost)**
   - Tenants are namespaces with strict baseline policies (NetworkPolicies, quotas, admission controls).
   - Suitable only inside a single trust domain (e.g., “one customer, multiple teams”), **not** for cross-customer isolation or side-channel resistance.

2. **Virtual cluster tenancy (mid tier)**
   - Tenants get “their own Kubernetes API” (vcluster-like) while sharing worker nodes.
   - Better UX isolation; still **not** equivalent to physical separation and is not a side-channel-resistant boundary.

3. **Cluster-per-tenant (high assurance; default for regulated)**
   - Each tenant gets **one or more** Kubernetes clusters, managed by the management plane (GitOps + lifecycle).
   - Supports a tenant creating multiple workload clusters to separate their own projects/business units.
   - Backed by **dedicated physical servers** (no co-tenancy) when “side-channel resistant isolation” is required.

Physical separation options (orthogonal):
- Shared servers with scheduling controls (taints/labels) + hard network policy (only acceptable when all workloads are in the same trust domain).
- Dedicated node pools per tenant (still shares a physical machine if mixed pools exist; not sufficient for side-channel-resistant claims).
- Dedicated rack/servers per tenant (and optionally dedicated ToR pair) for environments requiring strong blast-radius reduction, compliance clarity, and side-channel resistance.

### 3) “Hardware-to-Kubernetes” lifecycle management

Move from “we provision a cluster” to “we manage the full estate”:
- **Inventory & IPAM/DCIM** as source of truth (servers, BMCs, switchports, addresses, VRFs, zones).
- **Zero-touch provisioning** of nodes:
  - BMC/Redfish/IPMI power control and boot order
  - PXE/iPXE or virtual media bootstrap
  - Talos (preferred) or another minimal OS baseline
- **Declarative cluster lifecycle**:
  - create/scale/upgrade clusters (Kubernetes + Talos)
  - expand/replace hardware (immutable rebuild, no snowflakes)

Important: the design should stay GitOps-first (desired state in Git), with automation applying it and emitting evidence.

### 4) Network architecture: simple customer handoff, cloud-grade isolation

Border leaf ↔ customer core should be a clean, standard demarc:
- Support **two integration modes**, to enable “small installs now” without blocking “cloud-grade later”:
  - **L2 handoff**: VLAN(s) to the customer core, with static routing (and clear operational runbooks). This is common in small environments.
  - **L3 handoff (eBGP)**: preferred long-term path for scale, policy, VRFs, and multi-zone/anycast readiness.
- Tenant isolation via **VRFs** and strict route policy.
- Service exposure via controlled IP pools:
  - per-tenant ingress VIP ranges (and possibly per-tenant anycast VIPs later)
  - BGP advertisement from the platform side (MetalLB BGP mode and/or Cilium BGP control plane)

Zone-awareness constraint:
- The network model must support eventual **anycast + fast convergence** for zone loss. “Zero packet loss” is not realistically guaranteeable; the goal should be *minimal loss and sub-second convergence* (BFD, tuned hold timers, ECMP, and careful failure-domain design).

### 5) Control plane layering: management vs tenant clusters

To keep blast radius and security boundaries clean:
- **Management cluster** runs:
  - GitOps (Forgejo/Argo CD), Identity (Keycloak), Secrets (Vault+ESO), PKI (Step CA+cert-manager)
  - Observability stack (LGTM)
  - Lifecycle controllers (Cluster API and bare-metal provider or equivalent)
  - Policy enforcement (Kyverno/Gatekeeper), baseline security controls
- **Tenant clusters** run:
  - Kubernetes runtime + ingress + mesh (or a reduced set), plus tenant workloads
  - optional shared managed services (DB/S3) depending on tier and risk appetite

The management cluster should be able to:
- declare tenant clusters in Git
- bootstrap them from bare metal
- enroll them into GitOps reconciliation
- enforce consistent security baselines

### 6) Milestones / roadmap (build small without blocking scale)

The key design constraint is “intrinsic scalability”: early milestones must establish the **interfaces** (naming, identity model, GitOps contracts, network modes) that later scale-out builds upon, even if the first implementation only uses a subset.

Scalability invariants (do not violate in early milestones):
- **Everything is modeled as objects**: customer/tenant, workload cluster(s), server pool(s), and (eventually) zone(s), even if the MVP only creates one of each.
- **Tenant scoping is baked in**: Keycloak groups/clients, Vault paths/policies, Argo CD Projects, DNS naming, and GitOps folder contracts include a tenant/customer identifier from day 1.
- **Network mode is a replaceable module**: L2 handoff and eBGP handoff implement the same higher-level contract (ingress VIP allocation, tenant segmentation), so “L2 first” does not block “BGP later”.
- **Hard isolation is a first-class target**: dedicated physical server pools per tenant/customer are part of the model, even if a small single-tenant deployment does not need to exercise it.

Milestone 0 — **Single-customer, minimal deployment (“cloud-in-a-box”)**
- One site/zone, one customer, one workload cluster (management plane may be co-located if needed).
- L2 handoff supported (VLAN + static routes); document the demarcation/runbook.
- HA/security posture is still first-class (no single points of failure inside the box beyond the site itself).

Milestone 1 — **Customer can create multiple workload clusters**
- Introduce a first “cluster as a service” API/workflow (GitOps representation) so one customer can run multiple clusters for internal separation.
- Keep the abstraction compatible with future multi-customer hosting (customer/tenant IDs baked into identity, naming, and secrets paths).

Milestone 2 — **Hosted multi-customer with hard isolation**
- Add “customer accounts” (tenants) with dedicated physical server pools and strict network segmentation.
- Make “cluster-per-tenant” the default regulated posture; optionally allow lighter tenancy only within a single customer trust domain.

Milestone 3 — **Network scale-up path**
- Add eBGP/VRF integration as the preferred mode (without removing the L2 mode).
- Standardize IPAM, per-tenant ingress VIP ranges, and route policy contracts.

Milestone 4 — **Multi-zone capable control planes (follow-up idea doc → design)**
- Implement the multi-zone architecture (anycast/BGP failover, failure domains, storage replication, quorum constraints) as a promoted design.

## What is already implemented (repo reality)

DeployKube already contains many building blocks that a “private cloud” needs:
- GitOps operating model: Forgejo mirror + Argo CD root app (`docs/design/gitops-operating-model.md`).
- Core security primitives: Vault + External Secrets Operator + SOPS posture (`target-stack.md`).
- Identity foundation: Keycloak, OIDC integrations for platform services (`target-stack.md` and component READMEs).
- Network primitives: Cilium + MetalLB + Istio + Gateway API, with strict mesh mTLS (`target-stack.md`).
- Observability: LGTM stack deployed via GitOps (`target-stack.md`).
- Early RBAC/multi-tenant direction: group/role architecture draft and label-driven namespace RBAC scaffolding (`docs/design/rbac-architecture.md`, `platform/gitops/components/shared/rbac/**`).
- Two-environment bootstrap story (dev + prod) with a hard GitOps boundary (Stage 0/1 only bootstrap).

What is *not* present today: any notion of “fleet of clusters”, “tenant provisioning”, “VRF-per-tenant routing handoff”, or “bare-metal lifecycle”.

## What is missing / required to make this real

### 1) A concrete tenancy contract

We must explicitly define:
- what a “tenant” means (namespace vs virtual cluster vs full cluster)
- what is shared vs dedicated (ingress, DNS zones, secrets paths, databases, object storage, observability)
- what the isolation guarantees are (and which tier they apply to)
  - explicitly define what “side-channel resistant isolation” means in this offering (dedicated physical servers required; any additional hardening is defense-in-depth)

This must be backed by enforceable controls:
- policy engine (Kyverno/Gatekeeper) + baseline constraints
- default-deny network posture + exceptions by policy
- resource quotas/limits and fair-share
- Argo CD project boundaries per tenant

### 2) Tenant lifecycle automation

We need an API/workflow that creates a tenant and keeps it converged:
- GitOps representation of a tenant (CRDs and/or a folder contract in `platform/gitops/`)
- identity (Keycloak groups/clients), Git (Forgejo teams/repos), secrets (Vault namespaces/policies), and cluster RBAC wiring
- safe offboarding (revoke credentials, delete namespaces/clusters, wipe disks if required)

### 3) Hardware and network management scope

We need to decide how much “hardware management” we own:
- servers only (BMC + OS provisioning + disk wipe), or also
- switching (ToR/border leaf config, BGP/VRFs, port provisioning), and
- optional integration into customer systems (IPAM, monitoring, SIEM)

If we manage switches, we must pick a narrow initial target (e.g., FRR/SONiC + gNMI/OpenConfig) or accept vendor-specific tooling.

### 4) Cluster fleet management (CAPI or alternative)

Introduce a cluster lifecycle controller approach suitable for:
- many clusters
- reproducible upgrades (Kubernetes + Talos)
- controlled drift and emergency remediation (replace nodes, roll back)

This likely implies:
- Cluster API as the declarative interface
- a bare-metal provider (Metal3/Ironic, Tinkerbell, Sidero Metal, etc.) as an implementation choice

### 5) Artifact strategy for paranoid / regulated environments

Selling this into “no cloud allowed” implies:
- in-cluster registry + artifact mirroring
- pinned versions/digests for charts/images
- an upgrade path that works offline (documented + tested)

### 6) Multi-zone (follow-up doc required)

This idea is incomplete without a dedicated multi-zone design (three-zone requirement, anycast+BGP, etc.) covering:
- zone definition (latency limits, failure domains, shared services placement)
- Kubernetes control-plane/etcd quorum constraints
- storage replication strategy across zones
- anycast/BGP announcement model, fast failover, and operational testing

See `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`.

## Risks / weaknesses

- **Isolation story risk**: namespace multi-tenancy is not “military-grade”; over-selling isolation would be dangerous.
- **Multi-zone reality**: “native multi-zone Kubernetes” has real latency/quorum constraints; true “region-like” distances likely require multi-cluster patterns.
- **Hardware scope creep**: switch automation + server provisioning + Kubernetes platform is a large product surface.
- **Demarcation responsibility**: peering with customer core needs clear responsibility boundaries (routing policy, IP ownership, troubleshooting runbooks).
- **Blast radius**: a shared management plane is a high-value target; it must be hardened and isolated (and may need its own dedicated hardware).

## Alternatives considered

- Build on an existing private-cloud substrate:
  - OpenStack / MAAS / VMware / Nutanix as “IaaS”, DeployKube as “PaaS”.
  - Pros: mature hardware/network lifecycle; Cons: heavy, less GitOps-native, harder to productize as one cohesive system.
- Avoid multi-tenancy in Kubernetes:
  - “cluster per tenant always”, even for small deployments.
  - Pros: clean isolation; Cons: more overhead and cost for minimal deployments.
- Keep “hardware management” out-of-scope:
  - Only run on customer-provided Kubernetes/hardware.
  - Pros: narrower scope; Cons: fails the “appliance” goal and reduces reliability guarantees.

## Open questions

- What is the first “hosted multi-customer” variant we can support operationally (e.g., multiple customers, each on dedicated server pools, sharing only the management plane)?
- What is the minimum acceptable tenancy tier for the regulated target audience (is namespace multi-tenancy ever acceptable)?
- Are we willing to require **three failure domains** for “zone-loss resilience” (or do we need a 2-zone + witness story for transitional deployments)?
- What is the expected customer handoff:
  - what does “minimal L2 handoff” look like (VLANs, static routes, failover, IP ownership)?
  - what is the eBGP contract (ASNs, VRFs, route policy, BFD, address ownership)?
  - do we own IP space inside the customer network, or must we consume customer-provided prefixes?
- What is the “hardware managed” boundary:
  - do we manage ToR/border leaf config, or only the servers?
  - do we require a specific switch OS/vendor to keep the product supportable?
- What is the security posture for operator access:
  - break-glass process, MFA requirements, audit log retention, offline/air-gapped workflows?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A written, enforceable tenancy model (tiers + guarantees) and a threat model per tier.
- A concrete “tenant lifecycle” GitOps contract (what files/CRs exist, what controllers reconcile them).
- A first reference network design for customer handoff (L2 + eBGP/VRF policy, service exposure, DNS/TLS integration).
- A chosen cluster-fleet lifecycle approach (CAPI + provider decision, or a clearly justified alternative).
- A scoped, testable multi-zone design (separate idea doc → promoted design) that does not depend on wishful properties like “no packet loss”.
- A minimal reference deployment definition (“small”, “medium”, “large”) with BOM-level assumptions and HA requirements.

