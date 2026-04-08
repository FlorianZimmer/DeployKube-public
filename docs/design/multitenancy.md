# DeployKube Multitenancy (Org + Projects) — GitOps-First “Cloud Feel”

<a id="dk-mt-top"></a>

Last updated: 2026-01-16  
Status: **Design (Phase 0/1: foundations in repo; Phase 2+: planned)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy.md`
- Related trackers / contracts:
  - GitOps boundary + operations: `docs/design/gitops-operating-model.md`
  - Access contract + breakglass posture: `docs/design/cluster-access-contract.md`
  - RBAC groups/personas: `docs/design/rbac-architecture.md`
  - Policy engine + tenant baseline constraints: `docs/design/policy-engine-and-baseline-constraints.md`
  - Label registry (contract): `docs/design/multitenancy-label-registry.md`
  - Contracts + enforcement checklist (single-page): `docs/design/multitenancy-contracts-checklist.md`
  - GitOps + Argo tenancy boundaries: `docs/design/multitenancy-gitops-and-argo.md`
  - Multi-tenant storage contract: `docs/design/multitenancy-storage.md`
  - Tenant secrets + Vault conventions: `docs/design/multitenancy-secrets-and-vault.md`
  - Tenant lifecycle + data deletion (runbooks/contract): `docs/design/multitenancy-lifecycle-and-data-deletion.md`
  - Observability tenancy direction: `docs/design/observability-lgtm-design.md`

---

## MVP scope (Tier S first; do not block Tier D/H)

For Queue #11 (“Multitenancy as a product”), the MVP implements **Tier S (shared-cluster tenancy)** only: logical isolation via **labels + admission + policy + Argo boundaries + RBAC**.

**Explicit non-goal (for the MVP):** implementing Tier D/H (dedicated clusters and/or hardware separation).

**Hard requirement:** nothing we ship for Tier S should make Tier D/H harder later. Concretely:
- `orgId` / `projectId` are **stable identifiers** and must not encode `deploymentId`, cluster names, or storage backends.
- Git contracts (tenant registry + tenant workload repos) must remain **portable** across shared → dedicated: changing the target cluster must be a platform-owned registry/config decision, not a tenant repo rewrite.
- Vault path contracts must remain tier-agnostic (a dedicated cluster may use a different Vault instance, but the logical tenant subtree model stays the same).

## 1) Goals

DeployKube multitenancy must:

1. **Feel like a real cloud** (GCP-like mental model)
   - Users reason about **Organizations** and **Projects**
   - Networking feels like **VPC + firewall**, not “random namespaces”

2. Stay **GitOps-first** (non-negotiable)
   - UI is a Git client that authors YAML + PRs
   - No direct UI mutation of cluster state (“no control plane writes”)

3. Preserve **repo constraints** and existing contracts
   - Bootstrap (Stage 0/1) is minimal; steady-state is Argo root app `platform-apps`
   - Existing tenant namespace label contract must remain stable:
     - If `darksite.cloud/rbac-profile=tenant`, the namespace **must set**
       `darksite.cloud/tenant-id` and `observability.grafana.com/tenant` with equal values
     - Implemented via VAP:
       `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-label-contract.yaml`
   - Baseline tenant networking is deny-by-default with explicit exceptions
     - Implemented via Kyverno generate policy:
       `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`

4. Provide a clear **tenancy offerings** story
   - **Shared-cluster tenancy** (multiple orgs/projects within one cluster)
   - **Dedicated tenancy** (org gets its own workload cluster(s) and optionally dedicated hardware pools)
   - Out-of-scope (but tracked): **Virtual clusters** (vcluster-like)

5. Be **safe at scale** (performance, scalability, blast radius)
   - Tenant onboarding must not require mutating global control-plane config (or restarting shared controllers) for each new org/project.
   - A single tenant must not be able to degrade the Kubernetes control-plane or shared platform services (“noisy neighbor” controls).
   - The design must carry explicit scale budgets and “switch thresholds” before we treat shared-cluster tenancy as a product offering.

### 1.1 Non-functional budgets (required before Phase 2)
Before enabling “hostile tenant” shared-cluster onboarding (Tier S for real customers), we must record and track explicit budgets.
At minimum:

- **Tenancy shape budgets**
  - max orgs / projects per cluster
  - max tenant namespaces per org and total

- **GitOps/control-plane budgets**
  - max Argo `Application`/`AppProject` objects and expected reconcile rate
  - “no global file grows per tenant” rule (avoid per-tenant edits to shared Argo RBAC ConfigMaps)

- **Networking budgets**
  - Defined in [`docs/design/multitenancy-networking.md`](multitenancy-networking.md#dk-mtn-budgets) (“12) Budgets + switch thresholds (required to productize)”).

- **Identity budgets**
  - max Keycloak groups per user that we expect to emit in tokens
  - max OIDC token size we consider acceptable for Argo/K8s auth paths

- **Observability budgets**
  - per-org ingestion and query limits for logs/metrics/traces (to prevent noisy neighbor)

---

## 2) Non-goals (for this design phase)

- A full “cloud API surface” (CRDs/controllers for every concept) on day 1
- Cross-org private connectivity “inside the stack” (no peering shortcuts)
- Claiming hard side-channel resistance for shared-cluster tenancy
- Designing around virtual clusters (vcluster). We track it for later but do not anchor the design on it.

---

<a id="dk-mt-terminology"></a>

## 3) Terminology (GCP-like)

### Organization (“org”)
A top-level customer account. In hosted mode: org ~= customer.

- Identifier: `orgId`
- Cloud feel: “billing account / customer boundary / admin boundary”

### Project
A team/app/environment grouping under an org. One org has many projects.

- Identifier: `projectId`
- Cloud feel: “team space / environment boundary / app boundary”

### VPC
An org-owned network domain. Projects attach to a VPC (including Shared VPC across projects).

- Identifier: `vpcId`
- Cloud feel: “private network + firewall”

---

## 4) Tenancy offerings (what we sell / operate)

### A) Shared-cluster tenancy (default for cost/velocity)
**Model**: multiple orgs/projects share a Kubernetes cluster; isolation is via:
- namespace scoping
- RBAC + admission guardrails (“Git-only access changes”)
- baseline deny-by-default NetworkPolicies + explicit exceptions
- ingress controls (Gateway API + policy constraints)
- observability tenancy boundaries

**Guarantees**:
- Strong *logical* isolation (API, RBAC, network policy, audit)
- Not a side-channel resistant boundary (shared kernel/worker nodes)

**Use when**:
- One customer, many teams (single trust domain)
- Low/medium paranoia
- Cost/ops simplicity matters

### B) Dedicated tenancy (“paranoid/regulatory”)
**Model**: org gets its own workload cluster(s) (and optionally dedicated hardware pools).
- still GitOps-first: desired state is in Git; Argo reconciles per cluster
- org has clean blast radius boundaries at cluster/lifecycle level

**Guarantees**:
- Strong isolation boundary at “cluster per org”
- Compatible with dedicated nodes/racks for side-channel resistance claims

**Use when**:
- Regulated workloads
- Strong customer boundary requirements
- “We must prove no co-tenancy on nodes/racks”

---

## 5) Threat model and paranoia tiers

This section defines what we *actually* protect against, per offering.

### Threats we explicitly model
- **T1: Accidental cross-tenant access**
  - Wrong RBAC binding, wrong label, or an overly broad policy
- **T2: Tenant-to-tenant lateral movement**
  - Network reachability, service discovery, route hijack
- **T3: Privilege escalation via Kubernetes API**
  - Direct RBAC mutation, admission/webhook tampering, namespace label tampering
- **T4: Data-plane leakage through observability**
  - Logs/metrics/traces visible across orgs/projects
- **T5: “Support session” abuse**
  - Untracked or overly broad breakglass/support access
- **T6: Noisy neighbor / control-plane exhaustion**
  - API watch/list storms, overly chatty reconcilers, expensive admission/policy evaluation, or unbounded GitOps sync loops

### Paranoia tiers (recommended)
- **Tier S (Shared / Standard)**: shared-cluster tenancy
  - Primary goal: prevent T1–T5 *logically*
  - We do not claim side-channel resistance
  - Subtiers (pragmatic Phase 0/1 split):
    - **S0 (seed / friendly tenants)**: internal/friendly tenants; may rely on Git governance and incomplete guardrails; not a “hostile tenant” claim.
    - **S1 (standard / product candidate)**: hostile-tenant-capable shared cluster; requires enforceable contracts (admission/policy/Argo/RBAC), explicit budgets, and evidence-backed promotion gates.
- **Tier D (Dedicated)**: org-per-cluster tenancy
  - Primary goal: reduce blast radius and simplify compliance evidence
- **Tier H (Dedicated + Hardware separation)**: org-per-cluster + dedicated pools/racks
  - Goal: side-channel-resistant posture is plausible (still requires careful operational discipline)

**Important**: The design must never imply that shared-cluster tenancy is equivalent to dedicated hardware isolation.

---

<a id="dk-mt-k8s-mapping"></a>

## 6) Kubernetes mapping (Org + Projects) — the core contract

<a id="dk-mt-k8s-invariants"></a>

### 6.1 Invariants (do not break)
- `orgId` **reuses** the existing label contract:
  - `darksite.cloud/tenant-id = <orgId>`
  - `observability.grafana.com/tenant = <orgId>`
  - enforced today by VAP:
    - `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-label-contract.yaml`
  - canonical label registry: `docs/design/multitenancy-label-registry.md`

### 6.2 New project concept
We introduce:
- `darksite.cloud/project-id = <projectId>`

**Reason**: project is the unit of ownership, Git workflow, and policy exceptions.

This is **Planned** as an admission contract (see “Implemented vs Planned” section).

<a id="dk-mt-namespace-taxonomy"></a>

### 6.3 Namespace taxonomy (what namespaces exist)
We keep a small taxonomy, because labels drive everything:

- **Platform namespaces** (owned by platform operators)
  - `darksite.cloud/rbac-profile=platform` (existing model)
- **App namespaces** (team namespaces, internal to the platform operator’s org)
  - `darksite.cloud/rbac-profile=app` + `darksite.cloud/rbac-team=<team>` (existing)
- **Tenant namespaces** (customer workloads)
  - `darksite.cloud/rbac-profile=tenant`
  - `darksite.cloud/tenant-id=<orgId>` (existing)
  - `observability.grafana.com/tenant=<orgId>` (existing)
  - `darksite.cloud/project-id=<projectId>` (new)
  - Optional networking attachments:
    - `darksite.cloud/vpc-id=<vpcId>` (see networking doc)

For the canonical list (including mutability), see: `docs/design/multitenancy-label-registry.md`.

### 6.4 Naming convention (recommended)
Namespace names should be:
- globally unique
- stable across moves (shared → dedicated)
- human-scannable

Recommended pattern:
- `t-<orgId>-p-<projectId>-<env>-<purpose>`

Examples:
- `t-acme-p-payments-dev-app`
- `t-acme-p-payments-prod-app`
- `t-acme-p-platform-prod-shared-services` (if you choose project “platform” within org)

**Note**: Namespace name is *not* the source of truth; labels are.

**Constraints (recommended; enforce via validation gates/admission when we productize)**
- Kubernetes namespace names are DNS labels: **max 63 chars**, lowercase alnum + `-`, must start/end with alnum.
- `orgId` / `projectId` / `vpcId` should be treated as **stable identifiers** (not display names). Keep them short to avoid:
  - namespace name length issues
  - Keycloak group name bloat
  - long DNS hostnames and certificate subject lengths

### 6.5 Ownership (who can create/change what)
To keep “cloud feel” and prevent bypasses:

- Tenants do **not** get `create namespaces` (RBAC)
- Tenants do **not** get `update namespace labels` (RBAC)
- Tenants do **not** get to mutate RBAC/admission/CRDs directly
  - This is aligned with the access contract:
    `docs/design/cluster-access-contract.md`

Result:
- A tenant cannot “label themselves into” a different org/project/VPC
- A tenant cannot attach routes to shared gateways or hijack hostnames (once we enforce the planned policy gates)

<a id="dk-mt-label-immutability"></a>

### 6.6 Label immutability (admission contract; Phase 1 partial implementation)
For tenant namespaces, treat these labels as **identity** and make them immutable after creation:
- `darksite.cloud/rbac-profile`
- `darksite.cloud/tenant-id`
- `darksite.cloud/project-id`
- `darksite.cloud/vpc-id` (if present)
- `observability.grafana.com/tenant`

Phase 1 implementation status:
- Enforced today (VAP A2): set-once immutability for `darksite.cloud/{tenant-id,project-id,vpc-id}`.
- Still planned: immutability for `darksite.cloud/rbac-profile` and `observability.grafana.com/tenant`.

Rationale:
- prevents accidental or malicious “re-homing” of workloads into another org/project/VPC by relabeling
- reduces blast radius: a bad label change becomes “create a new namespace and migrate” (auditable), not “silent identity swap”

Enforcement (Phase 1; must be admission-enforced, not just RBAC/process):
- Implement a `ValidatingAdmissionPolicy` (CEL) for `Namespace` CREATE/UPDATE, scoped to `darksite.cloud/rbac-profile=tenant`.
- Validation requirements:
  - **Presence**: require `darksite.cloud/project-id` for tenant namespaces (in addition to the existing `tenant-id` + observability tenant contract).
  - **Value constraints**: `tenant-id`, `project-id`, `vpc-id` must be DNS-label-safe (`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`, max 63).
  - **Immutability** on UPDATE using `oldObject`:
    - once set, identity label values cannot change,
    - identity labels cannot be removed,
    - optional labels (like `vpc-id`) may be “set once” (allowed to be added if previously unset; still immutable afterwards).

Implementation:
- VAP A1: `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-label-contract.yaml`
- VAP A2: `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-identity-contract.yaml`

Operational implication:
- Moves (e.g. shared → dedicated, project splits) are done by **creating new namespaces** and migrating workloads/data, not by editing identity labels in-place.

---

## 7) GitOps representation (how this feels cloud-like)

### 7.1 Principles
- Everything is **declared** and reviewed
- “Provisioning” is a PR that adds:
  - org/project namespace(s)
  - RBAC bindings (via labels + sync)
  - networking attachments (labels + policies)
  - observability and secrets integration

<a id="dk-mt-folder-contract"></a>

### 7.2 Recommended folder contract (Planned)
We standardize where “tenant intent” lives in Git to keep PRs tidy and auditable.

**Repo reality:** the tenant intent surface is now scaffolded under `platform/gitops/tenants/` (required `metadata.yaml` + per-project namespace intent). The broader contract below (VPCs, services, storage) is implemented incrementally as each tenant-facing primitive is productized.

Important: there are **two** Git surfaces in the Tier S model:

1. **Platform-owned tenant registry + infra intent** (this repo, reconciled by `platform-apps`)
   - namespaces + identity labels, VPC/firewall intent, service-catalog requests, support-session exceptions
   - Argo access-plane objects (AppProjects + tenant root Applications) live under `platform/gitops/apps/tenants/` (see `docs/design/multitenancy-gitops-and-argo.md`)

2. **Tenant-owned workload repos** (preferred for Tier S1 “hostile tenants”)
   - Argo can restrict by **repo URL** but not by **path inside a repo**
   - Therefore, repo-per-project is the recommended “product mode” boundary (see `docs/design/multitenancy-gitops-and-argo.md#5-3-source-repos-repo-restrictions`)

