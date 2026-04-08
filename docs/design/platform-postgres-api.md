# Design: Platform-Owned Postgres API

Last updated: 2026-03-15
Status: Implemented baseline

## Tracking

- Canonical tracker: `docs/component-issues/cnpg-operator.md`

## 1) Problem statement

DeployKube currently installs CloudNativePG (CNPG) directly and platform components consume CNPG's upstream `postgresql.cnpg.io` API surface. That works for current platform-owned workloads, but it is the wrong long-term product contract:

- it exposes a third-party API group as an implementation detail,
- it keeps the platform coupled to CNPG-specific semantics,
- it does not give tenants or internal product surfaces a stable managed-service interface,
- it keeps broad CNPG operator RBAC as the visible control plane instead of containing it behind a platform boundary.

If DeployKube wants to use Postgres internally and later expose it as a managed database service, the stable contract should be a DeployKube-owned API under `*.darksite.cloud`, with CNPG treated as one implementation backend.

## 2) Goals / non-goals

### Goals

- Define one platform-owned Postgres API for both:
  - internal platform consumers such as Keycloak, Forgejo, PowerDNS, Harbor, and
  - future tenant-facing managed Postgres service requests.
- Keep CNPG platform-internal and out of tenant-facing contracts.
- Preserve the GitOps-first model: operators apply Postgres intent CRs; controllers reconcile the concrete resources.
- Avoid in-flight YAML rendering; use CRDs + controllers as the contract boundary.
- Make multitenant exposure secure by default:
  - tenants do not create raw CNPG resources,
  - the platform controls plans, networking, credentials, and backup posture.
- Keep room for a future backend change or split deployment model without breaking the product API.

### Non-goals

- Replacing CNPG in the near term.
- Designing a generic database abstraction for every engine in v1.
- Giving tenants direct self-service over operators, CRDs, or DB engine internals.

## Current implementation status

Implemented in-repo:

- `data.darksite.cloud/v1alpha1` CRDs for `PostgresClass` and `PostgresInstance`
- dedicated Argo apps for the CRD install, class catalog, and controller runtime
- `platform-postgres-controller` reconciler (implemented in `tools/tenant-provisioner`)
- internal consumer migrations: Keycloak, Forgejo, PowerDNS, and Harbor now request Postgres through `PostgresInstance`
- platform-only disposable classes now support PoCs and lab workloads; IDLab uses `PostgresInstance` with `PostgresClass/platform-poc-disposable`

Current first-slice limitations:

- CloudNativePG is the only backend
- the controller currently reuses the existing namespace-local connection secret flow instead of minting credentials itself
- tenant-facing self-service is still intentionally gated off; the API is platform-internal first

## 3) Design principles

1. The stable contract must be platform-owned.
   Use `*.darksite.cloud`, not `postgresql.cnpg.io`, for the product API.

2. Prefer namespaced request objects.
   The consumer namespace is the natural ownership boundary for internal apps and future tenant projects.

3. Separate request from plan.
   Consumers request a database instance; the platform defines allowed classes/plans cluster-wide.

4. Keep backend details out of the request surface.
   CNPG-specific fields should not leak into the stable API.

5. Treat Postgres as a managed service boundary.
   The platform owns backups, credentials, topology, and engine lifecycle; consumers own schema/app usage.

## 4) Proposed API surface

Recommended API group:

- `data.darksite.cloud/v1alpha1`

Rationale:

- `data.darksite.cloud` is a stable ownership boundary for data-service contracts.
- It avoids binding the public API shape to one engine or one vendor.
- It can later host adjacent managed data surfaces if that remains coherent.

### 4.1 `PostgresClass` (cluster-scoped)

`PostgresClass` defines an allowed service profile. It is platform-owned and cluster-scoped.

Responsibilities:

- allowed storage profile
- HA posture
- backup policy
- retention/deletion behavior
- exposure mode
- engine family/version policy
- performance and quota guardrails

Examples:

- `platform-small`
- `platform-ha`
- `tenant-dev`
- `tenant-prod`
- `platform-poc-disposable`

Consumers do not set low-level CNPG tuning directly. They pick a class the platform supports.

### 4.2 `PostgresInstance` (namespaced)

