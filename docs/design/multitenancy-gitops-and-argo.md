# Design: Multitenancy GitOps and Argo CD (AppProjects + Tenant PR Flow)

Last updated: 2026-01-24  
Status: **Design (Phase 0/1 foundations exist; Phase 2+ planned)**

This document defines how DeployKube expresses and enforces **multitenancy** using **GitOps + Argo CD**:
- a per-org/project `AppProject` + `Application` model,
- repo/path restrictions (Forgejo + Argo),
- a tenant PR flow with validation gates,
- scale budgets and “switch thresholds” (when to change the architecture tier).

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy-gitops-and-argo.md`

## Related docs (inputs / constraints)

- Tenancy model, labels, naming, and governance: `docs/design/multitenancy.md`
- Label registry (contract): `docs/design/multitenancy-label-registry.md`
- Networking (deny-by-default, route hijack posture, budgets): `docs/design/multitenancy-networking.md`
- Storage (S3/PVC/backup boundaries; ESO/ExternalSecret gotchas): `docs/design/multitenancy-storage.md`
- Tenant lifecycle/offboarding (what must be deleted): `docs/design/multitenancy-lifecycle-and-data-deletion.md`
- GitOps boundary and ops workflow: `docs/design/gitops-operating-model.md`
- Access contract + admission guardrails: `docs/design/cluster-access-contract.md`
- RBAC persona/group architecture: `docs/design/rbac-architecture.md`
- Validation jobs doctrine: `docs/design/validation-jobs-doctrine.md`
- Argo CD component (repo creds, OIDC, current RBAC config): `platform/gitops/components/platform/argocd/README.md`

---

## Scope / ground truth

- Repo-grounded: this doc describes the model we will implement under `platform/gitops/**` and enforce via Argo CD `AppProject` boundaries + admission guardrails.
- This doc does not claim live cluster state or measured scaling numbers; budgets are **initial targets** that must be validated in dev/prod before “hostile tenants” (Tier S productization).
- Focus: **shared-cluster tenancy (Tier S)**. Dedicated tenancy (Tier D/H) appears only as an explicit switch threshold.

MVP scope reminder:
- Queue #11 implements **Tier S** Argo boundaries (AppProjects + tenant registry) first.
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for the MVP, but Tier S work must not block future multi-cluster:
  - keep tenant repo boundaries repo-shaped (repo-per-project), so “move project to another cluster” is primarily a destination change in platform-owned Argo registry objects,
  - avoid cluster-specific identity in `orgId`/`projectId` (those remain stable across clusters).

---

## 1) Goals

1. **GitOps-first tenant delivery**  
   Tenants ship changes by PR; Argo CD reconciles. Tenants do not need direct `kubectl` mutation rights for day-2.

2. **Hard GitOps boundaries in Argo**  
   A tenant cannot affect other tenants by:
   - pointing Argo at other repos/paths, or
   - deploying into other namespaces/clusters, or
   - applying access-plane resources (RBAC/admission/CRDs/webhooks).

3. **No global Argo RBAC growth per tenant**  
   Adding orgs/projects must not require editing `argocd-rbac-cm` for each tenant.
   Tenant access is expressed in `AppProject.spec.roles[].groups` (per-tenant objects), not global CSV policy growth.

4. **Clear PR flow with validation gates**  
   Tenant PRs are reviewable, structurally validated, and constrained by policy before they can impact the cluster.

5. **Explicit scale budgets and switch thresholds**  
   We define “how many orgs/projects/apps” are acceptable per tier and what we do when we exceed those numbers.

---

## 2) Non-goals (for this design)

- This document is not the canonical design for the “Tenant API” (CRDs/controllers). See: `docs/design/tenant-provisioning-controller.md`.
- Allowing tenants to mutate access-plane resources directly (Kubernetes RBAC, admission, CRDs, Argo config).
- Claiming shared-cluster tenancy is side-channel resistant (see Tier S honesty in `docs/design/multitenancy.md`).

---

## 3) Imported invariants (must align)

This design assumes and does not redefine:

- **Org identity contract (implemented)**: `darksite.cloud/tenant-id == observability.grafana.com/tenant` (VAP-enforced).
  - Source: `docs/design/multitenancy.md`, `docs/design/multitenancy-label-registry.md`
- **Project identity contract (implemented)**: `darksite.cloud/project-id=<projectId>` is required for tenant namespaces and is immutable after creation (VAP-enforced).
  - Source: `docs/design/multitenancy.md`, `docs/design/multitenancy-label-registry.md`
- **Namespace naming (recommended)**: `t-<orgId>-p-<projectId>-<env>-<purpose>`
  - Source: `docs/design/multitenancy.md`
- **Tenants cannot create namespaces or change identity labels** (Git-only onboarding/offboarding).
  - Source: `docs/design/multitenancy.md`, `docs/design/cluster-access-contract.md`
- **Access-plane changes are GitOps-only** and protected by admission guardrails.
  - Source: `docs/design/cluster-access-contract.md`

---

## 4) The model (what exists vs what we add)

### 4.1 Repo reality today (implemented)

- Argo CD reconciles from the Forgejo mirror repo seeded from `platform/gitops/` (`docs/design/gitops-operating-model.md`).
- Platform apps are defined as individual `Application` objects under `platform/gitops/apps/**` and use Argo project `default` (no `AppProject` boundaries yet).

### 4.2 What we add for multitenancy (planned)

We introduce new Argo primitives and a “tenant registry” layer:

1. **A strict platform `AppProject` (`platform`)** and a locked-down `default` (deny-by-default) posture.
2. **One `AppProject` per tenant org**, optionally per tenant project.
3. **One root `Application` per tenant project** (recommended), which points at that project’s GitOps source.

Result: tenants can ship workloads independently, while Argo enforces:
- which repos can be read,
- which namespaces can be targeted,
- which Kubernetes kinds can be applied.

Tenant registry (definition):
- “Tenant registry” is the **platform-owned Git-managed directory** that contains tenant `AppProject` objects and tenant root `Application` objects.
- Proposed location: `platform/gitops/apps/tenants/` and included by the active environment kustomization under `platform/gitops/apps/environments/**`.
- Tenants do **not** edit this registry in v1; it is part of the access-plane boundary and follows four-eyes + evidence discipline.

Planned direction (KRM-native):
- represent tenant onboarding intent as a `Tenant` CR (GitOps-applied), and let a controller converge the corresponding `AppProject`/`Application` objects and external side effects. See: `docs/design/tenant-provisioning-controller.md`.

---

## 5) AppProject model (the security boundary)

`AppProject` is the primary Argo isolation boundary. Treat it as part of the “access contract”.

### 5.1 Naming

Recommended:
- Org boundary: `tenant-<orgId>`
- Optional tighter project boundary: `tenant-<orgId>-p-<projectId>`
- Platform boundary: `platform` (dedicated; used by all platform `Application` objects)
- `default` AppProject: **deny-by-default** so forgetting `spec.project` is safe (it should not be a usable boundary)

### 5.2 Destinations (namespace restrictions)

Use namespace globbing to match the naming convention from `docs/design/multitenancy.md`:

- Org-scoped project allows all project namespaces for that org:
  - `t-<orgId>-p-*-*`
- Project-scoped project allows only that project:
  - `t-<orgId>-p-<projectId>-*`

Important:
- Prefer **project-scoped AppProjects** when you need strong separation between teams/environments inside one org.
- Prefer **org-scoped AppProjects** when you want fewer Argo objects and “projects are a soft boundary” (the default stance in `docs/design/multitenancy.md`).

### 5.3 Source repos (repo restrictions)

Preferred (Tier S1 “product mode”): **repo-per-project** in Forgejo (recommended already in `docs/design/multitenancy.md`):
- Forgejo org: `tenant-<orgId>`
- Project repo: `apps-<projectId>`

Then `AppProject.spec.sourceRepos` can be strict and simple:
- Org-scoped: allow only repos in `tenant-<orgId>`
- Project-scoped: allow only that one repo

Repo authentication (planned):
- Prefer **read-only Forgejo robot credentials** scoped to the tenant org/project.
- Store the credential in Vault and project it into `argocd` via ESO as Argo repo credentials (either per-repo `repository` Secret or per-org `repo-creds` Secret).
- This is a product requirement for repo-per-project mode; avoid a single “read everything” Git credential before hostile tenants.

Fallback (Tier S0 “friendly tenants only”): monorepo-in-one-repo, where tenant manifests live under `platform/gitops/tenants/<orgId>/...`.
- Argo cannot restrict by path inside a repo; only by repo URL.
- In this mode, path boundaries must be enforced by:
  - platform-owned `Application.spec.source.path` (tenants cannot edit Applications), and
  - Git governance (Forgejo permissions + CODEOWNERS + required approvals).
  
This fallback is explicitly **not** the Tier S1 isolation story, because “hard boundaries in Argo” require repo-level separation.

### 5.4 Resource allow/deny (apply surface)

Tenant AppProjects must default to a **strict whitelist** and grow only with evidence.

Baseline intent (Tier S):
- **Deny all cluster-scoped resources** (no `Namespace`, no `CRD`, no `ClusterRole*`, no `ValidatingAdmissionPolicy`, no `MutatingWebhookConfiguration`, etc.).
- **Deny access-plane namespaced resources** unless explicitly productized:
  - RBAC objects (`Role`, `RoleBinding`)
  - `ResourceQuota`, `LimitRange` (tenant guardrails are platform-owned)
  - secret-projection objects (`ExternalSecret`, `SecretStore`, `ClusterSecretStore`) until we have a tenant-safe Vault/ESO scoping model (see `docs/design/multitenancy-secrets-and-vault.md` and `docs/design/multitenancy-storage.md`)
- **Deny `Secret` resources** by default (no secrets in Git); secrets are projected by platform-owned ESO objects per `docs/design/multitenancy-secrets-and-vault.md`.
- **Allow** namespaced workload primitives needed for apps:
  - Deployments/StatefulSets/DaemonSets, Jobs/CronJobs, Services, ConfigMaps, ServiceAccounts
  - PersistentVolumeClaims (storage contract applies; see `docs/design/multitenancy-storage.md`)
  - HorizontalPodAutoscaler, PodDisruptionBudget
  - NetworkPolicy (exceptions are PR-authored per `docs/design/multitenancy-networking.md`)
  - Gateway API `HTTPRoute` (but only within constrained attachment/hostname policy; see `docs/design/multitenancy-networking.md`)

This is deliberately conservative. The canonical list belongs in the tracker once we implement it as YAML.

Important: AppProject boundaries protect the **GitOps path**. If tenants have kubectl rights in their namespaces, the same prohibitions must also be enforced via admission/policy (Kyverno validate policies and/or VAP) to prevent kubectl bypass.

### 5.5 Argo RBAC mapping (no global RBAC growth)

Use Keycloak groups (patterns from `docs/design/multitenancy.md`) and bind them inside each AppProject:

- `dk-tenant-<orgId>-admins` → project admin for `tenant-<orgId>`
- `dk-tenant-<orgId>-project-<projectId>-admins` → project admin for `tenant-<orgId>-p-<projectId>`
- `developers`/`viewers` map to narrower roles (sync vs read-only)

Principle: adding org/project access should be “add AppProject with roles”, not “patch global RBAC CSV”.

---

## 6) Application model (how tenant desired state is applied)

### 6.1 Root ownership: platform reconciles tenant registry

Platform GitOps (root app `platform-apps`) owns and applies:
- tenant `AppProject` objects
- tenant root `Application` objects (one per project)

Tenants do not create Argo primitives directly in v1; they only change their workload manifests in Git.

### 6.2 One `Application` per tenant project (recommended default)

Each tenant project gets one Argo `Application`:
- `metadata.name`: `tenant-<orgId>-<projectId>`
- `spec.project`: `tenant-<orgId>` (or the project-scoped AppProject)
- `spec.source.repoURL`: the tenant project repo
- `spec.source.path`: the project’s rendered manifests (typically a Kustomize overlay per deployment/environment)
- `spec.destination.namespace`: the project’s primary app namespace for that cluster (e.g., `t-<orgId>-p-<projectId>-prod-app`)
- `spec.syncPolicy.syncOptions`: keep `CreateNamespace=false` (tenant namespaces are platform-provisioned with required labels/policies)

Rationale:
- Minimizes Argo object count.
- Keeps the tenant surface understandable (“your project == one sync unit”).
- Still allows multiple namespaces by using multiple Applications only when needed.

### 6.3 Split into more Applications only when needed

Use multiple Applications per project when:
- you need explicit ordering (databases → apps → ingress),
- you want different sync policies (prune off for one, automated on for another),
- you need clearer blast radius for partial failures.

At scale, prefer `ApplicationSet` generation rather than hand-authoring hundreds of Applications.

---

## 7) Tenant PR flow and validation gates

### 7.1 Governance split (two PR classes)

1. **Platform PRs (access-plane / registry)**
   - Examples: create org/project namespaces, create/update AppProjects, change Argo OIDC/RBAC, change admission guardrails, change default-deny networking baseline.
   - Must follow the “RBAC-critical paths” rule and evidence loop (`docs/design/cluster-access-contract.md`).

2. **Tenant PRs (workload-plane)**
   - Examples: Deployments/Services, HTTPRoutes, NetworkPolicies (exceptions), per-app config.
   - Reviewed/approved by the tenant’s own org/project admins (four-eyes within the tenant).

### 7.2 Validation gates (pre-merge, required)

Tenant PRs must be validated before merge. Minimum gates:

- **Renderability**: `kustomize build` (or Helm template) must succeed for every supported overlay.
- **Schema sanity**: server-side apply compatible; basic schema validation for common kinds (cluster CRDs may require relaxed validation).
- **Prohibited kinds check**: fail if the change introduces disallowed kinds (cluster-scoped, RBAC, admission, secret-projection until productized).
- **Namespace safety**: resources must target only namespaces belonging to the org/project naming/label contract.
- **No secrets in Git**: secret scanning required (gitleaks-like) for any tenant repo that can affect a cluster.
- **Policy compatibility**: known constraints must be checked early (e.g., tenant NetworkPolicy must not use `ipBlock` per networking design).

These gates are “static”. They do not prove runtime correctness, but they prevent the most common footguns from reaching Argo.

### 7.3 Validation gates (post-merge, optional but recommended)

Runtime gates follow `docs/design/validation-jobs-doctrine.md`:

- **Sync-gate hook Jobs** (Argo PostSync) only when a capability must not proceed unless validated.
- **Smoke-test CronJobs** for ongoing assurance in prod.

Recommendation:
- Tier S0/S1: require at least one project-local smoke check (CronJob) for externally reachable services.
- Tier S2: require per-project “delivery health” checks (routing + DNS + TLS) with alerting on staleness.

### 7.4 Evidence loop

Platform PRs require evidence under `docs/evidence/**` (repo contract).
Tenant PR evidence lives in the tenant’s own workflow (product mode) and may be summarized into platform evidence during onboarding/offboarding or support events (see `docs/design/multitenancy-lifecycle-and-data-deletion.md`).

---

## 8) Scale budgets and tier thresholds

These budgets are explicit “starting targets” and must be validated with measurement before productizing hostile shared tenants.

### 8.1 What we measure (SLOs)

Minimum SLOs to track:
- PR merged → Argo observes new commit: **< 60s**
- Argo sync started → resources applied: **< 2m** for small changes
- App `Synced/Healthy` (steady workloads): **< 10m** after merge (depends on images, rollouts, and quotas)

### 8.2 Tiered scale model (shared-cluster)

Define tiers within Tier S (shared-cluster):

**Tier S0 (Seed / friendly tenants)**  
Recommended ceiling:
- up to **5 orgs**
- up to **25 projects total**
- up to **250 Argo Applications total** (platform + tenants)

Architecture:
- org-scoped AppProject per org
- one Application per project
- minimal smoke tests; manual support acceptable

**Tier S1 (Standard / product candidate)**  
Recommended ceiling:
- up to **25 orgs**
- up to **150 projects total**
- up to **1,500 Argo Applications total**

Architecture:
- org-scoped AppProject per org (project-scoped only when justified)
- default: one Application per project; allow more only with documented need
- required tenant PR validation gates (renderability, prohibited kinds, secret scanning)
- required per-tenant budgets for ingress/networkpolicy (see networking design budgets)

**Tier S2 (Scale / requires sharding decisions)**  
Trigger when any S1 ceiling is exceeded, or when SLOs cannot be met with reasonable Argo sizing.

Required next step (decision for S2):
- **Primary:** shard Argo CD (multiple Argo instances or application-controller sharding) and define an allocation strategy.
- **Secondary (isolation/contract trigger):** move large or high-paranoia tenants to **Tier D (dedicated clusters)**.
- **Long-term direction:** a “platform control cluster + workload clusters” topology aligns with Phase 2 (`docs/design/cloud-productization-roadmap.md`), but is not required to unblock S2 sharding.

### 8.3 “Switch thresholds” (explicit triggers)

Switch tiers (S0→S1→S2, or S→D) when:
- Application/controller reconciliation latency violates SLOs consistently,
- Argo’s resource footprint becomes a material noisy-neighbor risk,
- org/project growth implies a large number of per-tenant Argo objects (AppProjects/Applications),
- tenant churn rate (merges/hour) causes sustained sync backlog,
- or tenant isolation requirements exceed what shared-cluster posture can honestly provide.

---

## 9) Summary of decisions (this doc)

- Use Argo `AppProject` as the primary tenant boundary (repos, destinations, kind allowlist).
- Prefer repo-per-project (Forgejo org per tenant) so boundaries are repo-shaped, not path-shaped.
- Keep tenant creation of Argo primitives out of v1; platform owns `AppProject`/`Application` objects.
- Avoid per-tenant edits to global Argo RBAC config; bind tenant groups via `AppProject` roles.
- Start with a strict tenant resource allowlist and expand with evidence and explicit productization.
- Record explicit tier ceilings (apps/projects/orgs) and treat exceeding them as a required architecture decision.