Proposed structure:
```
platform/gitops/tenants/<orgId>/
  README.md                     # org runbook / contacts (doc-only in v1)
  metadata.yaml                 # tenant lifecycle contract (required; see multitenancy-lifecycle-and-data-deletion.md)
  vpcs/
    <vpcId>/                    # VPC + firewall intent (see multitenancy-networking.md)
      README.md
      firewall/
        allow/
          netpol-*.yaml         # v1: concrete NetworkPolicies (no “deny” concept in K8s NetworkPolicy)
  projects/
    <projectId>/
      README.md
      namespaces/
        <env>/
          <namespaceName>.yaml  # Namespace + identity labels (tenant-id/project-id/vpc-id)
      rbac/
        bindings.yaml           # optional beyond label sync
      network/
        netpol-*.yaml           # optional connectivity exceptions
        httproute-*.yaml        # optional tenant ingress routes (see multitenancy-networking.md)
      services/                 # managed service intent (see multitenancy-service-catalog.md)
        postgres/
          instances/
            <instanceName>.yaml
        valkey/
          instances/
            <instanceName>.yaml
  storage/                      # org-scoped storage intent (see multitenancy-storage.md)
    README.md
    s3/
      buckets/
        <bucketName>.yaml
    backup/
      scope.yaml
```

