# Idea: KRM-First “Cloud UI” That Only Authors GitOps CRs (Air-Gapped Friendly)

Date: 2025-12-25
Status: Draft

## Problem statement

DeployKube’s long-term vision includes **air-gapped** cloud deployments that remain **100% declarative** and GitOps-driven, but are still easy to operate for teams that expect a “cloud console” experience.

The challenge is reconciling:
- **Usability** (AWS/GCP-like UI workflows)
- **Declarative intent** (KRM / CRDs as the interface)
- **Auditability & control** (GitOps, reviews, policy gates)
- **Air-gapped delivery** (offline artifacts, upgrades, provenance)

## Why now / drivers

- Air-gapped clouds magnify operational friction: every manual step becomes expensive and hard to audit.
- GitOps is already the repo’s operating model; improving “day-2 UX” without abandoning GitOps is strategically aligned.

## Proposed approach (high-level)

Build a web UI similar to AWS/GCP, but it **never** mutates cluster state directly.

Instead, the UI:
1. Generates KRM YAML (CRs and/or higher-level platform CRDs).
2. Writes it to Git as commits/PRs (or to a “workspace” branch) against the GitOps repo.
3. Runs validation (policy, lint, dry-run render) and shows the “plan”.
4. Lets Argo CD reconcile and then shows convergence status + health.

Key property: the UI is a **Git client + status dashboard**, not a direct control plane.

## What is already implemented (repo reality)

DeployKube already provides several foundational blocks required for this workflow:

- GitOps control-plane split: bootstrap stages hand off to Argo CD for steady state (`docs/design/gitops-operating-model.md`).
- In-cluster Git: Forgejo hosts the repo Argo syncs from (`platform/gitops/components/platform/forgejo/README.md`).
- GitOps reconciliation: Argo CD syncs `platform/gitops/**` via “app-of-apps” bundles (`platform/gitops/apps/**`).
- Identity foundation: Keycloak-backed SSO is integrated for Argo CD and Forgejo (`target-stack.md` and component READMEs).
- Secrets patterns: Vault + External Secrets Operator are implemented as the default secrets posture (`target-stack.md`).
- Early multi-tenant scaffolding:
  - Label-driven namespace RBAC reconciliation (`platform/gitops/components/shared/rbac/**`).
  - Keycloak group → Forgejo team sync scaffolding (see `docs/design/rbac-architecture.md`).
- Partial offline helpers (dev): registry cache + image warm tooling exists for the mac-orbstack flow (`docs/guides/mac-orbstack.md`).

## What is missing / required to make this real

### 1) Define the platform API (the “Cloud” CRDs)

Right now, users would mostly be authoring raw Kubernetes resources and vendor/operator CRDs (Istio, cert-manager, CNPG, etc.).

For a “cloud console” UX, we likely need a stable set of **platform-level APIs** (even if internally they compose existing operators), e.g.:
- `Customer` / `Tenant` / `Project`
- `WorkloadCluster` / `Environment`
- `Database` (Postgres) / `Bucket` (S3) / `Cache` (Valkey) abstractions
- `DNSRecord` / `Certificate` / `IngressRoute` abstractions

This implies long-term commitments: API versioning, migration, compatibility, and deprecation policy.

### 2) Guardrails: policy enforcement and safe self-service defaults

To make “UI-generated GitOps” safe, the cluster must enforce rules regardless of the UI:
- Admission policies (Kyverno/Gatekeeper) to restrict cluster-scoped writes, enforce labels/owners, constrain images/registries, require NetworkPolicies, etc.
- Baseline multi-tenant controls per namespace (ResourceQuota, LimitRange, default-deny netpol patterns).

Without these, the UI increases the blast radius by making it easier to submit unsafe manifests.

### 3) Workflow: PR/approval/plan UX that matches GitOps reality

GitOps is asynchronous; the UI must make that visible:
- Preview (“what will change”), policy results, and ownership checks before merge.
- Clear “pending → applied → converged/failed” states mapped to Argo Application health/sync.
- Rollback UX via Git revert and Argo sync.

### 4) Air-gapped completeness (artifacts + upgrades)

The hardest part of air-gapped operation is artifact management and upgrades:
- A first-class in-cluster registry (e.g., Harbor) or equivalent offline distribution.
- Mirroring and pinning of:
  - container images
  - Helm charts / OCI artifacts
  - CRDs and operator artifacts
  - (if applicable) Talos/Kubernetes artifacts
- A documented, tested upgrade pipeline that works offline.

### 5) In-cluster CI/CD runner (optional, but likely needed)

If “apply against CI/CD interactively from the WebUI” is a core requirement, we likely need a runner that works in air-gapped mode (Forgejo Actions runners, or another approach) to execute:
- schema validation
- kustomize/helm rendering
- policy checks
- “plan” diffs

## Risks / weaknesses

- **CRDs are a product surface**: exposing platform CRDs means long-term compatibility work.
- **Leaky abstraction risk**: if the UI doesn’t hide complexity, users will still debug raw operators.
- **Mismatch with “cloud console” expectations**: GitOps latency and approvals must be a first-class UX element.
- **Actions vs desired state**: one-shot operations (restore/rotate/migrate) must be modeled carefully to avoid repeated side effects.
- **Air-gapped burden**: offline artifact mirroring and upgrade orchestration is a major engineering stream.

## Alternatives considered

- UI as “read-only dashboard + links”: lower effort, but doesn’t improve onboarding/self-service much.
- UI directly mutating the cluster: better immediacy, but breaks GitOps/auditability and is harder to secure.
- Keep only raw Kubernetes + docs: lowest engineering cost, but doesn’t meet usability goals for broader audiences.

## Open questions

- What is the scope of “cloud”?
  - Kubernetes-only self-service (apps + managed services), or also hardware/cluster provisioning?
- Is the UI intended for:
  - platform operators only, or also app teams / end users?
- Do we want a small “paved path” API (few CRDs) or a broad cloud-like API surface?
- What is the required approval model (PR required always, or “fast path” branches for trusted teams)?
- What is the offline distribution target (single ISO/USB bundle, registry mirror, or both)?

## Promotion criteria (to `docs/design/**`)

Promote this idea once the following are decided and documented:
- A minimal platform API surface (initial CRDs/resources) and ownership model.
- The guardrail stack (policy engine choice, namespace baseline requirements).
- The GitOps workflow model from the UI (PR-based flow, validation gates, status model).
- The air-gapped artifact strategy (registry, mirroring, pinning, upgrade procedure).

