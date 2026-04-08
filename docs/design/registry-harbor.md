# Design: In-Cluster OCI Registry (Harbor) for Platform + Tenants

Last updated: 2026-02-01  
Status: Implemented (Phase 0 wiring)

This design introduces a first-class in-cluster registry to enable:
- true air-gapped operation (no public registry dependency at runtime),
- a tenant-friendly “build → push → deploy” workflow,
- and a clean substrate for curated artifact ingress (ARC) with scanning + policy gates.

## Tracking

- Canonical tracker: `docs/component-issues/registry-harbor.md`

Related:
- Distribution bundles (offline artefact shipping): `docs/design/distribution-bundles.md`
- Curated ingress idea (scan + approval gate): `docs/ideas/2026-01-07-curated-package-ingress-to-harbor.md`
- Cloud roadmap constraints (multi-tenancy compatibility): `docs/design/cloud-productization-roadmap.md`

## Scope / ground truth

Repo-only scope (no live cluster assumptions):
- GitOps payload: `platform/gitops/**`
- Bootstrap tooling: `shared/scripts/**`, `bootstrap/**`, `scripts/**`
- Constraints + patterns: `docs/design/**`, `docs/component-issues/**`, `target-stack.md`

## Problem statement

DeployKube currently depends on public registries for:
- platform component images (either directly or via local cache helpers in dev), and
- tenant workloads (by default, nothing prevents `docker.io/...` pulls).

This blocks:
- “bootstrap + operate without internet” (regulated/air-gapped installs),
- a credible supply-chain posture (explicit ingress + scanning + approvals),
- and future multi-tenant productization (we need mechanical enforcement, not convention).

## Goals

1) **Durable in-cluster OCI registry** usable by platform components and tenants.
2) **Tenant-safe isolation model** (projects, quotas, credentials, and a path to enforcement).
3) **GitOps-first installation and configuration** (no ad-hoc registry drift).
4) **Compatible with the curated ingress direction** (ARC/import pipeline) without locking in implementation details prematurely.
5) **Roadmap compatibility**:
   - works for “single-tenant today” and “multi-customer hosted later”,
   - does not assume “one cluster forever” (must be portable to per-tenant clusters).

## Non-goals (for this design)

- Solving the full “offline bootstrap + distribution bundle” story (covered separately).
- Shipping a full artifact signing/attestation regime in Phase 0 (we design for it, but do not require it).
- Replacing GitOps as the steady-state controller (Harbor is a managed service, not a new control plane).

## Proposed architecture (Phase 0)

### Component choice: Harbor

DeployKube standardizes on **Harbor** as the in-cluster OCI registry because it provides:
- a Docker registry API (OCI images),
- artifact metadata and a UI suitable for operator/tenant workflows,
- built-in vulnerability scanning integrations (scanner adapters),
- and a known path toward policy and replication features.

Harbor is a *platform component* installed via GitOps (not Stage 0/Stage 1).

## Bootstrap and cutover sequence

Offline bootstrap has a chicken-and-egg problem: Harbor is installed via GitOps, but GitOps itself needs charts/images that must be served from somewhere first.

Phase 0 must make the bootstrap/cutover sequence explicit:

1) **Before Harbor exists** (Stage 0/1):
   - An offline bundle provides all required images and manifests.
   - A bootstrap artifact source (“bootstrap registry”) serves those images to nodes.

2) **Install Harbor offline** (first reconcile):
   - Harbor is installed from offline-safe sources. The repo baseline renders the pinned Harbor Helm chart via Kustomize `helmCharts:`; offline bundles must vendor the chart + images so no internet fetch is required at reconcile time (see `docs/design/offline-bootstrap-and-oci-distribution.md`).
   - Harbor’s own images must already be available via the bootstrap registry/bundle (no public pulls).

3) **Load baseline images into Harbor**:
   - Before enforcement is enabled, import the platform-required and curated tenant baseline images into Harbor under deterministic names.

