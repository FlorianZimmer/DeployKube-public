# Design: Multi-Platform Bootstrap via Platform Drivers

Last updated: 2026-03-03  
Status: Draft

DeployKube currently bootstraps two “platforms”:
- **Dev**: kind on OrbStack (`bootstrap/mac-orbstack`, `shared/scripts/bootstrap-mac-orbstack-*.sh`)
- **Prod-like**: Talos on Proxmox (`bootstrap/proxmox-talos`, `shared/scripts/bootstrap-proxmox-talos-*.sh`)

This design defines an explicit abstraction boundary for **Stage 0** so new platforms (e.g. Hetzner Cloud, VMware, baremetal) can be added without forking the repo into separate bootstrap codebases.

## Tracking

- Canonical tracker: `docs/component-issues/bootstrap-platform-drivers.md`

Related:
- GitOps boundary and Stage 0/1 contract: `docs/design/gitops-operating-model.md`
- Deployment config contract (env diffs live here, not in scripts): `docs/design/deployment-config-contract.md`
- Offline bootstrap constraints: `docs/design/offline-bootstrap-and-oci-distribution.md`

## Problem statement

Stage 1 is conceptually the same across platforms (install Forgejo + Argo CD, seed the mirror, apply the root `platform-apps` Application), but Stage 0 is currently implemented as platform-specific “monolith” scripts.

As soon as we add more platforms (Hetzner Cloud, VMware, eventually baremetal), copy/pasting Stage 0 logic will:
- increase drift between platforms,
- make cross-cutting fixes expensive (timeouts, offline mode, chart pinning, custody gates),
- make it harder to reason about the Stage 0/Stage 1 boundary.

We want a single repository that supports multiple provisioning backends while keeping the “bootstrap boundary” non-negotiable:
Stage 0/1 only create the cluster + seed Forgejo/Argo; everything else converges via GitOps under `platform/gitops/**`.

## Goals

1) **Support multiple platforms** (next: Hetzner Cloud, VMware; future: baremetal) with a single codebase.
2) **Make Stage 0 pluggable** behind a small, explicit “platform driver” contract.
3) **Maximize reuse** of common Talos bootstrap logic across Talos-based platforms (cluster init, CNI/LB/Gateway API, storage baseline, offline bundle wiring, custody gates).
4) **Keep environment-specific values out of scripts**: differences must flow from:
   - `platform/gitops/deployments/<deploymentId>/config.yaml` (GitOps contract), and
   - `bootstrap/<platformId>/config.yaml` (host-side provisioning inputs only).
5) **Enable platform additions without changing GitOps semantics**: adding a platform should largely be “add a deployment profile + implement a driver”.

## Non-goals

- Replacing GitOps with an imperative “bootstrap installs everything” flow.
- Building a universal VM/baremetal imaging pipeline in Phase 0.
- Mandating a single provisioning technology (OpenTofu vs other); the contract allows either, but the implementation should stay repo-consistent (reuse OpenTofu where it already exists).
- Introducing new product-owned CRDs for bootstrap itself in Phase 0 (bootstrap is host-driven by design).

## Definitions

- **Platform**: the infrastructure/provisioning backend for Stage 0 (OrbStack/kind, Proxmox/Talos, Hetzner/Talos, VMware/Talos, baremetal/Talos).
- **`deploymentId`**: DeployKube deployment profile identifier used by GitOps:
  - folder: `platform/gitops/deployments/<deploymentId>/`
  - environment bundle: `platform/gitops/apps/environments/<deploymentId>/`
- **Platform driver**: a Stage 0 implementation that provisions/creates a cluster and emits the artifacts Stage 1 needs.
- **Bootstrap artifacts**: local files produced by Stage 0 (at minimum a `kubeconfig`; for Talos-based clusters also a `talosconfig` plus node endpoints).

## Current state (repo-truth)

- Proxmox/Talos bootstrap:
  - Orchestrator: `shared/scripts/bootstrap-proxmox-talos-orchestrator.sh`
  - Stage 0 (monolith): `shared/scripts/bootstrap-proxmox-talos-stage0.sh`
  - Stage 1: `shared/scripts/bootstrap-proxmox-talos-stage1.sh`
  - Provisioning IaC: `bootstrap/proxmox-talos/tofu/`
- OrbStack/kind bootstrap:
  - Orchestrator: `shared/scripts/bootstrap-mac-orbstack-orchestrator.sh`
  - Stage 0: `shared/scripts/bootstrap-mac-orbstack-stage0.sh`
  - Stage 1: `shared/scripts/bootstrap-mac-orbstack-stage1.sh`

Today, “platform == deploymentId” happens to be true for `mac-orbstack-single` and `proxmox-talos`, but the repo already supports multiple deployment profiles (overlays) and will need more as additional platforms appear.

## Proposed design: Platform driver contract (Stage 0)

Introduce an explicit “driver” contract for Stage 0 that is stable across platforms.

### Inputs (Stage 0)

Stage 0 is invoked with:
- `platformId` (selects a driver implementation)
- `deploymentId` (selects the GitOps profile and DSB inputs)
- `bootstrap/<platformId>/config.yaml` (provider-specific provisioning inputs; no GitOps knobs)
- `platform/gitops/deployments/<deploymentId>/config.yaml` (deployment knobs consumed where required by Stage 0, e.g. time/NTP baseline, DNS base domain, offline/registry endpoints)

