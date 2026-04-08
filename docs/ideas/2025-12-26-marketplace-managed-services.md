# Idea: Cloud Marketplace (Fully Managed Services vs Curated Deployments)

Date: 2025-12-26
Status: Draft

## Problem statement

DeployKube should provide a “public cloud-like” **marketplace** where users can order services that are:
- pre-hardened by default
- integrated with platform IAM (Keycloak), secrets (Vault/ESO), TLS (Step CA + cert-manager), and observability
- available in HA configurations and compatible with the platform’s multi-zone goals

This needs two clearly separated product levels:

1) **Fully Managed Services** (provider-operated, “DBaaS/ObjStore-as-a-Service”)
- The platform operator/provider owns day-2 operations and an SLO.
- Users consume the service via a declarative request (YAML/UI), not by operating the underlying operator/cluster.

2) **Marketplace Offerings (Curated Deployments)** (procurement + deployment channel)
- The platform provides a curated, hardened, GitOps-friendly deployment package.
- The tenant/customer owns day-2 operations of the service (unless they separately buy managed ops).

The responsibilities and guarantees must be explicit to avoid “we deployed it” being mistaken for “we run it”.

Related ideas:
- KRM-first Cloud UI (authors declarative requests): `docs/ideas/2025-12-25-krm-gitops-cloud-ui.md`
- Declarative provisioning / “single YAML” (tenants/clusters/services): `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`
- Managed private cloud multi-tenancy: `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
- Three-zone anycast+BGP: `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`

## Why now / drivers

- A marketplace is the natural “self-service surface” for a private cloud offering.
- Without an explicit split between “managed” and “curated deployments”, we risk unclear operational boundaries and security/SLA disputes.
- Multi-tenant, regulated environments require consistent hardening/IAM integration; ad-hoc Helm installs won’t scale.
- Air-gapped customers need an artifact and upgrade story that a marketplace can standardize.

## Proposed approach (high-level)

### 1) Define two product classes with explicit responsibilities

#### A) Fully Managed Services (FMS)

Definition:
- The provider/platform team is responsible for provisioning, upgrades, backups, monitoring, incident response, and security patching.
- The user/tenant only declares intent (plan/size/SLO class) and consumes endpoints/credentials.

Examples:
- Managed Postgres (“DBaaS”) backed by CNPG
- Managed S3-compatible object storage backed by Garage
- Managed Redis/Valkey

Key implications:
- “Managed” requires **clear SLOs** and operational runbooks.
- “Managed” must have a data durability story compatible with multi-zone goals (or must explicitly be “single-zone only” until the multi-zone storage design exists).

#### B) Marketplace Offerings (Curated Deployments)

Definition:
- The platform provides a curated deployment package (GitOps app), default hardening, and integration hooks (IAM/TLS/secrets/observability).
- The tenant/customer is responsible for day-2 operations unless they purchase an additional managed-ops package.

Examples:
- Hardened GitLab/Harbor/ClickHouse/Elastic stack deployments (as packages)
- “Paved path” app templates (ingress, policies, dashboards), operated by the tenant

Key implications:
- The marketplace guarantees **deployment correctness and integration**, not ongoing availability.
- The package must ship explicit operational docs (backup/restore, upgrades, SRE runbooks) and clearly mark what is not handled by the platform.

### 2) Ordering interface: declarative “service requests” (UI-wrappable)

Model a service order as a KRM object (or a small set) so it can be created by:
- Git PR (four-eyes), or
- the future Cloud UI (which authors GitOps CRs), or
- an emergency direct apply (optional, but discouraged)

Candidate API shapes:
- `ServiceCatalogItem` / `ServicePlan` (published offerings and constraints)
- `ServiceInstance` (a user’s ordered instance of a service)
- Optional: `ServiceBinding` (how apps consume credentials/endpoints)

Key properties:
- Tenant-scoped: service instances must be bound to a tenant/customer identity and (if multi-cluster) a target cluster.
- Policy-validated: prevent unsupported combos (e.g., “multi-zone managed DB” when the deployment only has one zone).

### 3) Deployment model: GitOps apps for everything, with clear ownership

Both FMS and Marketplace Offerings should be delivered as Argo-managed apps, but:
- **FMS** instances should be reconciled by a provider-owned controller that generates/owns the underlying manifests and enforces SLO policies.
- **Marketplace** installs should be “turnkey GitOps apps” (Helm/Kustomize packages) with tenant-owned day-2 responsibilities.

### 4) IAM, security, and hardening: platform baselines vs service-specific policy

Regardless of product class, the marketplace must standardize:
- identity integration patterns (Keycloak OIDC, groups/roles, service accounts)
- secrets delivery (Vault/ESO) and rotation expectations
- TLS posture (cert-manager + Step CA; plaintext exceptions must be documented)
- baseline network policy expectations (default deny where feasible, explicit egress)
- audit logging expectations (who ordered what, who approved it)

Managed services additionally must standardize:
- backup/restore SLO and testing cadence
- upgrade and patch windows (and emergency patch workflow)
- incident response boundaries (what the provider does vs what the tenant must do)

### 5) Responsibilities matrix (explicit)

At minimum, document and enforce these boundaries:
- **Provisioning**: FMS = provider; Marketplace = platform deploys package, tenant owns ops thereafter.
- **Upgrades/Patching**: FMS = provider; Marketplace = tenant (platform may publish updates).
- **Monitoring/Alerting**: FMS = provider owns alerts; Marketplace = tenant consumes dashboards/alerts.
- **Backup/Restore**: FMS = provider runs and tests restores; Marketplace = tenant responsibility (package provides tooling/runbooks).
- **Security incidents**: FMS = provider response; Marketplace = tenant response (provider supports platform layer only).
- **Data ownership**: always tenant/customer; platform must define encryption-at-rest/in-transit expectations per class.

### 6) Artifact distribution (air-gapped friendly)

Marketplace requires:
- pinned chart/image versions (and ideally digests)
- offline artifact packaging/mirroring story
- compatibility matrix with `target-stack.md`

Managed services require the above plus stronger change-control discipline (SLO impact awareness, staged rollouts).

## What is already implemented (repo reality)

- Core platform building blocks exist: GitOps (Forgejo/Argo), IAM (Keycloak), secrets (Vault/ESO), TLS (Step CA/cert-manager), observability (LGTM) (`target-stack.md`).
- Operators and data-plane components exist that could become the first “managed” services:
  - CloudNativePG (Postgres), Garage (S3), Valkey
- There is currently no service marketplace API, no catalog, and no explicit managed-vs-curated responsibility model.

## What is missing / required to make this real

### 1) A catalog and instance API (CRDs + validation)
- Define what constitutes an “offering”, “plan”, and “instance”.
- Define tenant/customer scoping and multi-cluster targeting.
- Define admission/policy validation for safe defaults.

### 2) A “managed service operator” (for FMS)
- Reconcile `ServiceInstance` into underlying resources.
- Enforce SLO policies (replicas, PDBs, topology spread, backup schedules).
- Emit health/status and support evidence capture.

### 3) A packaging standard for Marketplace Offerings
- Minimum hardening requirements (IAM/TLS/secrets/observability hooks).
- Required docs/runbooks and explicit responsibility statements.
- Upgrade channel (how new versions of the package are published and applied).

### 4) Commercial/operational boundaries
- Define what the provider guarantees for managed services (SLOs, support tiers).
- Define what the marketplace guarantees for curated deployments (deployment success, compatibility, but not runtime SLO unless separately contracted).

## Risks / weaknesses

- **Responsibility confusion**: marketplace deployments can be mistaken for managed services; contracts must be unambiguous.
- **Overpromising HA**: “pre-hardened and HA” depends on customer topology (zones, storage). Plans must encode prerequisites.
- **Supply-chain burden**: pinning, mirroring, and upgrading many offerings is a major ongoing effort.
- **Multi-zone dependency**: true multi-zone managed services require a multi-zone storage and quorum design; until then, managed offerings must clearly state limitations.

## Alternatives considered

- “Just publish Helm charts”:
  - low effort but fails the product requirements (IAM/TLS integration, hardening, responsibility clarity).
- Adopt an external marketplace ecosystem:
  - feasible later, but still requires a DeployKube-specific contract for IAM/secrets/TLS/policy and air-gapped artifact flows.

## Open questions

- What is the initial top-5 catalog (managed vs curated)?
- Do we run managed services in:
  - each tenant’s workload cluster, or
  - a shared “service cluster” (strong isolation required), or
  - dedicated hardware per tenant for regulated tiers?
- How do we encode prerequisites in plans (zones available, storage class capabilities, network mode)?
- How do we implement chargeback/billing (even if only for internal/showback in dedicated deployments)?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A concrete CRD model for catalog + service instances (v1alpha1) with tenant scoping.
- A clear responsibilities matrix that is reflected in docs and in the API (managed vs curated is explicit).
- One “managed” service and one “curated marketplace” offering implemented end-to-end with:
  - IAM/secrets/TLS integration
  - smoke tests
  - upgrade story
  - explicit ops/runbook ownership

