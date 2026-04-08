# Design: Tenant API + provisioning controller (KRM-native)

Last updated: 2026-01-26  
Status: **Partially implemented (networking + Forgejo provisioning in progress)**

## Tracking

- Canonical tracker: `docs/component-issues/tenant-provisioner.md`

---

## 1) Problem statement

Tenant onboarding currently spans multiple repo surfaces and “derived outputs” (registry files, folder scaffolds, per-deployment rendered manifests, and manual/Job-driven side effects). This is workable, but it is:
- high-toil to review (many files per tenant),
- easy to drift (multiple sources of truth),
- hard to wrap in a UI safely (the UI must understand repo layout and render steps),
- fragile when onboarding requires “in-flight YAML rendering” as a prerequisite step.

If the long-term goal is a **KRM-native platform** (portable, UI-wrappable, multi-cloud friendly), tenant onboarding should be expressed as a **stable Kubernetes API**, and converged by controllers.

---

## 2) Goals / non-goals

### Goals

- **Single declarative input:** onboarding a tenant is “apply one YAML file” (multi-doc) via GitOps:
  - one `Tenant` (org-level), plus
  - one or more `TenantProject` objects (project-level).
- **No ad-hoc rendering step:** onboarding must not require running workstation/CI render scripts to generate additional YAML files.
- **Platform-only authorship:** only platform operators can author/approve `Tenant` changes; tenants must not be able to mutate tenant CRs (Git or kubectl).
- **Immediately usable:** after the `Tenant` object is reconciled, the tenant can start delivering workloads:
  - tenant namespaces exist with required labels and baseline constraints,
  - Argo boundaries and root `Application`s exist,
  - Forgejo org/repo exists and is seeded with a valid “tenant repo” skeleton,
  - tenant repo branch protections / PR gates are enforced,
  - Keycloak groups and Vault policies/stores exist for the tenant’s org/projects.

### Non-goals (for this doc)

- Replacing the Stage 0/1 bootstrap boundary (still required).
- Dedicated-cluster provisioning (Tier D/H); this design must remain compatible, but does not implement it.
- Tenant self-service to create/edit `Tenant` CRs (explicitly out of scope).
- A full “cloud provisioning” CRD suite (clusters, hardware pools, IPAM, etc.) — see idea docs for that direction.

---

## 3) Proposed API shape

### 3.1 `Tenant` CRD (v1alpha1)

We introduce a cluster-scoped CRD:
- `apiVersion: tenancy.darksite.cloud/v1alpha1`
- `kind: Tenant`

Rationale for **cluster-scoped**:
- a `Tenant` needs to own cluster-scoped objects (`Namespace`, potentially `ClusterSecretStore`, etc.),
- we want clean garbage collection via `ownerReferences` and consistent label selection.

Minimal sketch (illustrative; not a locked schema):

```yaml
apiVersion: tenancy.darksite.cloud/v1alpha1
kind: Tenant
metadata:
  name: tenant-<orgId>
spec:
  orgId: <orgId>            # DNS-label-safe, stable identifier
  description: <text>       # non-PII
  tier: S                   # S|D (future)
  lifecycle:
    retentionMode: immediate|grace|legal-hold
    deleteFromBackups: retention-only|tenant-scoped|strict-sla
  # Projects are modeled as separate TenantProject CRs (see below).
```

### 3.2 `TenantProject` CRD (v1alpha1)

We introduce a second CRD for project-level provisioning:
- `apiVersion: tenancy.darksite.cloud/v1alpha1`
- `kind: TenantProject`

`TenantProject` is also **cluster-scoped** so it can own cross-namespace/cluster-scoped objects (and so RBAC stays simple: “operators only”).

Minimal sketch (illustrative; not a locked schema):

