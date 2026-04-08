# Idea: Declarative Provisioning From a Single YAML (Deployments + Tenants)

Date: 2025-12-25
Status: Draft

## Problem statement

To productize DeployKube as a managed private cloud, we must be able to create:
- a **new cloud deployment** (initial install on new hardware), and
- a **new tenant/customer** (inside an existing cloud),

by authoring **one YAML file** that fully describes the desired state (parameters, topology, security posture, and sizing).

This YAML must be:
- **UI-wrappable** later (the UI just authors this YAML / CRs; it is not the control plane).
- **Apply-anywhere**:
  - from a laptop (“nodeless bootstrap”) for small deployments, or
  - from an optional bootstrap node/server in the target environment.
- **Non-redundant**: the same API and reconciliation logic should drive both:
  - initial bootstrap of a new environment, and
  - ongoing provisioning of tenants/clusters within an existing environment,
  to keep maintenance cost low and avoid divergent procedures.

This bootstrap procedure is vital to enable:
- very small dedicated deployments (doctor’s office) up to
- large multi-customer hosted deployments,
without rewriting the provisioning system.

Related ideas:
- Managed cloud / multi-tenancy: `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
- Three-zone anycast+BGP: `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`
- KRM-first Cloud UI: `docs/ideas/2025-12-25-krm-gitops-cloud-ui.md`

## Why now / drivers

- **Operational scalability**: selling/operating many deployments requires repeatable, low-toil installs and tenant onboarding.
- **Maintainability**: multiple ad-hoc bootstrap scripts per environment will not scale; we need one reconciler and one contract.
- **Security**: provisioning must be policy-driven and auditable (who created what, with what parameters).
- **UI enablement**: a “cloud console” can be built later only if the platform has stable declarative APIs now.

## Proposed approach (high-level)

### 1) Define a single declarative API surface (KRM / CRDs)

Introduce a small set of platform CRDs that together represent “one cloud deployment” and “tenants inside it”.

Two acceptable shapes for “single YAML”:
1) A single file containing **multiple KRM objects** (multi-document YAML): `CloudDeployment`, `Tenant`, `WorkloadCluster`, `ServerPool`, etc.
2) One top-level object (e.g., `CloudPlan`) that embeds tenants/clusters as spec subtrees.

Key requirement: the schema must support “small now, large later” without breaking changes:
- `zones: [zone-a]` for single-zone MVP and `zones: [zone-a, zone-b, zone-c]` for true multi-zone.
- `customers: [cust-001]` for dedicated installs and `customers: [cust-001, cust-002,...]` for hosted multi-customer.
- `serverPools` that can represent “shared pool” or “dedicated physical servers per tenant/customer”.
- a network section that supports both:
  - L2 handoff + static routing, and
  - L3 eBGP/VRF contracts.

### 2) One reconciler: a provisioning controller that converges reality to the YAML

Implement a controller (the “provisioner”) that reconciles the above CRDs and drives:
- **Environment bootstrap** (create/initialize a new cloud deployment).
- **Tenant provisioning** (create tenant/customer isolation boundaries and their clusters).
- **Cluster lifecycle** (create/upgrade/scale clusters and their node pools).
- **Day-2 safety**: drift detection, idempotency, and clear Conditions/Events.

Important boundary: steady-state workloads and platform services remain GitOps-managed (Forgejo/Argo). The provisioner should focus on:
- infrastructure lifecycle and “bring-up” of clusters,
- authoring/maintaining the desired cluster inventory and tenant scaffolding,
and then handing off in-cluster service composition to Argo CD wherever possible.

### 3) Bootstrap modes without duplicating logic

We want the exact same CRDs + reconciliation logic regardless of how bootstrap is initiated.

Bootstrap Mode A — **Laptop bootstrap (nodeless)**
- Run a temporary “bootstrap management cluster” locally (e.g., kind) on the laptop.
- Install the provisioner (and any required lifecycle controllers) into that bootstrap cluster.
- Apply the single YAML; the provisioner provisions the real management cluster on target hardware.
- “Pivot” control to the real management cluster once it is up (move controllers/state), then delete the local bootstrap cluster.

Bootstrap Mode B — **Bootstrap node/server**
- Run the same “bootstrap management cluster” on a small bootstrap server in the target environment (useful for air-gapped or when a laptop is undesirable).
- Same YAML and same controllers; the only change is where the bootstrap cluster runs.

Design goal: Mode A and Mode B share >95% of code and manifests; only the “bootstrap runtime” differs.

### 4) Tenant onboarding as the same workflow (not a second system)

Once a management plane exists:
- onboarding a tenant/customer is “apply a Tenant spec” (via GitOps)
- the provisioner converges:
  - dedicated server pools (if required for side-channel resistance)
  - tenant network segmentation (VLAN/VRF/VIP allocation)
  - one or more workload clusters for that tenant
  - identity + access scaffolding (Keycloak groups/clients, Vault policy/paths, Argo CD Projects, Forgejo org/team/repo)

This keeps “new deployment” and “new tenant” as the same conceptual flow: declare intent → controller converges → GitOps applies platform/services.

### 5) Evidence and operability as first-class API design

The CRDs must expose:
- Conditions (e.g., `InventoryReady`, `BootstrapReady`, `ManagementClusterReady`, `GitOpsReady`, `TenantReady`)
- last-applied revision / render hashes
- links or references for evidence capture (what commands/outputs to store in `docs/evidence/**`)

## What is already implemented (repo reality)

- Stage 0/1 bootstrap scripts exist for dev/prod and already enforce a GitOps boundary (`docs/design/gitops-operating-model.md`).
- Talos/Kubernetes provisioning exists for the current prod topology (Proxmox + Talos) but not as a generic “fleet controller”.
- Foundational platform building blocks exist (Vault/ESO, Keycloak, Forgejo/Argo, cert-manager/Step CA, Istio/Cilium/MetalLB, observability) (`target-stack.md`).

## What is missing / required to make this real

### 1) The provisioning CRDs (schema + contracts)
- Object model: cloud deployment, zones, customers/tenants, clusters, server pools, network contracts.
- Versioning strategy (v1alpha1 → v1beta1) and migration plan.

### 2) A lifecycle engine for clusters and bare metal
- Decide on the cluster lifecycle substrate (e.g., Cluster API + a bare-metal/Talos-friendly provider).
- Define how the provisioner interacts with the substrate (directly reconcile CAPI objects vs generate-and-commit GitOps manifests).

### 3) Secrets and bootstrap trust chain
- How bootstrap credentials are provided (BMC creds, initial CA roots, initial admin identity).
- How quickly we can “turn on Vault” and stop using bootstrap secrets.
- A clear “break-glass” story with auditability.

### 4) Networking automation boundaries
- Decide what is provisioned by the platform vs expected from the customer:
  - VLAN creation, VRFs, BGP sessions, route policy, IPAM
- Ensure L2 and BGP modes share the same higher-level contract.

### 5) A minimal reference “single YAML” for MVP
- A concrete example for:
  - single-zone / single-customer / single cluster
  - single-zone / single-customer / multiple clusters
  - three-zone / hosted multi-customer / dedicated server pools

## Risks / weaknesses

- **Bootstrap chicken-and-egg**: we need controllers running before the management cluster exists; pivoting must be reliable.
- **API surface lock-in**: the CRDs become a product contract; careless design will create long-term compatibility pain.
- **Security pitfalls**: bootstrap secrets handling is a major risk area; must be designed first, not patched later.
- **Overreach**: attempting “hardware + network + k8s + multi-zone” all at once may delay a sellable MVP; milestones must be scoped.

## Alternatives considered

- Keep expanding Stage 0/1 scripts per environment:
  - faster short-term, but creates long-term divergence and blocks UI-driven self-service.
- Terraform/Ansible as the primary interface:
  - can work, but less aligned with KRM/GitOps and harder to expose as a stable product API.
- “UI directly provisions everything”:
  - rejected; the UI should author declarative intent and show status, not be the control plane.

## Open questions

- Should the “single YAML” be one top-level object or multiple KRM objects in one file?
- Where do we store tenant/customer desired state:
  - in Git only (preferred), or
  - allow direct apply to the management cluster as an emergency path?
- What is the minimal supported bare-metal provisioning target (which BMCs, which switch OSes)?
- How do we model upgrades safely (Kubernetes/Talos versions, phased rollouts, zone-by-zone)?
- How do we enforce “dedicated physical servers” for side-channel-resistant tiers (admission + scheduling + inventory binding)?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A concrete v1alpha1 CRD schema and at least one complete example “single YAML”.
- A proven bootstrap flow (laptop bootstrap or bootstrap node) that can bring up a management plane from bare metal and hand off to GitOps.
- A tenant onboarding flow using the same APIs that provisions at least one tenant workload cluster.
- Security design for bootstrap credentials and the trust chain (Vault/PKI/identity) with a documented break-glass process.