Tenant workload source (Tier S1 “product mode”, recommended):
- Forgejo org: `tenant-<orgId>`
- Repo: `apps-<projectId>`
- Workload YAML (Deployments/Services/HTTPRoutes/NetworkPolicies/PVCs) lives in the tenant repo and is constrained by the tenant `AppProject` allowlists/denylists and admission/policy guardrails.

Monorepo fallback (Tier S0 “friendly tenants only”):
- Tenant workload YAML may live under `platform/gitops/tenants/<orgId>/projects/<projectId>/...`, but Argo cannot enforce path boundaries within the repo.
- Treat this as a weaker isolation tier that relies on Git governance + platform-owned `Application.spec.source.path` (not suitable for hostile tenants).

**Important**: In v1, `metadata.yaml` / `README.md` are conventions and review surfaces; enforcement is via labels and admission policies, not bespoke controllers.

---

## 8) Identity model (Keycloak, Kubernetes RBAC, Argo, Forgejo, Vault)

This section defines how org/project boundaries propagate across systems.

### 8.1 Keycloak groups (authoritative for humans)
Existing platform uses `dk-*` groups.

We extend with a tenant/org/project pattern:

- Org-level
  - `dk-tenant-<orgId>-admins`
  - `dk-tenant-<orgId>-viewers` (optional)
  - `dk-tenant-<orgId>-support` (reserved)