4) **Cut over to Harbor as steady-state**:
   - After Harbor is healthy, the platform switches from “bootstrap transport” to “Harbor is the durable store.”
   - Admission enforcement then moves from **audit/warn** → **deny** for tenant namespaces.

Phase 0 decision (must be explicit):
- Whether GitOps references internal images by explicit Harbor names from day 1 (recommended), or whether runtime mirrors are used as a long-lived mechanism.

### Exposure + TLS

- External access: via the existing ingress substrate (Gateway API / Istio), with hostnames driven by the deployment config contract (no hard-coded domains).
- Hostname split (recommended, to avoid ambiguity):
  - `harbor.<baseDomain>`: Harbor UI (OIDC).
  - `registry.<baseDomain>`: OCI registry endpoint used by Kubernetes nodes and tenants.
- TLS: via cert-manager with the platform-managed issuer. Current internal/private implementation uses Step CA. If Harbor or the registry endpoint is classified as an external high-assurance client-facing surface, it should move to the Vault PKI-backed issuer path.
- Node trust: Kubernetes nodes must trust the issuing CA for image pulls. Today that means the Step CA root bundle. If Harbor later moves onto the high-assurance external issuer path, node trust distribution must be updated to the corresponding Vault PKI chain. The implementation detail is platform-specific, but the contract is “nodes can verify Harbor TLS”.

### AuthN/AuthZ

- Humans: OIDC via Keycloak for UI access.
- Automation: Harbor robot accounts for push/pull, with credentials stored in Vault and delivered via External Secrets Operator.

Direction (multi-tenancy-safe):
- registry RBAC is group/project based (no per-user hand-crafted grants),
- and tenant registry credentials are provisioned/rotated by automation, not manually copy/pasted.

### Storage + HA posture (explicitly staged)

Phase 0 posture should be chosen explicitly and documented in the tracker:
- **Single-instance** Harbor is acceptable for dev and early prod pilots *if* backup/restore is in place and downtime is acceptable.
- HA (multiple replicas, external DB, object storage backend) is a follow-up once storage/DB patterns are stable.

Avoid painting ourselves into a corner:
- Keep registry storage backend selectable (PVC now, S3/Garage later).
- Prefer externalized DB patterns (CNPG) once feasible, to align with `docs/design/data-services-patterns.md` and backup doctrine.

## Project layout and naming

Harbor “projects” become the isolation boundary.

Recommended minimum projects:
- `platform`: platform-owned images used by GitOps components (including DeployKube-built images).
- `packages`: curated/imported artefacts (the “approved ingress” namespace).
- `charts` (optional): if we adopt OCI charts as the primary offline chart distribution mechanism.

Tenants:
- One project per tenant, derived mechanically from tenant identity (e.g. `t-<tenantId>`).
- Enforce quotas and retention per tenant project to prevent noisy-neighbor storage exhaustion.

### Deterministic naming for mirrored images

Offline installs and multi-registry mirroring require a deterministic naming scheme inside the internal registry.

Recommended naming scheme (example shape):
- `registry.<baseDomain>/mirror/docker.io/<repoPath>`
- `registry.<baseDomain>/mirror/quay.io/<repoPath>`
- `registry.<baseDomain>/mirror/registry.example.internal/<repoPath>`
- `registry.<baseDomain>/platform/<repoPath>` (DeployKube/platform-built images)
- `registry.<baseDomain>/packages/<repoPath>` (curated ingress/promoted artifacts)

This avoids collisions across upstream registries and makes policy enforcement and auditability straightforward.

### Image reference posture (digest vs tags)

Phase 0 recommendation for deterministic offline installs:
- Platform images referenced by GitOps should be pinned by digest (`@sha256:<digest>`), with digests recorded in the bundle BOM and (when practical) in manifests.
- Tags are allowed only if there is a verification step that maps the tag to a specific digest (and stores that mapping in the BOM / ingress report).

## Tenant contract (how tenants use the registry)

### Baseline workflow

