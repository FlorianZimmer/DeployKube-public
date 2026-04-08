# Cloud Productization Roadmap (Repo-Grounded)

Last updated: 2026-03-14
Status: Draft (Phase 0 foundations largely in place; cross-cutting roadmap tracker currently clear)

Purpose: a single, always-referenced roadmap that ties the **current repo state** to the long-term “private cloud where public cloud is not possible” vision, and lays out a low-complexity implementation order.

Scope / ground truth:
- This document is grounded in what exists in-repo (scripts + `platform/gitops/**` + docs).
- It does **not** claim live cluster state.
- Future work is explicitly labeled as planned/ideas and references `docs/ideas/**`.

## Tracking

- Canonical tracker: `docs/component-issues/cloud-productization-roadmap.md`

## Vision (links)

The product direction is described in these idea docs:
- Managed private cloud-in-a-box + multi-customer tenancy: `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
- Three-zone “regional” Kubernetes + anycast/BGP: `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`
- Declarative provisioning from a single YAML: `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`
- Access model: four-eyes RBAC, Git escalation, breakglass: `docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`
- Marketplace: fully managed services vs curated deployments: `docs/ideas/2025-12-26-marketplace-managed-services.md`
- KRM-first Cloud UI (authors GitOps CRs/PRs): `docs/ideas/2025-12-25-krm-gitops-cloud-ui.md`
- Vendor integrations (storage, Redfish, HSM) via stable KRM provider abstractions: `docs/design/vendor-integration-and-provider-abstractions.md`

## Current state (what we already have)

Strong foundations already implemented:
- **GitOps operating model**: bootstrap stages only seed Forgejo/Argo; steady-state reconciles from `platform/gitops/**` (`docs/design/gitops-operating-model.md`).
- **Core platform blocks**: OpenBao+ESO (implemented via `secrets/vault` component path compatibility), Keycloak, cert-manager, Step CA (current internal/private issuer path), Vault PKI as the implemented high-assurance external issuer path, Istio (STRICT mTLS), Cilium, MetalLB, PowerDNS/ExternalDNS, LGTM observability (`target-stack.md`, component READMEs).
- **Early tenancy scaffolding**: label-driven namespace RBAC sync + Keycloak→Forgejo team sync (`platform/gitops/components/shared/rbac/README.md`).
- **Admission guardrails + policy engine**: access-plane guardrails via Kubernetes `ValidatingAdmissionPolicy` (`platform/gitops/components/shared/access-guardrails`) and tenant baseline constraints via Kyverno (`platform/gitops/components/shared/policy-kyverno`). Designs: `docs/design/cluster-access-contract.md`, `docs/design/policy-engine-and-baseline-constraints.md`.
- **Validation jobs doctrine**: repo-wide rules for smoke/cron validation and evidence capture (`docs/design/validation-jobs-doctrine.md`).
- **Deployment config contract (v1alpha1)**: validated per-deployment identity + elimination of per-env “overlay path patch lists” via controller-owned `PlatformApps` catalog (`docs/design/deployment-config-contract.md`).
- **Provisioning contract v0 (schema + examples)**: the first repo-truth "single YAML" baseline is now a validated multi-document bundle of `DeploymentConfig` + `Tenant` + `TenantProject` (`docs/design/provisioning-contract-v0.md`, `platform/gitops/deployments/examples/provisioning-v0/`).
- **Ops readiness baseline now evidenced for one tier-0 component**: cert-manager has a live Proxmox GitOps rollback/forward-upgrade rehearsal with self-signed, Step CA, and Vault issuance validation .
- **Bootstrap trust-chain (SOPS bundles)**: per-deployment bootstrap secret scoping via the Deployment Secrets Bundle (DSB) (`docs/design/deployment-secrets-bundle.md`) — implemented (see evidence under `docs/evidence/`).
  - Operator playbook: `docs/guides/bootstrap-new-cluster.md`.
  - SOPS Age key custody gate (prod): `docs/toils/sops-age-key-custody.md`.
  - Two-phase Age rotation helper: `docs/toils/sops-age-key-rotation.md`.

Major gaps vs the vision:
- No **multi-cluster / fleet lifecycle** layer (no Cluster API or equivalent in-repo).
- No **end-to-end provisioning controller/workflow** yet; Stage 0/1 scripts are still the primary “creation mechanism”.
  - The v0 "single YAML" contract now exists as a validated bundle of existing APIs (`docs/design/provisioning-contract-v0.md`), but the bundle is not yet the direct runtime entrypoint.
- No **BGP/VRF/anycast** implementation; MetalLB configuration is L2-only today (BGP is explicitly “future”).
- Storage is still **single-site oriented**:
  - Standard profiles are NFS-backed for PVCs via `shared-rwo` (default StorageClass). A general-purpose `shared-rwx` StorageClass is not shipped by default today; RWX is treated as “backup-plane only” when needed.
  - Single-node profile v1 moved the default PVC path to node-local RWO for performance and also treats RWX as “backup-plane only”.
  This still blocks “true three-zone” resilience for stateful tier-0 services unless we adopt a multi-zone storage strategy.
- **DR maturity is still incomplete**, but the repo now has an implemented baseline:
  - `backup-system` ships the off-cluster backup target, backup smokes, restore tooling, and full-restore staleness enforcement (`docs/design/disaster-recovery-and-backups.md`, `docs/component-issues/backup-system.md`).
  - Remaining work is now narrower: hardening, blast-radius reduction, and stronger routine restore evidence in the dedicated `backup-system` tracker.

## Things we are doing today that will block (or create painful rework)

1) **Hard-coded deployment identity**
- Many components and scripts reference concrete domains like `*.internal.example.com` (still true today).
- The per-env “dev vs prod overlay path” patch lists for Argo `Application`s are now controller-owned through `PlatformApps` (`platform-apps-controller`) overlays.
Risk: scaling to “many deployments” or “multi-customer hosted” becomes brittle and high-toil unless identity/config is centralized.

2) **Platform core and tenant workloads are mixed**
- The environment-neutral base includes example apps (e.g., Factorio/Minecraft).
Risk: productizing a “cloud” requires a clean separation between platform core, managed services, and tenant workloads/catalog installs.

3) **Guardrails exist, but require “controller allow-list discipline”**
- Admission guardrails are intentionally strict and protect access-critical types (RBAC, webhook configs, CRDs, admission resources).
- Some Kubernetes/in-cluster controllers must be allow-listed to reconcile/rotate their own resources (e.g., webhook `caBundle`, namespace teardown).
Risk: missing allow-list exceptions can deadlock reconciliation (e.g., namespaces stuck in `Terminating`) unless we keep the allow-list narrow and documented (and prove it via smoke jobs).

4) **Access to Kubernetes is becoming a product contract, but needs automation closure**
- We now have the core ingredients in-repo: OIDC login helper, GitOps RBAC + admission guardrails, and a documented offline breakglass SOP/drill (dev evidenced).
- Still missing: an automated/scheduled end-to-end OIDC smoke path and prod breakglass drill evidence.
Risk: if we do not close the loop with routine validation, access will become the #1 operational risk as soon as multiple tenants/clusters/customers exist.

5) **Single-site storage assumptions**
- NFS-backed PVCs (and any RWX backup-plane usage) are fine for dev and some small installs, but they are fundamentally incompatible with “zone-loss” resilience for tier-0 state.
Risk: if we entrench tier-0 persistence on single-zone storage, “three-zone” later becomes a large migration with high risk.

## Essential foundations to implement ASAP (stability prerequisites)

These are high-leverage because they reduce future complexity and are prerequisites for self-service and multi-tenancy.

1) **Access governance as a product feature**
- Implement a full access contract including:
  - “RBAC changes via Git only” (four-eyes via PR approvals)
  - prevention of kubectl bypass (admission controls)
  - breakglass entry and rotation
Ref: `docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`
Design: `docs/design/cluster-access-contract.md`

2) **Policy engine + tenant baseline constraints**
- Prefer Kubernetes built-in `ValidatingAdmissionPolicy` where sufficient; add Kyverno/Gatekeeper only when required by policy complexity.
- Ship baseline policies for:
  - namespace/tenant labeling requirements
  - default-deny networking posture (with controlled exceptions)
  - resource quotas/limits and forbidden patterns
This is required before “marketplace” and any real multi-tenant promises.
Design: `docs/design/policy-engine-and-baseline-constraints.md`

Implemented (Phase 0):
- `shared/access-guardrails` is implemented with smoke CronJobs and evidence (dev):.
- `shared/policy-kyverno` is implemented with a baseline smoke CronJob and evidence (dev):.

3) **Central “deployment config” contract**
- Create a single source of truth for domains/hostnames, trust roots, IP pools, network handoff mode (L2 vs eBGP), and environment IDs.
- Refactor existing overlays to consume it rather than patching dozens of apps.

Implemented (Phase 1–3):
- Contract + schema: `platform/gitops/deployments/<deploymentId>/config.yaml` + `platform/gitops/deployments/schema.json`
- Validation: `tests/scripts/validate-deployment-config.sh` (required fields + `.internal` convention + baseDomain uniqueness)
- Guardrail: `tests/scripts/check-hardcoded-domains.sh` (currently permissive until Phase 4 tightens allowed locations)
- GitOps toil reduction: `PlatformApps` CR + `platform-apps-controller` overlays (replaces the legacy per-app overlay patch lists and retired render artifacts).

Still missing (Phase 4):
- Components/scripts consuming hostnames/IP pools/trust roots from the contract (to remove remaining hard-coded identity under `platform/gitops/components/**` and tighten the guardrail).

Ref: `docs/design/deployment-config-contract.md`

4) **Supply-chain and artifact discipline**
- Pin chart/image versions (and ideally digests), and move toward an in-cluster registry + mirroring story for regulated/air-gapped deployments.
- Marketplace and managed services require this to be credible.
- Baseline policy + lint (tier-0): `docs/design/supply-chain-pinning-policy.md`, `tests/scripts/validate-supply-chain-pinning.sh`, `tests/fixtures/supply-chain-tier0-pinning.tsv`.

5) **Platform/tenant separation**
- Split “platform core” from “example apps” and later from “marketplace offerings”.
- This reduces blast radius and makes multi-tenant governance tractable.

6) **Ops readiness (upgrades + backup/restore drills)**
- For regulated environments, “it deploys” is not sufficient: we must be able to **upgrade** safely and **restore** tier-0 state.
- The cross-cutting baseline is now closed at the roadmap level by the cert-manager rehearsal captured in the public evidence subset.
- Remaining work should stay component-local and focus on materially different risk profiles rather than duplicating the same proof shape in the roadmap tracker.
- Minimum: documented and practiced procedures with evidence capture for:
  - upgrades/rollback of platform components (and later Kubernetes/Talos)
  - backup + restore drills for tier-0 data (OpenBao, CNPG/Postgres, Forgejo/Keycloak state as applicable)

7) **Provisioning contract (single YAML)**
- Freeze the “single YAML”/KRM contract early (schema + examples + validation), even if the first implementation still wraps Stage 0/1 scripts.
- This prevents divergent bootstrap procedures and keeps the future UI/marketplace aligned to a stable API.
Ref: `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`

Implemented (v0 contract baseline):
- `docs/design/provisioning-contract-v0.md`
- `platform/gitops/deployments/examples/provisioning-v0/`
- `tests/scripts/validate-provisioning-bundle-examples.sh`

Still missing:
- a controller/bootstrap entrypoint that consumes the bundle directly

## Roadmap (low-complexity order of implementation)

This roadmap intentionally builds “small single-tenant installs” first, while enforcing invariants that prevent blocking the long-term goals.

### Phase 0 — Sellable single-zone foundation (no multi-zone yet)

Goal: a small deployment (doctor’s office) that is secure, repeatable, and maintainable.

Deliverables:
- Kubernetes access contract: OIDC + four-eyes RBAC workflow + breakglass ready.
- Policy engine with baseline constraints (even if there is only one tenant).
- Central deployment config contract (implemented; Phase 4 remaining to eliminate hard-coded identity in components).
- Supply-chain baseline: pinned versions (and ideally digests) for tier-0 components + an explicit artifact mirroring plan for regulated/air-gapped installs.
- Platform/tenant separation: platform core runs without example apps by default (apps become opt-in / separate bundles).
- Ops readiness baseline: documented + practiced upgrade/rollback and backup/restore drills for tier-0 components (baseline now evidenced; remaining work continues in component trackers).
- Provisioning contract v0: a validated “single YAML” schema + examples for “small single-zone deployment + first tenant” (controller can come later).

Exit criteria:
- Onboarding/offboarding and “troubleshooting escalation via Git” is repeatable and evidenced.
- A tenant baseline can be applied and is enforced by admission.

Phase 0 implementation tracking is kept in canonical trackers:
- `docs/component-issues/cloud-productization-roadmap.md` (cross-cutting roadmap items)
- `docs/component-issues/access-guardrails.md` (OIDC smoke + breakglass readiness + alerting/staleness)
- `docs/component-issues/policy-kyverno.md` (baseline smoke + alerting/staleness)
- `docs/component-issues/backup-system.md` (full-deployment DR baseline)

### Phase 1 — Tenant contract (single cluster)

Goal: define tenancy boundaries that scale to hosted multi-customer later.

Deliverables:
- Tenant/customer object model (namespaces/projects, quotas, netpol, OpenBao secret paths, Argo Projects, Forgejo teams).
- GitOps onboarding/offboarding workflow with four-eyes and evidence.

Exit criteria:
- Tenant isolation is enforceable by policy (not just convention).

### Phase 2 — Multi-cluster per tenant (cluster-as-a-service, single-zone)

Goal: prove the platform can create and operate multiple workload clusters per tenant/customer.

Deliverables:
- Choose and implement a cluster lifecycle substrate (Cluster API or a clearly justified alternative).
- Create a second workload cluster from a management plane and enroll it into GitOps.
- Standardize cluster identity (cluster IDs, naming, secrets paths).
- Optional (but recommended before Phase 5): implement a **single-zone BGP mode** for ingress VIPs (MetalLB BGP or Cilium BGP), with runbooks + evidence, so “BGP in production” is not first introduced during multi-zone work.

Exit criteria:
- “Create/upgrade a workload cluster” is a repeatable, declarative workflow (ideally driven from the same API planned for “single YAML”).

### Phase 3 — Hosted multi-customer with hard isolation

Goal: multiple customers/tenants in one deployment with side-channel-resistant isolation.

Deliverables:
- Dedicated physical server pool modeling per tenant/customer and enforcement (admission + scheduling + inventory binding).
- Repo/IAM scoping model that scales approvals and visibility (four-eyes for access changes, least privilege by default).

Exit criteria:
- It is mechanically hard to accidentally grant cross-customer access or co-locate workloads on shared physical servers in “regulated tier”.

### Phase 4 — Marketplace (curated vs fully managed services)

Goal: public-cloud-like ordering surface with clear responsibility boundaries.

Deliverables:
- Catalog + instance API (CRDs) and validation policy.
- One curated offering (tenant-owned ops) end-to-end.
- One fully managed service (provider-owned SLO) end-to-end.

Exit criteria:
- Users can order services via Git (PR) with policy validation and predictable reconciliation.
Ref: `docs/ideas/2025-12-26-marketplace-managed-services.md`

### Phase 5 — True three-zone + anycast/BGP

Goal: survive loss of an entire zone/site (three-zone requirement).

Deliverables:
- Prereq: single-zone BGP mode has already been proven (runbooks + evidence) in earlier phases; Phase 5 should not be the first time we operate BGP.
- Anycast/BGP “regional VIP” design implemented (with health gating and fast withdraw).
- Three-zone reference architecture with explicit RTT/quorum constraints.
- Multi-zone storage strategy for tier-0 state and a zone-failure drill with evidence.

Exit criteria:
- A documented drill demonstrates “zone loss → converged steady-state” with measurable targets.
Ref: `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`

## Key decisions to freeze early (to avoid churn)

- Policy engine choice + split of responsibilities: keep access-plane invariants in VAP; use Kyverno for tenant baseline constraints and PolicyExceptions.
- Cluster lifecycle substrate (CAPI vs alternative) and where its desired state lives (direct CRs vs generated Git).
- Network contract for “L2 mode vs eBGP mode” (same higher-level interface, different implementation).
- Storage strategy trajectory: explicitly decide what is “single-zone only” until multi-zone storage is implemented.