```yaml
apiVersion: tenancy.darksite.cloud/v1alpha1
kind: TenantProject
metadata:
  name: tenant-<orgId>-p-<projectId>
spec:
  tenantRef:
    name: tenant-<orgId>
  projectId: <projectId>
  description: <text>
  environments: [dev, prod]          # overlayMode; not deploymentId

  git:
    forgejoOrg: tenant-<orgId>       # defaultable from Tenant
    repo: apps-<projectId>           # defaultable
    seedTemplate: default            # controller-defined template selector

  argo:
    mode: project-scoped             # org-scoped|project-scoped

  ingress:
    mode: tenant-gateway             # Tier S default attach point
    # hostnames derived from deployment config + orgId (see §4.1)
```

### 3.3 Multi-doc authoring (still “one file”)

Recommended authoring model for creating a new tenant is a single multi-doc YAML (one file, multiple documents):

```yaml
apiVersion: tenancy.darksite.cloud/v1alpha1
kind: Tenant
metadata:
  name: tenant-factorio
spec:
  orgId: factorio
  description: Example tenant (factorio)
  tier: S
  lifecycle:
    retentionMode: grace
    deleteFromBackups: tenant-scoped
---
apiVersion: tenancy.darksite.cloud/v1alpha1
kind: TenantProject
metadata:
  name: tenant-factorio-p-factorio
spec:
  tenantRef:
    name: tenant-factorio
  projectId: factorio
  description: Example project (factorio/factorio)
  environments: [dev]
  git:
    forgejoOrg: tenant-factorio
    repo: apps-factorio
    seedTemplate: default
  argo:
    mode: project-scoped
```

### 3.4 `status` as the UI/workflow surface

The `Tenant` and `TenantProject` objects must expose enough status for:
- operators to understand “what’s missing” without reading controller logs,
- a future UI to display “create tenant” progress without directly mutating the cluster.

Recommended patterns:
- `status.observedGeneration`
- `status.conditions[]` with crisp, documented semantics (see §6)
- `status.outputs` with stable identifiers (namespaces, repos, Argo resources) for navigation and automation.

Recommended output shape (compact + UI-friendly):

- `status.outputs` is **structured**, not a “bag of strings”.
- Each integration controller writes to its own subtree under `status.outputs.*` (to avoid write conflicts).
- The `tenant-core-controller` writes:
  - `status.outputs.resources[]`: a compact “what I created” list (for fast navigation),
  - `status.conditions` aggregation (`Ready`), and
  - `status.observedGeneration`.

Example (illustrative):

```yaml
status:
  observedGeneration: 7
  conditions:
    - type: ForgejoReady
      status: "True"
      reason: OrgAndReposReady
    - type: Ready
      status: "False"
      reason: WaitingForArgo
  outputs:
    forgejo:
      org: tenant-factorio
      repos:
        - name: apps-factorio
    argocd:
      appProjects:
        - tenant-factorio
        - tenant-factorio-p-factorio
      applications:
        - tenant-factorio-factorio
    resources:
      - apiVersion: v1
        kind: Namespace
        name: t-factorio-p-factorio-dev-app
      - apiVersion: gateway.networking.k8s.io/v1
        kind: Gateway
        namespace: istio-system
        name: tenant-factorio-gateway
```

---

## 4) Controller responsibilities (reconciliation model)

The **tenant provisioner** is a platform component (installed via GitOps) that reconciles `Tenant` and `TenantProject` objects and converges:

### 4.0 Architecture: split reconcilers (least privilege)

To avoid a “god controller”, we split reconciliation by integration. Each controller:
- runs as a separate Deployment (or Job where appropriate),
- uses a dedicated ServiceAccount + least-privilege RBAC,
- carries only the credentials it needs (e.g., Forgejo token only in the Forgejo reconciler),
- writes its own condition(s) + a compact `status.outputs` subset for its integration.

Recommended controller set (initial):
- `tenant-core-controller`: schema/semantic validation, finalizers, and “overall” aggregation.
- `tenant-namespaces-controller`: creates project/environment namespaces and required labels.
- `tenant-argo-controller`: AppProjects + Applications + Argo repo credentials.
- `tenant-forgejo-controller`: org/repo creation, seeding, branch protections.
- `tenant-keycloak-controller`: group scaffolding.
- `tenant-vault-controller`: policies + identity mappings + ESO stores (phase-gated).
- `tenant-networking-controller`: Tier S ingress attach points (Gateways) and related DNS/cert wiring.