`PostgresInstance` is the request object used by internal platform apps and, later, tenant projects.

Recommended shape:

- namespaced
- one object per desired managed Postgres instance
- references a `PostgresClass`
- exposes status and connection outputs

Current implemented shape:

```yaml
apiVersion: data.darksite.cloud/v1alpha1
kind: PostgresInstance
metadata:
  name: keycloak-postgres
  namespace: keycloak
spec:
  classRef:
    name: platform-ha
  databaseName: keycloak
  ownerRole: keycloak
  connectionSecretName: keycloak-db
  network:
    accessMode: SameNamespace
```

Currently implemented optional fields:

- `spec.superuserSecretName`
- `spec.serviceAliases[]`
- `spec.resourceNames.*` for runtime-preserving cutovers
- `spec.backup.connection.*` for backup host/TLS overrides

### 4.3 Status contract

`PostgresInstance.status` should be the primary UI and operator surface.

Recommended outputs:

- `status.phase`
- `status.conditions[]`
- `status.endpoint.host`
- `status.endpoint.port`
- `status.databaseName`
- `status.secretRef`
- `status.className`
- `status.observedGeneration`
- `status.backendRef` for platform debugging only

The important distinction is:

- `status.endpoint` and `status.secretRef` are product contract outputs,
- `status.backendRef` is implementation detail for operators.

## 5) Reconciliation model

Implemented controller:

- `platform-postgres-controller`

Recommended input/output flow:

1. Operator applies `PostgresClass` and `PostgresInstance` via GitOps.
2. The controller validates:
   - namespace eligibility,
   - class existence,
   - quota/policy compatibility,
   - tenant/internal ownership rules.
3. The controller reconciles backend resources:
   - CNPG `Cluster`
   - bootstrap/role wiring inside the CNPG `Cluster` spec
   - current first slice reuses the existing namespace-local connection `Secret`
   - stable Service name
   - backup/schedule resources
   - narrow NetworkPolicies
4. The controller updates `PostgresInstance.status`.
5. Consumers use the published Secret and Service, not CNPG resources.

## 6) Internal platform use

Internal platform components should migrate from raw CNPG overlays to `PostgresInstance` over time.

Examples:

- Keycloak requests `PostgresInstance/keycloak-postgres`
- Forgejo requests `PostgresInstance/postgres` in namespace `forgejo`
- PowerDNS requests `PostgresInstance/postgres` in namespace `dns-system`
- Harbor requests `PostgresInstance/postgres` in namespace `harbor`
- IDLab requests `PostgresInstance/idlab-postgres` in namespace `idlab` against the disposable `platform-poc-disposable` class

Benefits:

- internal apps use the same contract as the future product surface,
- credentials, service naming, backup class, and networking become standardized,
- CNPG-specific manifests stop leaking into application components.

Recommended internal rule:

- platform apps may reference only `data.darksite.cloud` request objects and the resulting connection secret/service,
- only the Postgres controller may manage raw CNPG resources for those instances.

## 7) Future tenant-facing managed service model

Tenant exposure should follow the same `PostgresInstance` contract, but only in approved tenant project namespaces and only through platform-defined classes.

Tenant-facing posture:

- tenant repos may request `PostgresInstance`,
- tenant repos may not request `postgresql.cnpg.io/*`,
- tenant repos may not set engine internals, privileged tuning, or cluster topology directly,
- credentials are delivered via a platform-owned Secret flow,
- networking remains platform-managed and default-deny.

This gives DeployKube a path to “DBaaS later” without changing the API consumers already use internally.

## 8) Isolation model

Recommended v1 backend isolation:

- one CNPG cluster per `PostgresInstance`
- run the concrete backend in the owning namespace
- keep the raw CNPG CRs platform-owned even when they live in a tenant namespace

Why this is the default:

- simplest mental model
- strongest boundary versus db-per-tenant on a shared engine
- cleaner backup/restore ownership
- easier per-instance lifecycle and deletion handling

Not recommended for the stable contract:

- shared giant Postgres cluster with many tenant databases as the default service model

That may be a future cost-optimization backend, but it should remain a backend choice hidden behind the same API, not the initial contract.

## 9) Security model