- Project-level
  - `dk-tenant-<orgId>-project-<projectId>-admins`
  - `dk-tenant-<orgId>-project-<projectId>-developers`
  - `dk-tenant-<orgId>-project-<projectId>-viewers`
  - `dk-tenant-<orgId>-project-<projectId>-support` (reserved)

**Governance**
- In Phase 0/1, DeployKube defines group *names and meaning* in Git.
- Group membership governance is environment/customer-specific (may be external IdP).
- This matches the repo’s stated direction: systems bind groups, not users.

**Scalability note**
- Group-claims-in-tokens can hit practical limits (token size, proxy/header limits, downstream parsing cost) if we emit “too many groups per user”.
- If we expect users to be members of many projects, prefer coarser roles/claims (or an alternate claim representation) over a group-per-project explosion.

### 8.2 Kubernetes RBAC (namespace-scoped)
**Implemented today**
- RoleBindings are generated for `rbac-profile=platform`, `rbac-profile=app`, and `rbac-profile=tenant` namespaces by:
  - `platform/gitops/components/shared/rbac/base/namespace-sync/configmap.yaml`
- App profile requires `darksite.cloud/rbac-team`.
- Tenant profile requires `darksite.cloud/tenant-id` and `darksite.cloud/project-id`, and binds to the org/project group patterns above.