### 4.1 In-cluster KRM resources (owned by the controller)

- **Namespaces** per project + environment:
  - create `Namespace/t-<orgId>-p-<projectId>-<env>-app` (and other standardized namespaces if the contract requires them later),
  - apply required identity labels:
    - `darksite.cloud/rbac-profile=tenant`
    - `darksite.cloud/tenant-id=<orgId>`
    - `darksite.cloud/project-id=<projectId>`
    - `observability.grafana.com/tenant=<orgId>`
  - optional behavior labels:
    - `darksite.cloud/backup-scope=enabled` (if backups are enabled for that env)

- **Argo CD boundaries**:
  - `AppProject/tenant-<orgId>` and/or `AppProject/tenant-<orgId>-p-<projectId>` (depending on `TenantProject.spec.argo.mode`)
  - `Application` objects per tenant project that sync from the tenant repo into the tenant namespace(s)

- **Repo credentials for Argo**:
  - create or reconcile Argo repository credentials (`Secret` in `argocd`) for the tenant repo(s), scoped to org/project.

- **Tier S ingress attach points (replace rendered gateway overlays)**
  - reconcile `Gateway/istio-system/tenant-<orgId>-gateway` as the platform-managed attach point
  - listener hostnames derived from:
    - tenant identity (`orgId`), and
    - deployment config (`platform.darksite.cloud/v1alpha1 DeploymentConfig`), e.g. `.spec.dns.baseDomain` (snapshot ConfigMap exists for Job consumers)
  - this must replace the current workflow of rendering per-tenant gateways into:
    - `platform/gitops/components/networking/istio/gateway/overlays/<deploymentId>/gateway.yaml`

All generated resources must be:
- labeled with `darksite.cloud/tenant-id=<orgId>` and `darksite.cloud/project-id=<projectId>` where applicable,
- owned by the `Tenant` object via `ownerReferences` (where Kubernetes allows it),
- applied via Server-Side Apply with a dedicated field manager to prevent drift and allow safe multi-writer behavior.

### 4.2 External system side effects (owned by the controller)

The controller must fully “set up the tenant” by converging external systems in a safe, idempotent way:

- **Forgejo**
  - Ensure org `tenant-<orgId>` exists.
  - Ensure repo `apps-<projectId>` exists (one repo per project, repo-per-project “product mode”).
  - Seed the repo with a valid tenant repo skeleton (kustomize base + overlays) so it is immediately usable.
  - Enforce branch protections:
    - require status check context(s) (e.g., `tenant-pr-gates`),
    - block direct pushes to protected branches (policy decision),
    - set CODEOWNERS / default branch protection posture (policy decision).

- **Keycloak**
  - Ensure tenant org/project group scaffolding exists (e.g., `dk-tenant-<orgId>-project-<projectId>-developers`, etc.).
  - Membership remains a human/IdP governance problem; the controller only ensures groups exist and are referenced consistently by downstream systems.

- **Vault / ESO**
  - Ensure tenant policies and identity mappings exist (group aliases from Keycloak groups to Vault identity groups/policies).
  - Ensure per-project scoped stores exist (e.g., `ClusterSecretStore/vault-tenant-<orgId>-project-<projectId>`) if the Phase requires it.

### 4.3 Deletion/offboarding posture

Deletion must be explicit and safe:
- use finalizers so a `Tenant` delete does not “half delete” resources,
- respect `spec.lifecycle` constraints (e.g., legal hold),
- integrate with the existing offboarding evidence/toils model (controller should not silently destroy data without an auditable trail).

This doc does not define the full offboarding semantics; it defines that the controller must participate in the lifecycle contract.

---

## 5) Platform-only authorship (tenants cannot mutate Tenant CRs)

This must be enforced as **defense-in-depth**, not just “tenants don’t have Git access”:

### 5.1 Git governance (primary workflow)
- `Tenant` manifests are authored and reviewed in the platform GitOps repo (four-eyes).
- Argo CD applies them; humans do not `kubectl apply` except breakglass with evidence.

