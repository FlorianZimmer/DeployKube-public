# Idea: Cluster Access Model (4-Eyes RBAC, GitOps Escalation, Breakglass)

Date: 2025-12-25
Status: Draft

## Problem statement

DeployKube needs a consistent access model that works across:
- single-tenant vs multi-tenant vs multi-customer deployments
- single-cluster vs multi-cluster per tenant/customer
- “small install” (few admins) to “large cloud” (many admins/tenants)

Security and HA requirements:
- **Four-eyes principle** for access changes: every *new* permission grant (RoleBinding/ClusterRoleBinding/Argo Project/Vault policy mapping) must require review/approval by a second person.
- **Least privilege by default**: admins start with minimal access and **escalate via Git** (auditable) when troubleshooting requires it.
- **Breakglass access** must exist for when IAM (Keycloak/OIDC) fails, without becoming the “real” day-to-day access path.

Non-goals:
- Perfect prevention of all insider threats; the goal is to make privilege changes explicit, reviewable, time-bound where possible, and detectable.

Related docs/ideas:
- Design doc (implementation plan + guardrails): `docs/design/cluster-access-contract.md`
- RBAC architecture draft: `docs/design/rbac-architecture.md`
- Managed cloud/multi-tenancy: `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
- Declarative provisioning / “single YAML”: `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`

## Why now / drivers

- Multi-customer and multi-cluster increases blast radius: access must be designed as a product feature, not an ad-hoc kubeconfig practice.
- If Keycloak/OIDC becomes a hard dependency with no breakglass story, zone failures or IAM misconfig can lock operators out.
- “Four-eyes” and “escalate via Git” are foundational constraints that affect repo layout, automation, and policies.

## Proposed approach (high-level)

### 1) One identity source, one authorization workflow

Principle:
- **Identity is authoritative in Keycloak**, but **authorization changes are GitOps-managed**.
- Humans do not `kubectl apply` RBAC resources directly in steady-state; they change Git, get review, and Argo reconciles.

Operationally, “get access” means:
1) open a PR that requests additional access (or time-bound access),
2) obtain required approvals (four-eyes),
3) merge → Argo sync → access becomes effective,
4) access expires automatically (for temporary escalation) or is explicitly removed via PR.

### 2) Enforce four-eyes in the system, not in policy docs

Enforcement layers (defense in depth):
- **Git repo controls (primary)**:
  - protect RBAC-critical paths (Kubernetes RBAC, Argo Projects/RBAC, Vault policy mappings)
  - require >= 2 approvals
  - require signed commits if desired for higher assurance
- **Cluster admission controls (secondary)**:
  - reject manual changes to RBAC objects unless performed by the GitOps controller identity (Argo CD service account) or by a breakglass identity
  - reject “privilege escalation patterns” (e.g., binding to `cluster-admin`) except in explicitly defined breakglass workflows

The repo protection gives four-eyes; admission prevents bypass.

### 3) Least-privilege baseline + Git-based escalation (“JIT via Git”)

Baseline access (examples; exact roles are a design detail):
- platform operators: read-most + write in platform namespaces, no RBAC mutation by default
- customer/tenant admins: admin within their tenant scope only (namespaces/projects or tenant clusters), no cross-tenant visibility
- auditors: read-only, no secrets by default

Escalation model:
- troubleshooting requires elevated access → create a PR that adds a **time-bound** binding (or adds user to an “elevated” group) with:
  - scope (which cluster(s), which namespaces)
  - reason/ticket reference
  - expiry timestamp (hard required)
- a controller (or scheduled job) enforces expiry by removing expired grants and recording status.

Important: escalation should be possible even in small single-tenant deployments (the process is the same, just fewer personas).

### 4) Multi-cluster, multi-tenant compatibility

The access model must scale cleanly across:
- one tenant with multiple workload clusters
- many tenants/customers each with one or more clusters

Core requirement:
- access grants must be scoped by **tenant/customer ID** and by **cluster ID** (and optionally by namespace/project).

Two viable deployment patterns (to decide later):
1) **Per-cluster GitOps**: each cluster runs its own Argo CD and enforces RBAC locally from its GitOps repo view.
2) **Central management-plane GitOps**: a management plane Argo reconciles RBAC/Projects/Policies into workload clusters (multi-cluster Argo destinations).

Either way, the Git authorization workflow remains: PR → review → Argo apply.

### 5) Breakglass: always a way in (but controlled)

Breakglass requirements:
- must work if Keycloak/OIDC is down or misconfigured
- must be usable even during partial-zone failure
- must be auditable and rotatable
- must not silently become the “default admin path”

Breakglass access forms (ordered by preference):
1) **Offline-held Kubernetes client certificate(s)** per cluster (stored out-of-band, retrieved via a two-person process).
2) **Cluster-local emergency identity** (if supported by the environment) that does not depend on external IAM.
3) **Node-level access** (Talos/console) to recover the API/IAM, used only when API auth is fully broken.

Breakglass procedure outline:
- credential is stored sealed (e.g., offline Vault, HSM-backed secret store, or physical envelope) with a two-person retrieval requirement.
- usage requires an incident record; commands executed should be logged/captured as evidence.
- after use: rotate/replace the breakglass credential and close the incident with evidence of rotation.

In hosted multi-customer scenarios, define whether breakglass is held by:
- provider SRE only,
- customer security officer only,
- or split custody (recommended for high-trust arrangements).

## What is already implemented (repo reality)

- Keycloak exists as the identity foundation; OIDC is integrated for platform services (`target-stack.md` and component READMEs).
- RBAC direction exists as a draft doc: `docs/design/rbac-architecture.md` (group model, personas, GitOps-managed RBAC intent).
- GitOps boundary is explicit (Stage 0/1 bootstrap → Argo steady-state) (`docs/design/gitops-operating-model.md`).

## What is missing / required to make this real

### 1) A formal “access contract” that spans systems

We need an explicit, implemented contract for:
- Kubernetes API access (OIDC config + kubeconfig flow)
- Argo CD access (projects, RBAC, app scopes)
- Vault access (policies, OIDC/JWT roles, tenant scoping)
- Forgejo access (repos/teams, PR approval enforcement)

### 2) Four-eyes enforcement in Forgejo for RBAC-critical paths

- define which folders are “RBAC critical” and require 2 approvals
- define who are valid approvers (platform security, platform ops, customer security, etc.)

### 3) Admission policies to prevent bypass

- ensure only GitOps controller identity (and breakglass) can mutate RBAC objects
- prevent “accidental cluster-admin” grants except breakglass

### 4) Time-bound access implementation

- choose a representation for expiring grants (annotation, CRD, or dedicated “AccessGrant” object)
- implement expiration enforcement and reporting (controller/CronJob)

### 5) Breakglass credential lifecycle

- define how breakglass certs/users are created per cluster, stored, rotated, and audited
- define “breakglass readiness checks” (prove that the stored credential actually works, without using it for day-to-day ops)

## Risks / weaknesses

- **Operational friction**: four-eyes and Git-based escalation slows response if not designed well; needs a fast-but-audited path for incidents.
- **Policy complexity**: admission and time-bound controllers can become fragile if over-engineered.
- **Breakglass creep**: if IAM is unreliable, people will default to breakglass; IAM HA must be treated as a tier-0 dependency.

## Alternatives considered

- Manual kubeconfigs + ad-hoc RBAC changes:
  - simpler short-term, but fails auditability, four-eyes, and multi-customer safety.
- External PAM/JIT products:
  - may fit later, but still needs a strong in-cluster/GitOps model and does not remove the need for breakglass.

## Open questions

- What is the minimum “incident escalation” latency target (minutes) for regulated customers, and how does that shape PR approval workflows?
- Should “time-bound access” be enforced via:
  - annotations + cleanup controller, or
  - a dedicated CRD like `AccessGrant`?
- Do we require separate Keycloak realms per customer in hosted mode, or a single realm with strict group scoping?
- What custody model do customers expect for breakglass credentials (provider-held vs split custody)?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A concrete, implemented four-eyes enforcement mechanism for RBAC changes (repo protection + admission).
- A working “escalate via Git” flow with time-bound access and automatic expiry.
- A documented and tested breakglass procedure (creation, storage, retrieval, rotation) with evidence capture.
- Clear multi-cluster scoping rules (tenant/customer IDs + cluster IDs) that work for both dedicated and hosted deployments.