Tenants can:
- push images to their Harbor project (CI inside/outside cluster),
- reference those images in their GitOps-managed workload manifests,
- and pull images in-cluster using `imagePullSecrets` provisioned by the platform.

### Predefined (“curated”) baseline images

To support offline installs and reduce tenant toil, DeployKube should ship a predefined baseline set of images into the internal registry:
- **Platform baseline**: all images required to reconcile `platform/gitops/**` for the shipped git revision (controllers, jobs, etc.).
- **Tenant baseline (optional, but strongly recommended)**: a small set of “golden” base images and build/runtime tooling images that are safe defaults for regulated environments.

Contract:
- the baseline set is declared by digest in the bundle BOM and is loaded into Harbor projects under deterministic names.
- tenant workloads are encouraged (and later enforced) to build FROM and run FROM these curated bases, rather than pulling arbitrary upstream bases directly.

#### Contract: Curated artifact index (single source of truth)

The curated baseline set must be declared as code (not prose) in a repo-owned index that can drive both:
- offline bundle build (what must be included), and
- optional connected imports (what is allowed to enter).

Recommended path (Phase 0):
- `platform/gitops/artifacts/package-index.yaml`

Minimum required fields per entry:
- `source` (upstream ref; optional for internal-only images),
- `digest` (resolved digest; required for offline bundle),
- `destination` (internal name under the deterministic scheme),
- `class` (`platform-required` | `tenant-baseline` | `optional`),
- `policy` (optional metadata for scanning thresholds/exceptions).

### Credential delivery (Vault + ESO)

Contract:
- registry robot credentials are stored under a tenant-scoped Vault path,
- ESO syncs them into the tenant namespace as a Docker config secret,
- and the tenant’s workloads reference that secret (or it is attached automatically via a namespace-level default if we later adopt such a pattern).

This aligns with the “secrets default: Vault + ESO” rule and keeps secrets out of Git.

#### Contract: Vault paths for registry creds

Registry credentials must follow the existing tenant Vault subtree contract from `docs/design/multitenancy-secrets-and-vault.md`:
- Org-level shared credentials (rare): `tenants/<orgId>/shared/<name>`
- Project-level shared credentials (recommended for Harbor robot creds): `tenants/<orgId>/projects/<projectId>/shared/<name>`

Recommendation:
- Create one Harbor robot account per tenant project (not per namespace), and store its Docker config JSON under:
  - `tenants/<orgId>/projects/<projectId>/shared/registry-harbor`

Rotation/offboarding semantics must be explicit:
- rotation: replace robot credential in Harbor, update Vault, ESO refreshes in-cluster secret,
- offboarding: delete Harbor project and permanently delete Vault keys under `tenants/<orgId>/...` per the offboarding doctrine.

### Enforcement (admission)

NetworkPolicy cannot prevent node-level image pulls; enforcement must be admission-time.

Design direction:
- For namespaces opted into tenant baseline constraints (`darksite.cloud/rbac-profile=tenant`), enforce “images must come from the internal registry” and (optionally) “must come from the tenant’s own project or approved shared projects”.
- Keep a controlled exception mechanism (breakglass with evidence) to avoid “policy bricks the cluster” incidents.

Implementation posture (Phase 0 recommendation):
- Implement tenant-scoped enforcement via Kyverno under the existing policy engine component (see `docs/design/policy-engine-and-baseline-constraints.md`), and scope it using the tenant namespace label contract.
- Use staged rollout:
  - start with audit/warn,
  - add targeted smokes/negative tests,
  - then switch to enforce/deny for tenant namespaces only.

Policy exceptions must follow the existing exception discipline (PolicyException with expiry + evidence).

## Curated ingress + ARC integration (future-proofing)

The curated ingress concept from `docs/ideas/2026-01-07-curated-package-ingress-to-harbor.md` remains valid with Harbor as the durable store:
- a Git-reviewed “package index” defines *what is allowed to enter*,
- an importer pulls upstream artefacts (when connectivity is available) and pushes them into Harbor,
- scanners/validators gate promotion into “approved” repositories/projects,
- an “ingress report” provides auditability.