### 5.2 Kubernetes RBAC (must enforce)
- Only platform operator/admin groups and Argo’s apply identity can `create/update/delete` the `Tenant` CR.
- Tenant human groups must have **no RBAC** granting verbs on `*.darksite.cloud` tenant APIs.

### 5.3 Admission guardrails (must enforce)
- Add a `ValidatingAdmissionPolicy` (or equivalent) that denies mutations of `Tenant` objects unless the request is from:
  - Argo CD controller identity, or
  - explicit breakglass identities.

Rationale:
- RBAC mistakes happen; admission policies ensure tenant creation is still bounded even if a RoleBinding is misapplied.

---

## 6) Readiness semantics (UI/workflow contract)

Define conditions that a UI can map to a progress bar:

Recommended placement:
- `TenantProject.status.conditions` is the primary “provisioning progress” surface (project is what becomes usable).
- `Tenant.status.conditions` is an aggregation surface (e.g., “all projects Ready”), not the primary progress log.

Recommended minimum conditions (names illustrative):
- `Accepted` — spec validated (identifier constraints, schema invariants).
- `NamespacesReady` — all namespaces exist with correct labels and are admitted by the tenant label contract policies.
- `KeycloakReady` — group scaffolding exists (org + project groups); membership is out of scope.
- `VaultReady` — policies + identity mappings exist (and per-project stores if required by the Phase).
- `ForgejoReady` — org + repo(s) exist, repo(s) are seeded with a valid skeleton, and the default branch protection posture is enforced.
- `ArgoReady` — AppProjects/Applications exist and are not rejected by Argo admission (InvalidSpec, permission denied, etc.).
- `GatewayReady` — per-tenant Gateway attach point exists and enforces namespace selectors.
- `Ready` — a summary condition meaning “all required sub-conditions are True”. It must **not** claim tenant workloads are deployed; it only asserts platform-owned prerequisites are ready.

Each condition should include:
- `reason` (stable string), and
- `message` (operator-readable), plus
- `lastTransitionTime`.

---

## 7) Migration plan (from today’s registry-driven model)

This direction should not require a flag day. A safe incremental path:

1) **Introduce the CRD + controller with no behavior change**
   - controller can be deployed, but does not own existing tenant resources yet.

2) **Compatibility phase**
   - controller reconciles `Tenant` + `TenantProject` CRs and produces a legacy “tenant registry” output (e.g., a generated `ConfigMap/*/deploykube-tenant-registry`) so existing Jobs/CronJobs remain functional.
   - avoid running render scripts as part of onboarding.

3) **Move ownership**
   - migrate one canary tenant (recommend: `factorio`) to being fully provisioned by the controller (namespaces + Argo + Forgejo + identity).
   - first “hard” win: stop rendering per-tenant Istio Gateways into deployment overlays; let the `tenant-networking-controller` own them.
   - deprecate legacy file inputs once parity is proven and evidenced.

4) **Remove legacy surfaces**
   - retire file-driven tenant registry inputs and any in-flight render steps once the controller is the sole authority.

---

## 8) Risks / tradeoffs (pushback to consider)

- **“God controller” blast radius**: a controller that can create namespaces, Argo resources, and external orgs/repos needs strong credential custody, least privilege, and auditing.
- **Loss of Git diffs for derived objects**: if the controller creates AppProjects/Applications dynamically, those resources are not directly reviewed as YAML diffs. Mitigations include:
  - a “plan” surface (status output or CLI) that previews what would be created,
  - strict, testable defaults and a minimal schema.
- **External API reliability**: Forgejo/Keycloak/Vault APIs will fail transiently; reconciliation must be idempotent, rate-limited, and observable.
- **Tight coupling to Forgejo**: owning repo creation ties the contract to a Git provider; design the integration behind an interface so future “multi-cloud Git” is possible.

This direction is still the cleanest path to a KRM-first UI and “apply a tenant” semantics, but it must be treated like building a control plane.