This keeps tenant access changes “cloud-like”:
- Onboarding a new tenant project is “create namespaces with labels”
- Onboarding a user is “add them to Keycloak groups”
- No bespoke RBAC manifests per namespace unless absolutely necessary

**Performance/scalability note**
- A “periodic full scan + kubectl apply” loop is acceptable for small scale, but it must not become a control-plane DoS vector at larger namespace counts.
- Before Phase 2 scale, prefer an incremental reconciliation model (watch namespaces, avoid writing unchanged RoleBindings, batch updates, and backoff under API pressure).

### 8.3 Argo CD boundaries (AppProjects + RBAC)
Argo must prevent tenants from affecting each other (even in GitOps).

**Planned**
- Create an `AppProject` per org, and optionally per project:
  - Org project: limits destinations and source repos for that org
  - Project project: further scoping for teams/environments
- Argo RBAC (group claims) maps org/project groups to:
  - read-only / sync / admin abilities **within that AppProject**
- This aligns with the repo’s Argo RBAC approach:
  - OIDC config and policy CSV are patched in:
    `platform/gitops/components/platform/argocd/config/scripts/configure-oidc.sh`
  - Today it is team/app oriented; we extend it for tenant org/project.

**Scalability/blast-radius requirement**
- Tenant onboarding must avoid “edit global `argocd-rbac-cm` for every tenant” patterns.
- Prefer per-tenant scoping expressed in `AppProject.spec.roles[].groups` so that adding an org/project does not require a global RBAC policy change or Argo restart.

