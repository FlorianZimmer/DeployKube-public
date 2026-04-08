# GitOps Operating Model

DeployKube is now GitOps-first: Stage 0/Stage 1 bootstrap prepares the cluster and seeds Forgejo + Argo CD, then the `platform-apps` root Argo CD `Application` reconciles the platform from `platform/gitops/`.

This document is the evergreen reference for **how the repo is operated** (what lives where, what Stage 0/Stage 1 do, and how to ship changes). Component-specific architecture, runbooks, and implementation details live in the component READMEs under `platform/gitops/components/**/**/README.md`, with cross-cutting alert/incident runbooks under `docs/runbooks/`. Open work items live under `docs/component-issues/`.

## Tracking

- Canonical tracker: `docs/component-issues/gitops-operating-model.md`

## Scope / ground truth
- This document is validated against what is implemented in-repo (scripts + manifests + docs), not against live cluster state.
- If a statement cannot be verified from the repository, it should not live here.

## Source of truth (repo split)
- Argo CD pulls desired state from the **Forgejo mirror** repo. The mirror is seeded from this monorepo via `shared/scripts/forgejo-seed-repo.sh`.
- The seed helper snapshots `platform/gitops` from the DeployKube git **`HEAD` commit** (uncommitted working tree changes are ignored). Commit before seeding.
- `platform/gitops/` is **not** a standalone git repository and must not contain its own `.git/` directory.

## Directory map
- `scripts/` – operator entrypoints (what you run). See `scripts/README.md`.
- `shared/scripts/` – Stage 0/Stage 1 implementations and helpers (Forgejo seeding, teardown, token helpers, etc.).
- `bootstrap/<env>/` – host-side inputs consumed by Stage 0/Stage 1 (kind/Talos config, bootstrap chart values, etc.).
- `platform/gitops/apps/` – Argo CD `Application` definitions and environment bundles (app-of-apps).
- `platform/gitops/components/` – component manifests (Helm/Kustomize), overlays, Jobs, and component READMEs.
- `platform/gitops/tenants/` – platform-owned multitenancy “tenant intent” folders (tenant metadata + namespace intent).
- `docs/design/` – cross-cutting design notes (RBAC, promotion, observability designs, etc.).
- `docs/apis/` – API reference docs for product-owned CRDs (`*.darksite.cloud`).
- `docs/guides/` – planned playbooks (bootstrap/release/restore), usually spanning multiple components.
- `docs/runbooks/` – alert/incident response runbooks (targets for alert `runbook_url` annotations).
- `docs/toils/` – operational how-tos and troubleshooting that are not directly tied to a specific alert.
- `docs/ideas/` – pre-implementation idea notes that are promising but not yet ready to become executable designs (`docs/ideas/README.md`).
- `docs/component-issues/` – open vs. resolved items per component (keep TODOs out of component READMEs).
- `docs/evidence/` – dated evidence logs (Argo status + smoke outputs) for changes and troubleshooting.
- `target-stack.md` – platform constraints and version expectations.
- `tmp/` – ephemeral scratch space for bootstrap sentinels and local logs (do not rely on it as a long-term record).

## Bootstrap model (Stage 0 / Stage 1)

Stage 0 and Stage 1 are intentionally small and exist only to get the GitOps control plane running.

### Stage 0 responsibilities (cluster preparation)
Stage 0 is allowed to:
- create/provision the cluster (kind on OrbStack, Talos on Proxmox) and perform required host-side setup (e.g., OrbStack NFS helper).
- install foundational prerequisites that must exist before Forgejo/Argo can function (CNI, baseline LoadBalancer support, baseline `shared-rwo` PVC storage, Gateway API CRDs, and bootstrap tooling images).

Stage 0 is **not** allowed to install or configure platform components beyond those prerequisites.

### Stage 1 responsibilities (Forgejo/Argo bootstrap + handoff)
Stage 1 is allowed to:
- install Forgejo + Argo CD with bootstrap values.
- seed the Forgejo mirror repo from `platform/gitops` using `shared/scripts/forgejo-seed-repo.sh`.
- apply Argo CD `AppProject/platform` before the root app (so platform apps can use `spec.project: platform` from the first sync).
- apply the root Argo CD `Application` (default name: `platform-apps`) pointing at `platform/gitops/apps/environments/<env>`.
- place the SOPS Age key into the Argo CD namespace so Argo can decrypt SOPS-managed material.

Stage 1 is **not** allowed to apply component manifests directly; the steady-state must converge via Argo CD sync.

## Change workflow (GitOps loop)
1. Change manifests under `platform/gitops/**` (and update docs/evidence as needed).
   - If you add a platform `Application` that references an upstream Helm repo (`spec.source.repoURL: https://...`), also add that repo to `AppProject/platform` (`platform/gitops/apps/base/appproject-platform.yaml`) or Argo will reject the `Application` as `InvalidSpec`.
   - If you onboard a new tenant/project (legacy tenant intent surface), update the tenant registry + folders + tenant intent `Application`s and run:
     - `./tests/scripts/validate-tenant-folder-contract.sh`
     - `./tests/scripts/validate-tenant-intent-applications.sh`
     - `./tests/scripts/validate-tenant-intent-surface.sh`
   - Planned direction: onboarding via a single `Tenant` CR (KRM-native) reconciled by a tenant provisioner controller (no in-flight render scripts). See: `docs/design/tenant-provisioning-controller.md`.