The platform-owned API is how we contain CNPG's broad privileges.

Required guardrails:

- tenant GitOps, tenant RBAC, and tenant admission deny raw `postgresql.cnpg.io` kinds,
- `PostgresClass` is platform-only,
- `PostgresInstance` may be allowlisted by namespace/profile later, not globally open,
- the Postgres controller runs with tightly defined ownership of backend objects,
- raw CNPG operator namespace stays isolated and protected as a platform control plane.

Long-term effect:

- the broad CNPG operator RBAC becomes an internal implementation exception,
- the product contract exposed to users is the platform API, not the operator RBAC surface.

## 10) API ownership and scope decisions

Recommended ownership split:

- `PostgresClass`: platform-owned, cluster-scoped
- `PostgresInstance`: namespaced request object

Why not a cluster-scoped request object:

- namespace is the natural boundary for connection secret publication, service naming, and tenancy policy,
- namespaced objects fit better with internal app ownership and future tenant project ownership,
- cluster-scoped request objects would make consumer scoping and deletion behavior more awkward.

## 11) Backup, restore, and lifecycle

The platform API must make managed-service lifecycle explicit.

`PostgresClass` should define or reference:

- backup mode
- backup frequency/SLO tier
- deletion behavior
- restore eligibility

Recommended deletion policies:

- `Retain`
- `DeleteAfterGracePeriod`
- `PlatformOnly`

The request object should not directly encode engine-specific backup machinery. The controller decides whether the backend uses logical dumps, CNPG native backups, WAL archiving, or a later backend-specific mechanism.

## 12) Networking contract

The product API should expose only high-level access intent.

Recommended `spec.network.accessMode` values:

- `SameNamespace`
- `SelectedNamespaces` later if needed
- `PrivateServiceOnly`

The controller then reconciles:

- stable Service discovery
- NetworkPolicies
- any future mesh exceptions or service-export behavior

Consumers should not hand-author backend DB ingress policies as part of the product contract.

## 13) Migration strategy

### Phase 1: contract design only

- write this design
- keep CNPG as-is for runtime
- keep tenant deny on raw CNPG APIs

### Phase 2: introduce the CRDs and controller

- add `PostgresClass` and `PostgresInstance`
- install CRDs before CRs via dedicated platform-owned GitOps component
- add API reference docs under `docs/apis/**`

### Phase 3: internal adoption

- migrate platform consumers one by one from raw CNPG overlays to `PostgresInstance`
- keep controller generating backend CNPG resources
- prove upgrades and restores through the new surface

### Phase 4: tenant-facing managed service

- allow tenant namespaces/projects to request approved `PostgresInstance` classes
- keep CNPG raw APIs denied
- introduce quotas, plans, and restore/SLO contracts as product features

## 14) GitOps layout (target end-state)

Recommended layout once implemented:

- CRDs:
  - `platform/gitops/components/platform/apis/data/data.darksite.cloud/crd/`
- controller:
  - `platform/gitops/components/platform/apis/data/data.darksite.cloud/controller/`
- API reference:
  - `docs/apis/data/data.darksite.cloud/`

This matches the repo direction for platform-owned APIs and keeps CRDs before CRs.

## 15) Why this is the recommended long-term path

This design is the best fit for DeployKube's product direction because it:

- aligns with the KRM-native `*.darksite.cloud` API strategy,
- gives internal platform apps and future tenants the same stable contract,
- keeps CNPG replaceable as an implementation detail,
- contains a privileged third-party operator behind a platform boundary,
- lets DeployKube productize Postgres incrementally instead of exposing raw engine APIs as the product.

## 16) Open questions

- Should the first public kind name be `PostgresInstance`, `PostgresDatabase`, or `ManagedPostgres`?
  Recommendation: `PostgresInstance` because it maps cleanly to a managed service unit and avoids pretending we expose only a single database inside a potentially richer backend shape.

- Should `data.darksite.cloud` also host future cache/database kinds?
  Recommendation: yes, if they remain coherent managed data-service contracts. If the group starts to sprawl, split later before `v1`.

- Should the first tenant-facing release expose only `SameNamespace` access?
  Recommendation: yes. It is the safest default and easiest posture to validate.