### 8.4 Forgejo repo and team model (Git boundary)
We want “cloud feel” where projects map to repos/teams cleanly.

**Recommended default (Shared-cluster)**
- A Forgejo **organization per customer org**:
  - `fg-org = tenant-<orgId>`
- Projects map to repos inside that org
  - `apps-<projectId>` repo, or repo-per-app inside project
- Forgejo teams mirror Keycloak groups (Planned extension)
  - Similar to the existing sync direction in `platform/gitops/components/shared/rbac/README.md`

This makes review ownership natural:
- org admins approve org-wide changes
- project teams approve project-level changes

### 8.5 Vault paths and policies (secret scoping)
Vault is a core multitenancy boundary.

See `docs/design/multitenancy-secrets-and-vault.md` for the full contract (ESO guardrails, rotation/revocation, and offboarding wipe semantics).

Recommended path structure:
- Org scope:
  - `secret/data/tenants/<orgId>/*`
- Project scope:
  - `secret/data/tenants/<orgId>/projects/<projectId>/*`
- Environment scope (optional):
  - `secret/data/tenants/<orgId>/projects/<projectId>/env/<env>/*`

Policy mapping:
- `dk-tenant-<orgId>-admins` → read/write org scope
- `dk-tenant-<orgId>-project-<projectId>-admins` → read/write project scope
- `dk-tenant-<orgId>-project-<projectId>-developers` → write-only project scope by default (no read on `secret/data/...`)
- `dk-tenant-<orgId>-project-<projectId>-viewers` → read-only project scope (optional)

---

## 9) Observability separation (org/project mapping)

### 9.1 Org-level tenancy (hard boundary)
We deliberately reuse:
- `observability.grafana.com/tenant = <orgId>`

This aligns with the LGTM multi-tenancy intent:
- Loki/Mimir/Tempo multi-tenancy typically uses a tenant header (e.g. `X-Scope-OrgID`)
- DeployKube’s existing contract already establishes the canonical org tenant id

**Implemented today**
- The label contract exists and is enforced for tenant namespaces (VAP)
- The full end-to-end enforcement may still be platform-scoped in places; see:
  - `docs/design/observability-lgtm-design.md`

### 9.2 Project-level separation (soft boundary by default)
Within an org, project separation is typically:
- a combination of labels and query scopes:
  - e.g. `darksite.cloud/project-id=<projectId>` propagated to telemetry as a label

This is *not* a full tenancy boundary unless we enforce it at the query/auth layer (planned).
Default recommendation:
- **Hard isolation at org level**
- **Soft isolation at project level** (filters + org-internal RBAC)

**Planned**
- Ensure telemetry pipelines (Alloy) attach `projectId` as a label where possible
- Use Grafana folders/datasources to scope dashboards per project
- Optional future hard boundary: project-based sub-tenancy inside LGTM (complex; not required for v1)
- Add per-org **ingestion and query limits** (logs/metrics/traces) to prevent noisy neighbor impact across tenants.

---

## 10) Networking Contract (source of truth)