2. Commit the change (Forgejo seeding snapshots git `HEAD`).
3. Seed the Forgejo mirror:
   - `FORGEJO_FORCE_SEED=true./shared/scripts/forgejo-seed-repo.sh`
   - Treat seeding as a privileged deployment action in mirror mode (it can bypass PR controls); prefer CI-only execution after merge with evidence.
4. Force Argo to re-fetch and reconcile (kubectl-only fallback):
   - `kubectl -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite`

Gotcha (existing clusters):
- `AppProject/default` is deny-by-default. If your cluster was bootstrapped before the `platform` project migration and `Application/platform-apps` is still in `spec.project: default`, patch it to `platform` before/after seeding. See: `docs/toils/forgejo-seeding.md`.

## Live troubleshooting vs. guardrails
Argo CD typically runs with `selfHeal` enabled, so live `kubectl apply` changes are expected to drift and be reverted unless you pause auto-sync for the affected `Application`.

Separately, DeployKube enforces **admission guardrails** that deny manual changes to access-critical resource types (RBAC objects, CRDs, admission policies/bindings, webhook configurations). For those resource types, pausing auto-sync does not help: you must ship the change via GitOps, or use breakglass with evidence. See `docs/design/cluster-access-contract.md`.

## Dev → Prod
Environment differences are expressed via:
- component overlays: `platform/gitops/components/**/overlays/<env>/`
- environment bundles: `platform/gitops/apps/environments/<env>/`

Promotion guidance lives in `docs/design/dev-to-prod-promotion.md`.

## HA tiering contract (proxmox-talos)

For the prod-like `proxmox-talos` deployment, availability policy is tiered (not global `replicas: 3` everywhere):
- Minimum worker-node baseline is 3 (`bootstrap/proxmox-talos/config.yaml`).
- Every rendered platform `Deployment`/`StatefulSet` in the `proxmox-talos` profile must define `darksite.cloud/ha-tier` on:
  - workload metadata labels
  - pod-template labels
- Allowed values:
  - `tier-0`: odd quorum replicas, minimum 3
  - `tier-1`: minimum 2 replicas
  - `tier-2`: singleton/non-critical allowed

CI enforcement source of truth:
- `tests/scripts/validate-ha-three-node-deadlock-contract.sh`
  - validates label presence/value/floors
  - validates anti-affinity rollout deadlock guards for hard anti-affinity workloads
  - validates Argo bootstrap rollout defaults used for small fixed node pools

## Evidence discipline
For every platform change:
- update the relevant component README(s) under `platform/gitops/components/**/**/README.md` (architecture/runbooks), and track open work in `docs/component-issues/<component>.md`.
- capture a short evidence log under `docs/evidence/YYYY-MM-DD-<topic>.md` using evidence format v1 (`docs/evidence/README.md`) and the template (`docs/templates/evidence-note-template.md`), including: the Git commit, Argo `Synced/Healthy` status (or `N/A` for repo-only changes), and the smoke-test command/output you used.

## Cross-cutting conventions (avoid component duplication)
- **Secrets**: prefer Vault + External Secrets Operator for steady-state secrets; use SOPS only for bootstrap-only material as warranted by `.sops.yaml`.
- **Deployment-scoped SOPS bundles (implemented)**: bootstrap-only SOPS material is per-deployment under `platform/gitops/deployments/<deploymentId>/secrets/`; see `docs/design/deployment-secrets-bundle.md` and lint via `tests/scripts/validate-deployment-secrets-bundle.sh`.
- **Job/CronJob termination in Istio-injected namespaces**: use Istio native sidecars (`sidecar.istio.io/nativeSidecar: "true"`) and the shared exit helper at `platform/gitops/components/shared/bootstrap-scripts/istio-native-exit` so batch pods reach `Complete` cleanly.
- **Validation jobs** (smoke tests, periodic checks, Argo verification): follow `docs/design/validation-jobs-doctrine.md` for uniform quality gates and review requirements.
- **Shared resource ownership**: for any shared ConfigMap/Secret/CR (e.g., `istio-native-exit-script`), ensure exactly one Argo CD Application owns it per namespace to avoid drift between apps.

## Release gate (runtime E2E)

Some validations require a live cluster and intentionally mutate `DeploymentConfig` to validate mode matrices (for example certificate modes and Keycloak IAM modes).

Before a full release, run the Release E2E Gate against the Proxmox cluster:
- Procedure: `docs/toils/release-e2e-gate.md`
- Local trigger: `scripts/release/release-gate.sh`