### Outputs (Stage 0)

Stage 0 must write a small, well-defined artifact set (paths can remain under `tmp/` by default):
- `KUBECONFIG` file (required)
- `TALOSCONFIG` file (Talos platforms only)
- a machine-readable “stage0 result” file (recommended) containing:
  - `platformId`, `deploymentId`
  - cluster endpoint (VIP / LB / API address)
  - node endpoints (Talos API IPs / ports) when applicable

Stage 1 (GitOps bootstrap) should require only the outputs above, not platform-specific details.

### Responsibilities split

Driver responsibilities (platform-specific):
- Create machines (VMs/instances/baremetal nodes) and ensure they can boot Talos (or kind containers for dev).
- Establish a stable Kubernetes API endpoint strategy (VIP, load balancer, floating IP, etc.).
- Ensure nodes can pull required bootstrap images (consistent with offline bundle / registry design).

Shared Stage 0 responsibilities (platform-agnostic for Talos platforms):
- Generate/apply Talos machine configs.
- Bootstrap Kubernetes and install only the Stage 0 baseline prerequisites (CNI, baseline LB, Gateway API CRDs, baseline storage class/provisioner required for Stage 1/Argo).

## Stage 1: make GitOps bootstrap shared

Stage 1 should be a single implementation that is parameterized by `deploymentId` and reads per-platform bootstrap values from `bootstrap/<platformId>/...` only when necessary.

Near-term target:
- Replace the duplicated `shared/scripts/bootstrap-mac-orbstack-stage1.sh` and `shared/scripts/bootstrap-proxmox-talos-stage1.sh` with a single Stage 1 library script plus thin wrappers (to preserve existing entrypoints and environment defaults).

## Repo layout proposal (incremental refactor)

Keep the current “entrypoint wrappers” pattern under `scripts/` and converge the implementation under `shared/scripts/`:

- `scripts/bootstrap-<platformId>.sh`  
  Thin wrappers that select defaults and call a shared orchestrator.

- `shared/scripts/bootstrap-orchestrator.sh`  
  Generic: runs Stage 0 via driver, then Stage 1, then optional Vault init gates (existing pattern).

- `shared/scripts/bootstrap/drivers/<platformId>/stage0.sh`  
  Platform-specific provisioning adapter (calls OpenTofu, cloud APIs, etc.) and then invokes shared Talos bootstrap helpers.

- `shared/scripts/bootstrap/lib/talos.sh`  
  Shared Talos bootstrap primitives (apply configs, bootstrap, wait loops), extracted from the current Proxmox Stage 0.

- `bootstrap/<platformId>/`  
  Host-side config + IaC modules (e.g. `tofu/`) for that platform.

This keeps “platform-specific code” local to a driver directory while pushing everything else into shared libs.

## Platform notes (expected differences)

### Hetzner Cloud (Talos)

Expected platform-specific concerns:
- instance lifecycle and networking (private networks vs public-only),
- a stable control plane endpoint (Hetzner LB vs floating IP),
- Talos boot/install strategy (image/snapshot vs install from ISO-equivalent).

These should live entirely in the Hetzner driver + `bootstrap/hetzner-talos/` IaC, while shared Talos bootstrap logic remains reused.

### VMware vSphere (Talos)

Expected platform-specific concerns:
- VM templates/OVA vs ISO boot,
- datacenter resource layout (networks, datastores, resource pools),
- endpoint strategy (VIP via in-cluster L2, external LB, or vSphere constructs).

Again: isolate in the vSphere driver + IaC; reuse Talos bootstrap library.

### Baremetal (Talos, future)

Baremetal adds complexity (inventory, PXE/installer, BMC, switching/L2, endpoint/LB). This design’s goal is not to solve baremetal immediately, but to ensure we do not paint ourselves into a corner where baremetal “forces a fork”.

## Validation + evidence expectations

Repo-only:
- Update `tests/scripts/validate-bootstrap-contract.sh` once Stage 1 is unified (keep contract coverage).
- Consider adding a “driver registry lint” that ensures every supported `platformId` has:
  - `bootstrap/<platformId>/config.yaml` (or example),
  - a Stage 0 driver entrypoint,
  - a corresponding `platform/gitops/deployments/<deploymentId>/` profile for at least one default deployment.

Runtime:
- Each new platform driver should ship with a minimal bootstrap evidence note (`docs/evidence/YYYY-MM-DD-...`) showing Stage 1 handoff and root app health (`Synced Healthy`) for the default deployment profile.

## Migration strategy (phased)

1) Unify Stage 1 implementation behind a shared library (keep wrapper scripts stable).
2) Extract Talos bootstrap primitives from the current Proxmox Stage 0 into `shared/scripts/bootstrap/lib/talos.sh`.
3) Convert Proxmox Stage 0 to a `proxmox-talos` driver that calls shared Talos libs (no behavioral changes intended).
4) Add scaffolding for a new Talos platform driver (start with Hetzner Cloud or vSphere) to validate the abstraction boundary.

## Open questions

- Do we allow one `platformId` to support multiple `deploymentId`s (recommended), or enforce a 1:1 mapping?
- Where should “endpoint strategy” live as a contract: bootstrap config only, or `DeploymentConfig` as well (to inform GitOps manifests like DNS/ingress)?
- For Talos image/boot flows, do we standardize on Image Factory for all Talos platforms, or allow per-platform image sources as long as offline mode is supported?