ARC (Artifact Conduit) is a candidate building block because it is explicitly scoped for:
- procuring OCI artefacts from diverse upstream sources, and
- performing automated scanning/validation + policy enforcement prior to crossing a security boundary.

Decision boundary:
- Harbor provides storage and UI; ARC (or a simpler importer) provides *ingress orchestration + policy gates*.
- We should avoid coupling tenant workflows to a specific ingress controller until we validate operational fit.

### Contract: Package index and ingress report

To import artefacts when connectivity exists without breaking offline assumptions, ARC-style ingress must have two explicit contracts:

1) **Package index** (allowlist / desired external artifacts):
   - repo-owned file path (Phase 0 recommendation: `platform/gitops/artifacts/package-index.yaml`),
   - reviewed/approved like any other GitOps change.

2) **Ingress report** (audit trail of what entered):
   - records: source ref, resolved digest, destination internal ref, scan summary, and policy decision,
   - stored durably (either as an OCI artifact in Harbor under `packages/` and/or referenced from `docs/evidence/` when exceptions are approved).

## Vulnerability scanning (what we rely on)

Scanning in this architecture has two distinct purposes:

1) **Ingress gate (prevent bad artefacts from entering the environment)**  
   This is best handled in the curated ingress pipeline (ARC or an equivalent importer + scanner + policy gate), because it can:
   - enforce approvals and policy decisions,
   - emit an audit trail (“ingress report”),
   - and keep “internet reads” scoped to a small, controlled surface.

2) **Ongoing visibility (inventory and drift awareness)**  
   Harbor’s scanner integration (or equivalent) is useful for UI-driven visibility and ongoing re-scans, but it should not be the only control surface.

Air-gapped constraint:
- whichever scanner we rely on must also have an offline database update story (treat scanner DB updates as artefacts that are imported/shipped, not as ambient internet pulls).

## Backup/restore (minimum regulated baseline)

Once “pull only from Harbor” is enforced, Harbor becomes tier‑0-ish infrastructure.

Minimum backup/restore contract (Phase 0):
- Back up:
  - Harbor database (users/projects/replication/metadata),
  - registry storage backend (PVC or object storage),
  - critical configuration and secrets required to restore access.
- Restore:
  - documented procedure aligned with `docs/design/disaster-recovery-and-backups.md`,
  - plus a validation job/smoke proving “can login + pull a known digest after restore”.

## Multi-tenancy and roadmap compatibility

This design avoids blocking future goals by:
- treating the registry as a platform-managed service with tenant-scoped isolation (projects + credentials),
- making enforcement label-driven (tenant namespaces opt in via the existing baseline constraints contract),
- and keeping the component portable:
  - “single cluster / many tenants” works,
  - and “one registry per workload cluster” remains possible later without breaking contracts.

Future Phase 2 (“multi-cluster per tenant”) implication:
- The same “tenant project + robot credentials + admission enforcement” pattern can be instantiated per workload cluster.
- If we later add a fleet/management plane, the registry can remain per-cluster to avoid cross-customer coupling.

## Risks / trade-offs

- Harbor operational complexity (DB, cache, upgrades) is non-trivial; we must pair it with backup/restore and validation jobs early.
- Registry storage consumes meaningful capacity; quotas/retention must be shipped as part of the tenant contract, not as an afterthought.
- Admission enforcement must be staged carefully to avoid breaking system namespaces and bootstrap flows.

## Implementation outline (high-level)

1) Add Harbor as a GitOps component (early wave if other components should pull from it).
2) Wire TLS + hostnames from deployment config contract.
3) Define project layout (`platform`, `packages`, per-tenant projects) and automation hooks.
4) Integrate Vault + ESO for robot credential delivery.
5) Add validation jobs (push/pull/smoke) and backup coverage.
6) Add label-driven admission enforcement for tenant namespaces.
7) Add curated ingress (ARC or equivalent) once the registry baseline is stable.