This doc intentionally avoids duplicating networking design details.  
Use [`docs/design/multitenancy-networking.md`](multitenancy-networking.md#dk-mtn-top) as the canonical spec, especially:

- [“2) Repo reality (implemented baseline)”](multitenancy-networking.md#dk-mtn-repo-reality)
- [“2.4 Tenant workloads vs Istio mesh”](multitenancy-networking.md#dk-mtn-tenant-workloads-vs-mesh)
- [“3) The model: Org, Project, VPC, and connectivity classes”](multitenancy-networking.md#dk-mtn-model)
- [“4) GitOps expression (labels + folders)”](multitenancy-networking.md#dk-mtn-gitops-expression)
- [“5) Firewall policy model …”](multitenancy-networking.md#dk-mtn-firewall) and [“6) VPC-to-VPC connectivity …”](multitenancy-networking.md#dk-mtn-vpc-to-vpc)
- [“7) Egress control (internet + customer networks)”](multitenancy-networking.md#dk-mtn-egress)
- [“8) Ingress / external exposure …”](multitenancy-networking.md#dk-mtn-ingress)
- [“9) Where enforcement happens (explicit)”](multitenancy-networking.md#dk-mtn-enforcement)
- [“10) Auditing and evidence”](multitenancy-networking.md#dk-mtn-evidence) and [“11) Smoke tests …”](multitenancy-networking.md#dk-mtn-smoke-tests)
- [“12) Budgets + switch thresholds (required to productize)”](multitenancy-networking.md#dk-mtn-budgets)

---

## 11) Lifecycle (onboarding/offboarding, upgrades, migrations, support)

### 11.1 Onboarding flow (shared-cluster)
**Desired “cloud feel”**: onboarding is a PR.

Planned direction (KRM-native): onboarding becomes “add one `Tenant` CR” and let a controller converge namespaces, Argo boundaries, and tenant repo provisioning. See: `docs/design/tenant-provisioning-controller.md`.

1. Create org folder (`platform/gitops/tenants/<orgId>/`)
2. Define VPCs for the org (optional first)
3. Create project(s) with namespaces per env
4. Ensure namespaces include required labels:
   - `rbac-profile=tenant`
   - `tenant-id=<orgId>`
   - `observability...=<orgId>`
   - `project-id=<projectId>`
   - optional: `vpc-id=<vpcId>`
5. Merge PR → Argo reconciles
6. RBAC sync job applies RoleBindings based on labels
7. Policy baseline applies (implemented today: Kyverno generates netpol/quota/limits)
8. Evidence captured under `docs/evidence/`

### 11.2 Offboarding flow (shared-cluster)
Offboarding is also Git-driven, plus an evidence trail.

1. PR removes:
   - project namespaces/manifests
   - project-specific firewall exceptions
   - org/project access bindings (if any)
2. Operator process revokes identity membership (IdP) and Vault access
3. Confirm:
   - namespaces deleted
   - secrets paths are wiped per policy
   - observability data retention rules apply (data ages out)
4. Record evidence (who approved, when removed, deletion confirmation)

### 11.3 Upgrade story
- Platform upgrades are still platform-owned (Argo reconciles platform components).
- Tenant projects ride the platform upgrade with:
  - stable baseline policies
  - explicit version compatibility notes in release process (outside this doc)

### 11.4 Migration: shared → dedicated
Goal: same org/project identifiers; different substrate.

- Keep `orgId` stable (`tenant-id` label remains the same)
- Move project manifests to the dedicated cluster GitOps repo (or per-cluster path)
- Re-point ingress/DNS to the dedicated gateway IPs
- Preserve audit trail: PRs and evidence for cutover

### 11.5 Support / breakglass posture
Must align with:
- `docs/design/cluster-access-contract.md`

Principles:
- Access changes are Git-managed
- Support sessions are time-bound, evidence-backed, and reversible
- Cross-org support connectivity is *external* (not “peering” inside the stack); see [`docs/design/multitenancy-networking.md`](multitenancy-networking.md#dk-mtn-no-cross-org-peering) (“No in-stack cross-org peering”).

**Planned support session mechanism**
- A PR adds a time-bound exception object (policy exception + optional ingress)
- “Time-bound” must be enforced, not just documented:
  - exception manifests carry an explicit expiry timestamp (and owner/reference)
  - automation rejects expired exceptions (CI gate) and removes expired sessions **in Git** (scheduled cleanup PR)
  - any in-cluster cleanup loop is **alert-only unless Git is also updated**, otherwise Argo will recreate the exception
- Evidence entry documents:
  - who requested, who approved
  - scope (org/project), duration
  - what was changed and reverted

---

## 12) GitOps UX model (future UI)
Moved to `docs/design/multitenancy-gitops-ux.md` to keep this document focused on tenancy contracts.

---

## 13) Implemented today vs Planned (truth table)

### Implemented today
- GitOps boundary: Stage 0/1 bootstrap; steady-state is Argo root app `platform-apps`
  - `docs/design/gitops-operating-model.md`
- Tenant namespace label contract enforced (tenant-id == observability tenant)
  - `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-label-contract.yaml`
- Tenant namespace identity contract enforced (project-id required; identity labels DNS-label-safe + set-once immutability)
  - `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-identity-contract.yaml`
- Tenant baseline constraints are opt-in via `darksite.cloud/rbac-profile=tenant` (unlabeled namespaces can exist but are platform-owned in Phase 0)
  - `docs/design/policy-engine-and-baseline-constraints.md`
- Tenant baseline: deny-by-default + DNS allow + same-namespace allow + quotas/limits (generated)
  - `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`
- Mesh posture: STRICT mTLS (with explicit exceptions); relies on Istio auto-mTLS (no global `*.local` forcing) and is continuously proven by `Job/istio-mesh-posture-smoke`
  - `platform/gitops/components/networking/istio/mesh-security/README.md`
- Shared Istio Gateway exists; `Gateway/public-gateway` restricts route attachment via `allowedRoutes.namespaces.from: Selector` (label gate `deploykube.gitops/public-gateway=allowed`)
  - `platform/gitops/components/networking/istio/gateway/overlays/*/gateway.yaml`
- Tenant gateway pattern exists (Tier S): per-org `Gateway/istio-system/tenant-<orgId>-gateway` restricts attachments via `allowedRoutes.namespaces.from: Selector` keyed by `darksite.cloud/tenant-id=<orgId>`
  - `platform/gitops/components/networking/istio/gateway/overlays/*/gateway.yaml`
- Tenant DNS/TLS contract exists (Tier S): org-scoped workloads hostname space `*.<orgId>.workloads.<baseDomain>` with platform-managed wildcard certificates and wildcard DNS records to the tenant gateway VIP
  - `docs/design/multitenancy-networking.md#dk-mtn-ingress`
- Tenant Gateway API ingress guardrails exist (Kyverno) to prevent route hijack by default (deny `Gateway`/`ReferenceGrant`, deny tenant `HTTPRoute` attachment to `public-gateway`, require tenant `HTTPRoute` attachment to `tenant-<tenantId>-gateway`, deny cross-namespace `backendRefs`, require hostname ownership)
  - `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-ingress-gateway-api-guardrails.yaml`
- Tenant internet egress is productized (Tier S): platform-managed egress proxy + PR-authored allowlists (direct internet egress denied by default)
  - `docs/design/multitenancy-networking.md#dk-mtn-egress`
- RBAC namespace sync supports `platform`, `app`, and `tenant` profiles (tenant uses `tenant-id` + `project-id`)
  - `platform/gitops/components/shared/rbac/base/namespace-sync/configmap.yaml`
- Tenant RBAC sync hardening: scale-safe reconciliation (hash-annotated RoleBindings; skip unchanged; backoff under API pressure)
  - `platform/gitops/components/shared/rbac/base/namespace-sync/configmap.yaml`

### Planned (this design)
- Org/project Argo AppProjects and Argo RBAC extensions
- VPC concept: `vpc-id` label + Git folder contract + firewall policy model
- Kubernetes API fairness and protection:
  - API Priority & Fairness (APF) for tenant user groups to limit blast radius from noisy neighbors
- Dedicated tenancy workflow:
  - org-per-cluster GitOps layout + migration runbooks
- SupportSession-style time-bound exceptions (Git-authored)
- Per-org observability ingestion/query limits (noisy neighbor control)

---

## 14) Future: Virtual Clusters (out of scope for v1)
Virtual clusters (vcluster-like) are explicitly out of scope for this design’s implementation plan.

Tracker pointer:
- The “virtual cluster tier” is discussed as a future option in:
  `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`

We will not design policies, networking, or RBAC in a way that requires virtual clusters to exist. The model must work with:
- namespaces (shared)
- clusters (dedicated)

---

## 15) Appendix: Example tenant namespace manifest (v1)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: t-acme-p-payments-dev-app
  labels:
    darksite.cloud/rbac-profile: tenant
    darksite.cloud/tenant-id: acme
    darksite.cloud/project-id: payments
    observability.grafana.com/tenant: acme
    darksite.cloud/vpc-id: acme-main   # optional; see networking doc
```
