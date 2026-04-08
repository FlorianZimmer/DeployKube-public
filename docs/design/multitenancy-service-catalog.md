# DeployKube Multitenancy Service Catalog (Tenant-Facing Primitives)

<a id="dk-mtsc-top"></a>

Last updated: 2026-01-16  
Status: **Design + implementation (tenant service catalog is partly planned; tenant-facing S3 primitive shipped)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy-service-catalog.md`
- Related docs / constraints:
  - Tenancy model + label invariants: `docs/design/multitenancy.md`
  - Tenancy networking (VPC + firewall): `docs/design/multitenancy-networking.md`
  - Tenancy storage (PVC + S3 + backups): `docs/design/multitenancy-storage.md`
  - Backup/DR contract: `docs/design/disaster-recovery-and-backups.md`
  - Access contract (GitOps-only access changes): `docs/design/cluster-access-contract.md`
  - Policy engine + tenant baseline constraints: `docs/design/policy-engine-and-baseline-constraints.md`
  - Marketplace responsibility split (idea): `docs/ideas/2025-12-26-marketplace-managed-services.md`
  - Stack truth (implemented components/versions): `target-stack.md`

---

## 1) Purpose and scope

This document defines:

1. Which **tenant-facing primitives** DeployKube exposes (S3, Postgres, PVC storage, ingress/DNS, etc.).
2. What **“tenant-facing”** means vs what **“managed”** means (these are different axes).
3. For each primitive: the isolation model and the **responsibility split** for:
   - isolation/security,
   - backups/restore,
   - SLOs/monitoring.

Scope / ground truth:
- Repo-grounded: contracts and GitOps manifests under `platform/gitops/**` plus the linked design docs.
- This doc does **not** claim live cluster state.
- Component READMEs under `platform/gitops/components/**/**/README.md` remain authoritative for implementation details.

MVP scope reminder:
- Queue #11 implements **Tier S (shared-cluster)** multitenancy first, including the initial set of tenant-facing primitives that are Tier S-ready.
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for the MVP.
- Design constraint: the ordering surface (Git intent + templates) must remain compatible with later offering some primitives **only** in dedicated tiers without changing the tenant-facing API shape.

---

<a id="dk-mtsc-definitions"></a>

## 2) Definitions (do not conflate)

### 2.1 “Tenant-facing” (exposure axis)
A primitive is **tenant-facing** if tenant workloads/humans receive a stable contract surface, typically:
- an endpoint/hostname,
- credentials delivered via Vault/ESO into their namespace,
- a documented interface (env vars, connection strings, headers),
- and an explicit policy/guardrail story.

A primitive is **platform-internal** if it is used to run the platform (observability, GitOps, identity, etc.) and tenants do **not** receive its credentials or administrative surface.

Key boundary (from `docs/design/multitenancy-storage.md`):
- **Tenant-facing S3 is the only case where tenant workloads receive S3 credentials.**
- Platform-managed services remain “managed”: tenants talk to APIs; they do not receive platform S3 keys/buckets.

### 2.2 “Managed” (responsibility axis)
“Managed” means the provider/platform team owns day‑2 for the service instance:
- provisioning and lifecycle,
- upgrades/patching,
- monitoring/alerting,
- backups + routine restore testing,
- incident response.

This matches the “Fully Managed Services” direction in `docs/ideas/2025-12-26-marketplace-managed-services.md`.

### 2.3 “Tenant-operated / curated deployment”
The platform may ship a hardened deployment package, but the tenant owns day‑2.

This is not the default posture for DeployKube’s multitenancy story; it is an explicit “marketplace offering” class with different guarantees.

### 2.4 Tenancy tiers (isolation strength)
This doc inherits the tenancy offerings and threat model from `docs/design/multitenancy.md`:
- **Tier S (Shared / Standard)**: shared cluster, logical isolation (RBAC/policy/network/observability). Not side‑channel resistant.
- **Tier D (Dedicated)**: cluster-per-org (strong blast radius boundary).
- **Tier H (Dedicated + Hardware separation)**: dedicated clusters plus hardware/pool separation.

### 2.5 Backup tiers (data criticality)
We reuse `docs/design/disaster-recovery-and-backups.md` terminology:
- **Tier‑0**: requires application-consistent backup/restore (e.g., Postgres).
- **Ordinary**: PVC/file-level backups are acceptable (crash-consistent by default).

### 2.6 Product readiness levels (enforceable, not narrative)
A primitive may “exist in repo” but still be unsafe to offer to hostile tenants in Tier S.

We use these readiness labels:

- **Tenant-facing**: stable interface + **enforceable guardrails** (RBAC/admission/policy/network) + a smoke test that proves the intended boundary.
- **Managed**: tenant-facing + platform-owned day‑2 (lifecycle, patching, monitoring, incident response) + backups/restore drills + explicit budgets/switch thresholds.
- **Tier S-ready**: safe to offer to hostile tenants in a shared cluster (see `docs/design/multitenancy.md` threat model) with guardrails + smoke + evidence. If not Tier S-ready, it may still be offered only in Tier D/H (dedicated) or as a curated tenant-operated package.

---

<a id="dk-mtsc-catalog"></a>

## 3) Catalog summary (repo-grounded truth table)

This section answers “what exists” vs “what is tenant-facing”.

### 3.1 Primitives that exist in-repo today (building blocks)

| Primitive | Exists in repo | Tenant-facing today | Notes / pointers |
|---|---:|---:|---|
| Tenant namespace baseline (labels, netpol default-deny, quotas, PSS/LimitRange) | Yes | Yes (foundation) | `docs/design/multitenancy.md`, `docs/design/policy-engine-and-baseline-constraints.md` |
| Ingress + DNS + TLS (Gateway API + Istio + ExternalDNS + cert-manager; Step CA current internal/private path, Vault PKI implemented for high-assurance external endpoints) | Yes | Partial (guardrails planned) | `docs/design/multitenancy-networking.md`, `docs/design/vault-pki-high-assurance-external-certificates.md`, `target-stack.md` |
| PVC storage (`shared-rwo`) | Yes | Yes | `platform/gitops/components/storage/shared-rwo-storageclass/README.md`, `docs/design/multitenancy-storage.md` |
| S3 endpoint (Garage) | Yes | No (platform-internal by default; tenant-facing is explicit allowlist) | `platform/gitops/components/storage/garage/README.md`, `docs/design/multitenancy-storage.md` |
| Postgres operator (CloudNativePG) + platform Postgres API (`data.darksite.cloud`) | Yes | No (platform workloads today) | `platform/gitops/components/data/postgres/**/README.md`, `platform/gitops/components/platform/apis/data/data.darksite.cloud/**`, `docs/design/data-services-patterns.md` |
| Valkey (Redis-compatible) | Yes | No (platform workloads today) | `platform/gitops/components/data/valkey/base/README.md` |
| Backup plane (`backup-system`) | Yes | No (platform footprint baseline) | `docs/design/disaster-recovery-and-backups.md`, `docs/design/multitenancy-storage.md` |
| Observability (LGTM stack) | Yes | Yes (human-facing) | `docs/design/observability-lgtm-design.md`, `target-stack.md` |

### 3.2 Tenant-facing primitives (what the “catalog” is)

Tenant-facing primitives are the subset that tenants can **order/consume** with explicit responsibility boundaries.

| Primitive | Default model | Current status | Tier S-ready | Ordering surface (GitOps intent; planned) |
|---|---|---:|---:|---|
| PVC storage (`shared-rwo`) | Platform primitive (not “managed” per-instance) | **Implemented** | Partial (needs tenant egress/`ipBlock` guardrails) | **Tier S1 (recommended)**: tenant repo `tenant-<orgId>/apps-<projectId>` (PVCs in workload YAML) · **Tier S0 fallback**: `platform/gitops/tenants/<orgId>/projects/<projectId>/...` (monorepo; weaker isolation) |
| Ingress hostname + DNS + TLS (HTTPRoute) | Platform primitive (guardrails enforce ownership) | **Partially implemented; hardening planned** | No (route hijack hardening + mesh posture decision) | **Tier S1 (recommended)**: tenant repo `tenant-<orgId>/apps-<projectId>` (HTTPRoute in workload YAML) · **Tier S0 fallback**: `platform/gitops/tenants/<orgId>/projects/<projectId>/network/` |
| S3 (tenant-facing buckets + per-tenant creds) | **Managed** primitive | **Implemented** (M6; primitive exists, managed posture still evolving) | Partial (budgets/offboarding/rotation runbooks pending) | Platform intent (v1): tenant intent bundle under `platform/gitops/tenants/<orgId>/projects/<projectId>/namespaces/<env>/` (bucket intent ConfigMap in `garage`, tenant egress allow, platform-owned ESO projection) + Garage ingress allowlist (`platform/gitops/components/storage/garage/base/networkpolicy.yaml`) |
| Postgres (DBaaS-style instances) | **Managed** primitive | **Platform API implemented; tenant productization still planned** | No | Platform registry intent: `platform/gitops/tenants/<orgId>/projects/<projectId>/services/postgres/instances/<instanceName>.yaml` |
| Valkey (cache instances) | **Managed** primitive (best-effort) | **Planned** (base exists; backups not implemented) | No | Platform registry intent: `platform/gitops/tenants/<orgId>/projects/<projectId>/services/valkey/instances/<instanceName>.yaml` |

### 3.3 Ordering interface (GitOps surface; v1 direction)
“Order” means PR-authored changes in Git (no imperative UI writes), but there are **two** reconcile surfaces:
- **Workload-plane** (tenant delivery): tenant repos (`tenant-<orgId>/apps-<projectId>`) reconciled by tenant Argo Applications (`docs/design/multitenancy-gitops-and-argo.md`).
- **Registry/access-plane** (tenant onboarding + managed services intent): this repo under `platform/gitops/tenants/<orgId>/...` and `platform/gitops/apps/tenants/...` (reconciled by `platform-apps`).

Folder contract: `docs/design/multitenancy.md#dk-mt-folder-contract`.

Guardrail reminder:
- Tenants must not have RBAC to create/update “secrets projection objects” (e.g. `ExternalSecret`). Those are treated as access-plane resources (`docs/design/cluster-access-contract.md`) and are platform-owned.

### 3.4 Promotion gates (how a primitive becomes “tenant-facing/managed/Tier S-ready”)
Before a primitive is promoted for Tier S (hostile tenants):
- **Guardrails**: RBAC/admission/policy/network enforce the boundary (e.g., no route hijack; no backend reachability bypass).
- **Smoke tests**: automated checks prove the boundary (e.g., can only read own bucket; cannot attach to platform gateways).
- **Backups/restore** (managed services): restore drills exist and are scheduled for Tier‑0 services.
- **Budgets**: explicit numbers + switch thresholds exist (see §11 and `docs/design/multitenancy.md#1-1-non-functional-budgets-required-before-phase-2`).
- **Evidence**: results captured under `docs/evidence/` and linked from the relevant component tracker.

---

<a id="dk-mtsc-matrix"></a>

## 4) Responsibilities matrix (per primitive)

This section is the “don’t get sued” part: it prevents “we deployed it” from being mistaken for “we run it”.

Each primitive below lists responsibilities for:
- **Isolation** (security boundaries and how they are enforced),
- **Backups/restore** (who owns RPO/RTO behavior),
- **SLOs** (who measures, who responds).

---

## 5) Primitive: Tenant namespace (Org/Project identity + baseline constraints)

Tenant interface:
- A namespace created by platform GitOps with the required labels (see `docs/design/multitenancy.md`):
  - `darksite.cloud/rbac-profile=tenant`
  - `darksite.cloud/tenant-id=<orgId>`
  - `observability.grafana.com/tenant=<orgId>`
  - `darksite.cloud/project-id=<projectId>`

### Isolation responsibilities

Platform:
- Enforce the tenant label + identity contracts via VAP (A1/A2): require `project-id`, validate identifier formats, and deny identity label mutation (`tenant-id`/`project-id`/`vpc-id`). (`docs/design/policy-engine-and-baseline-constraints.md`, `docs/design/multitenancy.md`)
- Enforce deny-by-default networking baseline (generated NetworkPolicies) and PodSecurity “restricted” posture for tenant namespaces. (`docs/design/policy-engine-and-baseline-constraints.md`)
- Ensure tenants cannot bypass isolation by mutating access-plane objects (RBAC/admission/CRDs) outside GitOps. (`docs/design/cluster-access-contract.md`)

Tenant:
- Treat namespace identity labels as immutable identity (org/project/VPC); re-homing is “new namespace + migrate”, not relabeling.
- Do not request “breakglass-like” exceptions (privileged pods, host access) unless the tenancy tier explicitly permits it and evidence is captured.

### Backup responsibilities

Platform:
- Provide the backup plane and the “GitOps-safe restore mode” workflow (restore without init races). (`docs/design/disaster-recovery-and-backups.md`)

Tenant:
- Decide which workloads/PVCs are in-scope for backup by using the backup label contracts and following the backup doctrine. (`docs/design/disaster-recovery-and-backups.md`)
- Provide application-level restore validation hooks where feasible (minimum: non-trivial integrity checks).

### SLO responsibilities

Platform:
- Owns availability of the *control-plane* contracts for tenants (admission/policy stack health, RBAC sync health, baseline netpol generation).

Tenant:
- Owns availability of their workloads in the namespace (replicas, PDBs, readiness, app-level SLOs) unless a workload is explicitly a managed service.

---

## 6) Primitive: Ingress hostname + DNS + TLS (HTTPRoute)

Tenant interface:
- A hostname (DNS) and an ingress route (Gateway API `HTTPRoute`) that exposes a tenant service.
- TLS is currently issued via cert-manager + Step CA for internal/private endpoints. External client-facing endpoints that require active revocation are planned to use a separate Vault PKI-backed issuer path.

### Isolation responsibilities

Platform:
- Enforce default-deny tenant networking and require explicit ingress allows to tenant backends. (`docs/design/multitenancy-networking.md`)
- Prevent route hijack (decision; implementation planned):
  - separate platform vs tenant gateways (no tenant attachments to `public-gateway`, ever),
  - default Tier S model: per-org tenant Gateway (or per-org listener set) with `allowedRoutes.namespaces.from: Selector` keyed by `darksite.cloud/tenant-id=<orgId>`,
  - enforce hostname ownership (org-scoped zone pattern) and forbid cross-namespace backendRefs/ReferenceGrants unless explicitly approved. (`docs/design/multitenancy-networking.md`)
- Ensure ingress gateway → tenant Service backends works without per-service `DestinationRule tls.mode: DISABLE` sprawl (see mesh posture decision in `docs/design/multitenancy-networking.md#dk-mtn-tenant-workloads-vs-mesh`).

Tenant:
- Own the correctness of their backend (health endpoints, safe timeouts/retries, rate limiting at the app boundary if required).
- Follow the mesh boundary rules (in-mesh vs out-of-mesh backends) and document exceptions when needed.

### Backup responsibilities

Platform:
- N/A (purely declarative config; restore comes from Git).

Tenant:
- N/A (for routing objects themselves). Back up the application state behind the route as appropriate.

### SLO responsibilities

Platform:
- Own the ingress control-plane SLOs (route programmed, cert issued, DNS propagated), and publish budgets/switch thresholds. (`docs/design/multitenancy-networking.md`)

Tenant:
- Own the “backend serves traffic” SLO for their app (the platform can route to a broken service; that is not an ingress outage).

---

## 7) Primitive: PVC storage (`shared-rwo`)

Tenant interface:
- Create PVCs using the stable StorageClass contract:
  - `shared-rwo` (default; `ReadWriteOnce`)
- Tenant namespaces are quota-bound (today’s baseline includes `requests.storage: 10Gi`). (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`)

### Isolation responsibilities

Platform:
- Provide the `shared-rwo` StorageClass as a stable contract across profiles/backends. (`docs/design/storage-single-node.md`, `platform/gitops/components/storage/shared-rwo-storageclass/README.md`)
- Ensure tenant namespaces cannot bypass Kubernetes scoping by directly reaching backend endpoints (NFS server, backup target, future Ceph admin/control plane). (`docs/design/multitenancy-storage.md`)
  - This implies strict tenant egress posture and disallowing ad-hoc `ipBlock` egress in tenant `NetworkPolicy` (planned).
- Provide quota profiles (planned) so storage growth is explicit and reviewable, not “edit global Kyverno template per tenant”. (`docs/design/multitenancy-storage.md`)

Tenant:
- Assume Tier S is not a “hard isolation storage boundary”. For hard isolation claims, use Tier D/H (dedicated clusters/hardware). (`docs/design/multitenancy.md`)
- Avoid relying on RWX semantics unless explicitly shipped; treat `shared-rwx` as “not available by default”.

### Backup responsibilities

Platform:
- Provide the backup plane primitives (restic jobs, encryption, retention, restore workflow). (`docs/design/disaster-recovery-and-backups.md`)
- For tenant productization: make the backup plane tenant-aware with per-tenant repositories and markers (planned). (`docs/design/multitenancy-storage.md`)

Tenant:
- Label and document PVC backup intent (`darksite.cloud/backup=restic|native|skip`) and provide restore validation hooks. (`docs/design/disaster-recovery-and-backups.md`)
- Own RPO/RTO at the application level unless a managed service explicitly covers it.

### SLO responsibilities

Platform:
- Provide measurable storage health signals (provisioning success, error rates, backup freshness) and define switch thresholds for “too big ⇒ dedicated/Ceph”. (`docs/design/multitenancy-storage.md`)

Tenant:
- Own workload-level durability (write patterns, fsync behavior, corruption handling) and capacity planning within quota.

---

## 8) Primitive: Object storage (S3) — tenant-facing buckets

Tenant interface (planned):
- S3-compatible credentials and bucket name delivered into the tenant namespace as a Kubernetes Secret (sourced from Vault via ESO).
- Stable env var contract: `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, plus bucket env vars. (See storage contract direction in `docs/design/storage-single-node.md` and `docs/design/multitenancy-storage.md`.)

### Isolation responsibilities

Platform:
- Separate **platform-internal S3** from **tenant-facing S3**:
  - tenants never receive platform S3 keys/buckets,
  - tenant-facing S3 uses per-tenant buckets + per-tenant credentials. (`docs/design/multitenancy-storage.md`)
- Enforce bucket scoping (recommended): **per-tenant buckets**, not shared bucket + prefix. (`docs/design/multitenancy-storage.md`)
- Enforce network exposure:
  - restrict Garage/RGW ingress to only explicitly allowed platform/tenant namespaces,
  - restrict tenant egress to only the S3 endpoint/port when S3 is granted (and keep other egress denied). (`docs/design/multitenancy-storage.md`)
- Enforce “secrets custody”:
  - tenant namespaces must not have RBAC to create/update `ExternalSecret` (or similar secret projection objects). (`docs/design/multitenancy-storage.md`, `docs/design/cluster-access-contract.md`)

Tenant:
- Treat S3 credentials as data-plane secrets; rotation and compromise response must be supported (apps must tolerate key rotation).
- Own application-level data correctness (object versioning semantics, idempotency, lifecycle expectations).

### Backup responsibilities

Platform:
- For managed tenant S3: include tenant buckets in the backup plane with explicit allow-lists (no “sync all buckets”), and per-tenant encryption boundaries. (`docs/design/multitenancy-storage.md`, `docs/design/disaster-recovery-and-backups.md`)
- Provide restore drills that prove “tenant can read back their bucket and cannot list platform buckets/other tenant buckets” (planned evidence gate). (`docs/design/multitenancy-storage.md`)

Tenant:
- Own restore verification at the application level (e.g., can the app rebuild state from objects) unless the service contract explicitly provides it.

### SLO responsibilities

Platform:
- Own the S3 availability/latency/error-rate SLO for managed tenant S3, and publish quotas/budgets + switch thresholds:
  - v1 (Garage) quotas may be soft; enforce via metering + key disable/escalation,
  - Phase 2/3 (RGW) quotas should be hard via native RGW quotas. (`docs/design/multitenancy-storage.md`)

Tenant:
- Own workload retry/backoff behavior and avoid turning transient S3 errors into cluster-wide load storms.

---

## 9) Primitive: Postgres — tenant-facing database instances (DBaaS)

Detailed platform-API direction:
- `docs/design/platform-postgres-api.md`

Tenant interface (planned):
- A Postgres endpoint (`host:port`), database name, and credentials delivered via Vault/ESO into the tenant namespace.
- A clear “plan” concept (sizing + HA posture) that is selectable by Git request, not by ad-hoc patching.

Current repo baseline:
- `data.darksite.cloud/v1alpha1` now exists in-repo with `PostgresClass` plus `PostgresInstance`.
- Keycloak, Forgejo, PowerDNS, and Harbor are internal consumers of that surface.
- Platform-only disposable PoCs can also use that surface through a class such as `platform-poc-disposable`; IDLab is the first example.
- Tenant namespaces are still intentionally blocked from raw `postgresql.cnpg.io/*` access; tenant-facing `PostgresInstance` exposure remains a later allowlist/policy step, not an open default.

### Isolation responsibilities

Platform:
- Keep the tenant DB surface product-closed:
  - tenants do not mutate CRDs/operators; they request instances via Git and consume the resulting endpoints/credentials.
- Prefer an isolation model that makes accidental cross-tenant reads hard:
  - v1 default: **per-project CNPG cluster per instance** (namespaced) rather than a shared Postgres cluster with “db-per-tenant” (noisy neighbor and operator blast radius).
  - recommend running the instance in the owning tenant project namespace and restricting tenant RBAC for `postgresql.cnpg.io/*` resources (platform-owned).
- Enforce network reachability:
  - default-deny tenant egress means DB access should be same-namespace where possible,
  - otherwise explicit allow NetworkPolicies keyed by `darksite.cloud/tenant-id` / `project-id`.
- Maintain the mesh boundary explicitly (CNPG control-plane vs data-plane mTLS gotchas). (`docs/design/data-services-patterns.md`)

Tenant:
- Own application-level query safety and performance (indexes, connection pools, transaction scopes).
- Treat DB credentials as sensitive and rotate-ready.

### Backup responsibilities

Platform:
- If Postgres is offered as **managed**:
  - treat it as **Tier‑0** (application-consistent backups required),
  - ship a backup mechanism that lands artifacts in the backup target (not just an in-cluster PVC),
  - run restore drills on schedule. (`docs/design/disaster-recovery-and-backups.md`)
- Evolve from v1 logical dumps → CNPG-native backups/WAL to object storage once the object store profile supports it. (`docs/design/disaster-recovery-and-backups.md`)

Tenant:
- Own higher-level restore validation (does the app start and pass integrity checks against restored DB) unless the managed service contract explicitly includes it.

### SLO responsibilities

Platform:
- Own Postgres availability/durability SLO for managed instances, bounded by tenancy tier:
  - Tier S is logical isolation only (no hard side-channel claims; shared storage limits apply),
  - Tier D/H can carry stronger durability/availability claims if the storage profile supports it.
- Publish scale budgets before productizing (max DB instances per cluster, max storage per tenant, backup IO budgets). (Align with `docs/design/multitenancy.md` “budgets” doctrine.)

Tenant:
- Own app-level HA design (can the app tolerate brief failovers) and avoid “noisy neighbor” behavior (unbounded connections/queries).

---

## 10) Primitive: Valkey (Redis-compatible) — tenant-facing cache instances

Tenant interface (planned):
- A Valkey endpoint (and if Sentinel-aware: sentinel endpoints) plus a password delivered via Vault/ESO.

### Isolation responsibilities

Platform:
- Enforce namespace/network isolation for cache access (do not ship a “shared open Redis”).
- Make the tenancy tier explicit: cache instances are typically Tier S‑safe, but not a hard isolation boundary.

Tenant:
- Treat the cache as a shared dependency and implement safe timeouts/retries; avoid turning cache outages into thundering herds.

### Backup responsibilities

Platform:
- Default: **no backups/SLO around durability** for tenant Valkey (cache semantics). The base library currently has no backup mechanism. (`docs/component-issues/valkey.md`)
- If a tenant requests “durable Redis”, that is a *different service* with different backup/SLO requirements and should not be implied by “Valkey available”.

Tenant:
- Own persistence strategy (treat cache as ephemeral; persist source-of-truth elsewhere).

### SLO responsibilities

Platform:
- Own cache availability SLO only if explicitly sold as a managed cache; otherwise publish it as best-effort.

Tenant:
- Own application behavior under cache degradation (graceful fallback, rate limiting).

---

<a id="dk-mtsc-budgets"></a>

## 11) Budgets + switch thresholds (required before productizing tenant services)

This doc inherits the “budget before hostile tenants” rule from `docs/design/multitenancy.md` and extends it to data services.

Before enabling tenant-facing managed primitives broadly (Tier S for real tenants), record concrete budgets at minimum:
- **S3**: max buckets per tenant, max total buckets, max object-store GiB per tenant, max request rate per tenant, and a “too big ⇒ dedicated/Ceph” threshold.
- **Postgres**: max managed instances per tenant and per cluster, max PVC GiB per instance, max backup IO, max concurrent connections per instance/tenant.
- **Backups**: max backed-up PVCs per tenant, max restic repos per tenant, max per-hour backup IO to the backup target.

If budgets are exceeded, the design must define a switch path:
- move tenants to Tier D (org-per-cluster), and/or
- move storage profile to Ceph-backed `shared-rwo` + RGW (Phase 2/3 direction in `docs/design/multitenancy-storage.md`).
