# DeployKube Multitenancy Networking — VPC + Firewall (GitOps-First)

<a id="dk-mtn-top"></a>

Last updated: 2026-01-20  
Status: **Design (Tier S ingress + NetworkPolicy guardrails + smokes implemented; VPC model planned)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy-networking.md`
- Related docs / constraints:
  - Multitenancy core model: [`docs/design/multitenancy.md`](multitenancy.md#dk-mt-top)
  - Label registry (contract): `docs/design/multitenancy-label-registry.md`
  - Policy engine posture: `docs/design/policy-engine-and-baseline-constraints.md`
  - GitOps boundary: `docs/design/gitops-operating-model.md`
  - Istio gateway + mesh security:
    - `platform/gitops/components/networking/istio/gateway/README.md`
    - `platform/gitops/components/networking/istio/mesh-security/README.md`

---

## MVP scope (Tier S first; do not block Tier D/H)

Queue #11 (multitenancy MVP) implements **Tier S (shared-cluster)** networking guardrails only (route hijack prevention, tenant NetPol constraints, mesh posture clarity).

Tier D/H (dedicated clusters and/or hardware separation) are explicitly out of scope for the MVP, but the networking model here must remain **portable**:
- `orgId`/`projectId` identity and hostname ownership rules must not rely on “shared cluster” specifics.
- Future dedicated clusters should be able to reuse the same tenant Git intent (VPC/firewall/ingress objects) with different target domains/gateways via overlays.

<a id="dk-mtn-goals"></a>

## 1) Goals

Networking must feel GCP-like while staying aligned to Kubernetes reality:

1. **VPC semantics**
   - A VPC provides *routing*, but traffic is only *permitted* if firewall policy allows it.

2. **Shared VPC**
   - One VPC can be used by many projects (within one org).
   - Default-deny posture remains the baseline; explicit allows are reviewable and auditable.

3. <a id="dk-mtn-no-cross-org-peering"></a> **No in-stack cross-org peering**
   - Cross-org connectivity is not solved by “internal shortcuts”.
   - If required, it must go **out of the stack** via external networking constructs + operator runbooks + evidence.

4. **GitOps-first**
   - Users request connectivity via PR-authored manifests.
   - Convergence is done by Argo; no imperative “open a firewall” actions.

5. **Explicit enforcement points**
   - Be clear about what’s enforced by:
     - Kubernetes NetworkPolicy (CNI)
     - Istio mesh policies (mTLS/authz)
     - Gateway API and route attachment controls
     - (Future) CNI-specific policy objects if needed

---

<a id="dk-mtn-repo-reality"></a>

## 2) Repo reality (implemented baseline)

### 2.1 Tenant baseline networking is deny-by-default today
Implemented via Kyverno generate policy:
- `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`

This generates into tenant namespaces:
- `NetworkPolicy tenant-default-deny` (ingress + egress deny)
- `NetworkPolicy tenant-allow-same-namespace` (intra-namespace allow)
- `NetworkPolicy tenant-allow-dns-egress` (DNS to CoreDNS only)

**Implication**: all cross-namespace, cross-project, and external connectivity must be explicitly added.

### 2.2 Istio mesh is STRICT mTLS (with exceptions)
- `platform/gitops/components/networking/istio/mesh-security/README.md`

**Implication**:
- For in-mesh traffic, mTLS is already enforced.
- Repo reality relies on Istio auto-mTLS (no mesh-wide client-side forcing of `ISTIO_MUTUAL` for `*.local`).
  - Explicit `DestinationRule tls.mode: DISABLE` is reserved for known out-of-mesh dependencies that truly require it (e.g., `kubernetes.default`, plain TCP services).
  - This keeps “in-mesh → out-of-mesh” working without per-service exception sprawl.

### 2.3 Public Gateway route attachment is platform-only (no tenant attachments by default)
- `platform/gitops/components/networking/istio/gateway/overlays/*/gateway.yaml`
  - `allowedRoutes.namespaces.from: Selector` (label gate: `deploykube.gitops/public-gateway=allowed`)

**Implication**:
- Tenant namespaces cannot attach `HTTPRoute`s to `Gateway/public-gateway` unless they can (incorrectly) mutate namespace labels to satisfy the selector.
- Tenant-scoped Gateway API guardrails (Kyverno) also deny `HTTPRoute` attachment to `public-gateway` regardless of label state.
- Tier S tenant gateway pattern exists: per-org `Gateway/istio-system/tenant-<orgId>-gateway` with `allowedRoutes.namespaces.from: Selector` keyed by `darksite.cloud/tenant-id=<orgId>`.
- Tenant `HTTPRoute` objects are admission-restricted to attach only to their org’s tenant gateway (and never `public-gateway`).

<a id="dk-mtn-tenant-workloads-vs-mesh"></a>

### 2.4 Tenant workloads vs Istio mesh (decision required before “hostile tenants”)
Repo policy posture currently assumes **tenant namespaces are not Istio-injected by default** (see baseline constraints: `docs/design/policy-engine-and-baseline-constraints.md`).

At the same time, the mesh security posture today includes:
- mesh-wide STRICT mTLS (`PeerAuthentication`)
- auto-mTLS behavior (no global `*.local` client-side forcing)

**Implication for multi-tenant ingress**:
- If tenant workloads are **out-of-mesh**, ingress/gateway proxies must be able to reach `*.svc.cluster.local` backends **without** per-service `DestinationRule tls.mode: DISABLE` sprawl.
- The shipped posture (no global `*.local` client-side forcing; rely on auto-mTLS) is intended to make “in-mesh caller → out-of-mesh backend” work by default while keeping “in-mesh ↔ in-mesh” mTLS enforced.

**Decision (2026-01-06; Tier S direction):**
1. ✅ **Rely on auto-mTLS instead of a global `*.local` client-side mTLS default**, and keep explicit `tls.mode: DISABLE` only for known out-of-mesh dependencies that truly require it.
   - Goal: “ingress gateway → out-of-mesh tenant backend” works without per-service exception sprawl.
   - **Implementation status**: shipped (global `*.local` `DestinationRule` removed; mesh posture smoke added).
   - Validation requirement: smoke proves:
     - in-mesh client → in-mesh server succeeds,
     - out-of-mesh client → in-mesh server fails (STRICT is real),
     - in-mesh client → out-of-mesh server succeeds (auto-mTLS does not force `ISTIO_MUTUAL`).

Fallback options (defer unless (1) fails validation):
2. **Make tenant workloads that use ingress “in-mesh”** (namespace injection or ambient), and keep “out-of-mesh tenants” as an explicit non-goal (or only for internal-only services not exposed via the mesh ingress). If we go here, align tenant baseline constraints to the chosen Istio data-plane mode (prefer Istio CNI/ambient over privileged init containers).
3. **Run separate Istio revision/control-plane for tenant ingress** (heavier; consider only if 1/2 fail).

---

<a id="dk-mtn-model"></a>

## 3) The model: Org, Project, VPC, and connectivity classes

### 3.1 Definitions (source of truth)
This doc assumes the core multitenancy model and label contract from [`docs/design/multitenancy.md`](multitenancy.md#dk-mt-top):
- Terminology: [“3) Terminology (GCP-like)”](multitenancy.md#dk-mt-terminology)
- Kubernetes mapping + label invariants: [“6) Kubernetes mapping (Org + Projects)”](multitenancy.md#dk-mt-k8s-mapping) (especially [“6.1 Invariants”](multitenancy.md#dk-mt-k8s-invariants) and [“6.6 Label immutability”](multitenancy.md#dk-mt-label-immutability))
- Namespace taxonomy: [“6.3 Namespace taxonomy (what namespaces exist)”](multitenancy.md#dk-mt-namespace-taxonomy)

### 3.2 Connectivity classes (what we support)
Within a single org:

1. **Same namespace**  
   - Allowed by baseline (`tenant-allow-same-namespace`)

2. **Within the same project (cross-namespace)**  
   - Default denied; allowed only if firewall rules explicitly allow

3. **Within a VPC across multiple projects (“Shared VPC”)**  
   - Routing exists, but is denied unless firewall allows

4. **VPC-to-VPC within the org (“peering-like”)**  
   - Not automatic; must be expressed and reviewed explicitly
   - Must avoid accidental broad opens

Across orgs:

5. **Cross-org connectivity**
   - **Not supported inside the stack**
   - Must go out-of-stack (VRFs/BGP/customer network), with operator runbooks and evidence

---

<a id="dk-mtn-gitops-expression"></a>

## 4) VPC representation in GitOps (decision)

### 4.1 Decision: start with labels + folder contract (no new CRDs in v1)
For v1, we represent VPC attachment via namespace labels:
- `darksite.cloud/vpc-id=<vpcId>`

And we represent “intended firewall posture” via a Git folder contract (source-of-truth and review surface), which renders to concrete allow NetworkPolicies.

Why:
- aligns with existing repo posture (labels drive policy and RBAC)
- avoids committing to long-lived CRD APIs too early
- keeps enforcement in standard Kubernetes objects (NetworkPolicy + Gateway API)

<a id="dk-mtn-folder-contract"></a>

### 4.2 Folder contract (proposed)
This is a sub-tree of the tenant GitOps contract defined in [`docs/design/multitenancy.md`](multitenancy.md#dk-mt-folder-contract) (“7.2 Recommended folder contract (Planned)”).

```
platform/gitops/tenants/<orgId>/vpcs/<vpcId>/
  README.md
  firewall/
    README.md
    allow/
      netpol-*.yaml  # v1: concrete NetworkPolicies (ingress/egress allow rules)
```

Notes:
- Kubernetes `NetworkPolicy` is additive; there is no “deny rule that overrides an allow”. For v1, keep the model to **default deny + explicit allow**.
- If we later introduce rendering/templating, add an explicit `rendered/` folder, but treat it as an implementation detail (the PR review surface remains the intent + concrete outputs).

---

<a id="dk-mtn-firewall"></a>

## 5) Firewall policy model (default deny + explicit allow)

### 5.1 Guiding rules
- Default deny is non-negotiable for tenant namespaces (already implemented)
- Allows must be:
  - specific (ports, protocols)
  - scoped (src/dst selectors)
  - auditable (Git, reviews, evidence)

### 5.2 Hierarchical firewall (recommended mental model)
Even if v1 uses raw NetworkPolicies, we structure policies as if hierarchical:

- **Org baseline**: global defaults (deny-by-default; common DNS)
- **VPC baseline**: shared defaults within that VPC (rare; keep minimal)
- **Project overlay**: project-level connectivity needs
- **Namespace overlay**: app-specific exceptions

In Kubernetes terms:
- “Hierarchy” is achieved by composing multiple NetworkPolicies (union of allows).
- We do not mutate the baseline generated policies; we add additional policies.

### 5.3 How firewall rules attach (v1)
A rule is applied by creating NetworkPolicies in the **source** namespace (egress) and/or the **destination** namespace (ingress) depending on policy direction.

Recommended v1 pattern:
- **Ingress is always explicit**:
  - destination namespace has an allow-from rule selecting destination pods
- **Egress is explicit when you want tight control**:
  - source namespace only allows egress to the specific destination pods/namespaces

This “two-sided” approach is more work, but materially reduces accidental broad openings.

### 5.4 Scale-safe NetworkPolicy authoring (approved patterns)
To avoid N² growth and “oops we opened everything” failures, standardize patterns for tenant allow policies:

- **Always scope by tenant identity labels** in `namespaceSelector`:
  - `darksite.cloud/tenant-id=<orgId>` must be present for any cross-namespace allow
  - optionally add `darksite.cloud/project-id=<projectId>` and/or `darksite.cloud/vpc-id=<vpcId>` for tighter scoping
- **Never rely on namespace names** for enforcement. Names are for humans; labels are the contract.
- **Prefer pod-level scoping**:
  - destination `podSelector` should select only the target workload pods (not “all pods in ns”)
  - prefer stable app labels (`app.kubernetes.io/name`, etc.) over ad-hoc selectors
- **Prefer ingress-allow + optional egress-allow**:
  - default is an ingress allow in the destination namespace
  - add explicit egress allows in the source namespace only when you need tight controls or when you want defense-in-depth for “shared VPC”
- **No `ipBlock` in tenant namespaces**:
  - tenant `NetworkPolicy` must not use `ipBlock` (ingress or egress)
  - external egress is via a platform-managed egress gateway/proxy (see “7) Egress control”)
- **Avoid unbounded selectors**:
  - avoid empty selectors like `namespaceSelector: {}` or `podSelector: {}`

### 5.5 Guardrails for tenant allow policies (implemented)
Enforce safe defaults for tenant-created/tenant-owned networking resources via policy and validation gates:

- **Kyverno validate policies (tenant namespaces only; Tier S safety)**
  - **Deny `ipBlock`** anywhere in tenant `NetworkPolicy` (ingress or egress): `tenant-deny-networkpolicy-ipblock`.
  - **Deny unbounded selectors** in tenant `NetworkPolicy` peers:
    - empty peers (`from/to: - {}`),
    - empty selectors (`namespaceSelector: {}`, `namespaceSelector.matchLabels: {}`),
    - cross-namespace peers without `podSelector.matchLabels` (avoid “all pods in ns”).
  - **Require identity scoping for cross-namespace allows**:
    - `namespaceSelector.matchLabels.darksite.cloud/tenant-id` must match the requesting namespace’s `darksite.cloud/tenant-id`.
    - `kubernetes.io/metadata.name` is forbidden for tenant-to-tenant scoping; only narrow platform allowlists exist:
      - `kube-system` (DNS only: `podSelector.matchLabels={k8s-app: kube-dns}`)
      - `istio-system` (Istio gateway only:
        - ingress gateway: `podSelector.matchLabels={istio: ingressgateway}`
        - tenant gateway: `podSelector.matchLabels={gateway.networking.k8s.io/gateway-name: tenant-<tenantId>-gateway}`)
      - `garage` (S3 only: `podSelector.matchLabels={app.kubernetes.io/name: garage, app.kubernetes.io/component: object-storage}`)
  - Implementation: `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-networkpolicy-guardrails.yaml`.

- **Tenant PR static gate (repo-agnostic)**
  - Tenant PR gates enforce the same NetworkPolicy constraints on rendered YAML: `shared/scripts/tenant/validate-policy-aware-lint.sh`.

- **Smoke coverage (runtime)**
  - `policy-kyverno-smoke-baseline` asserts admission denials for bad NetworkPolicies and validates tenant gateway → tenant backend connectivity end-to-end.

- **Validation gate (future)**
  - fail if a tenant namespace exceeds a maximum count of allow NetworkPolicies (prevents slow drift into unreviewable policy sprawl)
  - fail if a policy references missing/invalid tenant identity labels

---

<a id="dk-mtn-vpc-to-vpc"></a>

## 6) VPC-to-VPC connectivity within an org (“peering-like”)

### 6.1 Requirements
- Must be explicit and reviewable
- Must prevent “oops, we just opened everything”
- Must be decomposable into narrow allow rules

### 6.2 Git expression (recommended)
Represent “peering-like” intent as a small, explicit set of allowed flows, for example:

- Source: `vpcId=acme-main`, project `payments`
- Destination: `vpcId=acme-data`, project `platform`
- Allowed:
  - TCP/5432 to `postgres` service pods only
  - TCP/443 to `internal-api` pods only

In v1, this becomes:
- NetworkPolicy in `payments` namespaces allowing egress to the specific destination selectors
- NetworkPolicy in destination namespaces allowing ingress from the source selectors

### 6.3 Guardrails (planned)
To prevent accidental broad opens, enforce policy rules such as:
- disallow any `ipBlock` in tenant NetworkPolicies (all egress is via a platform-managed egress gateway/proxy)
- disallow allowing ingress from all namespaces
- disallow allowing `namespaceSelector: {}` without additional scoping labels
- require a change ticket reference and review ownership for firewall exceptions

These guardrails can be implemented via Kyverno policies scoped to tenant namespaces.

---

<a id="dk-mtn-egress"></a>

## 7) Egress control (internet + customer networks)

### 7.1 Baseline today
- Tenants can resolve DNS (CoreDNS in kube-system)
- Direct internet egress is denied by default
- Tenants only get internet egress via a platform-managed proxy, and only when explicitly allowlisted (see 7.2)

### 7.2 Internet egress (Tier S; implemented)
Tier S tenants do not get arbitrary internet egress. The only supported internet egress path is via a **platform-managed** HTTP(S) forward proxy.

Implementation (v1):
- Per org: platform-owned `Namespace/egress-<orgId>` (budget boundary).
- Per project (opt-in): a dedicated proxy `Service/egress-<orgId>/egress-proxy-p-<projectId>` on TCP/3128 (HTTP forward proxy + HTTPS CONNECT).
- Tenant request surface (PR-authored allowlist intent; Kubernetes object):
  - `tenancy.darksite.cloud/v1alpha1 TenantProject.spec.egress.httpProxy.allow[]`
  - Allow entries are `{type: exact|suffix, value: <domain>}`.
  - Absence of `spec.egress.httpProxy` means “no internet egress requested” (no proxy is created for the project).
- Tenant workload-plane authoring:
  - Tenants (or platform-owned tenant intent) create a `NetworkPolicy` allowing egress to the proxy on TCP/3128.
  - The proxy enforces allowlisted destinations and emits audit logs.

GitOps wiring:
- Component: `platform/gitops/components/networking/egress-proxy` (controller-owned; no manifests applied by Argo).
- Controller: tenant provisioner (`platform/gitops/components/platform/tenant-provisioner`) reconciles proxy resources from `TenantProject`.

Notes:
- v1 covers HTTP + HTTPS CONNECT only. Non-HTTP egress is out of scope for the v1 tenant UX.
- `ipBlock` remains denied for tenant NetworkPolicies. Any temporary `ipBlock`-based exception is breakglass-only: platform-owned, time-bound, and evidence-backed.

### 7.3 Customer network egress (out-of-stack)
If the tenant needs access to customer networks:
- Do not “peer” inside DeployKube
- Use external network demarcation and operator-run runbooks:
  - VRFs/BGP policies, customer core integration
  - evidence capture (routing policy, change records)
- In-cluster policy should still be explicit:
  - allow egress only to the customer network endpoints/gateways, not broad ranges

### 7.4 Egress gateway/proxy blast radius (must be explicit)
An egress gateway/proxy is a shared dependency and can become a **single blast radius** if not designed carefully.

Requirements (v1; implemented):
- **HA by default**:
  - each project proxy runs 2 replicas and a PDB (`minAvailable: 1`)
  - preferred anti-affinity (best-effort)
- **Per-org limits**:
  - `ResourceQuota/egress-<orgId>/egress-quota` caps proxy footprint (pods/cpu/memory)
- **Auditability**:
  - allowlist changes are PR-authored (`TenantProject.spec.egress.httpProxy.allow[]`)
  - access logs are emitted by the proxy pods; org/project identity is derived from the egress namespace and the proxy Deployment labels (and is available as log metadata in typical log pipelines)
- **Clear failure mode**:
  - if the egress proxy is down, only tenants relying on internet egress are impacted
  - failure is deny-by-default (silent allow is not acceptable)

---

<a id="dk-mtn-ingress"></a>

## 8) Ingress / external exposure (public/private) + hijack prevention

### 8.1 Current ingress architecture (repo)
- Shared Istio ingress gateway uses Gateway API.
- `public-gateway` exists with per-hostname listeners for platform services.

### 8.2 Multi-tenant ingress goals
- Tenants can expose services safely without hijacking others
- Exposure is controlled via Git PRs and policy checks
- DNS/TLS are integrated, not manual

### 8.3 Decision (Tier S default): per-org Gateway or per-org listener set
**Option 1 (selected default): per-org Gateway or per-org listener set**
- Create a Gateway per org (or per org per environment)
- Configure `allowedRoutes.namespaces.from: Selector` matching `darksite.cloud/tenant-id=<orgId>`
- Tenants can only attach routes to their org gateway

Benefits:
- strong hostname and attachment boundary
- simpler policy reasoning: “you can’t attach to what you don’t own”

Tradeoff:
- more Gateway objects/listeners (acceptable for moderate scale)

**Option 2 (defer / scale later): shared wildcard + strong policy**
- One shared gateway + wildcard listener for all tenants
- Strict policy enforces hostname ownership and prevents collisions

Tradeoff:
- policy becomes critical and must be extremely well tested

### 8.4 Preventing cross-tenant route hijacking (must-have)
Regardless of option, implement guardrails:

- Tenants must not be able to:
  - attach routes to platform gateways
  - claim hostnames outside their org zone
  - create conflicting hostnames

Concrete Tier S contract (recommended):
- **Gateway attachment boundary**:
  - platform gateway (`public-gateway`) is platform-owned only; tenant routes must never attach to it.
  - tenant routes attach only to a tenant gateway (`tenant-<orgId>-gateway`, per org/per env) or to a tenant-only shared gateway (scale option 2).
- **Hostname boundary**:
  - each org gets an org-scoped hostname space: `*.<orgId>.workloads.<baseDomain>`.
    - Note: DeployKube’s `baseDomain` is deployment-scoped and already environment-specific today (e.g. `dev.internal...`, `prod.internal...`), so we do not add a separate `<env>` label in the hostname contract.
  - Gateway listeners set `hostname` to `*.<orgId>.workloads.<baseDomain>` so out-of-zone hostnames cannot be programmed.
- **Backend reference boundary**:
  - default: `HTTPRoute.backendRefs` must remain in the same namespace (no cross-namespace backends).
  - tenants must not be able to create `ReferenceGrant` (keep the cross-namespace escape hatch closed by default).
- **Exposure boundary**:
  - tenant namespaces must not use `Service` types `NodePort` / `LoadBalancer` for direct exposure.
  - the default supported exposure mechanism is Gateway API (`HTTPRoute`) only.

Enforcement plan:
- RBAC: tenants cannot create/modify Gateways in `istio-system`
- Argo AppProject (planned): allow `HTTPRoute`, deny `Gateway` and `ReferenceGrant` for tenant repos (prevents GitOps bypass of attachment boundaries)
- Policy:
  - Implemented (Kyverno): tenant Gateway API guardrails in `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-ingress-gateway-api-guardrails.yaml`:
    - deny `Gateway` and `ReferenceGrant` in tenant namespaces
    - deny `HTTPRoute` attachment to `Gateway/public-gateway`
    - require tenant `HTTPRoute` attachment to `Gateway/istio-system/tenant-<tenantId>-gateway` (sectionName `http`/`https` when set)
    - deny cross-namespace `HTTPRoute.backendRefs`
    - enforce hostname ownership: tenant `HTTPRoute` hostnames must live under `<app>.<tenantId>.workloads.<baseDomain>`
  - Implemented (Kyverno): deny `Service` type `NodePort`/`LoadBalancer` in tenant namespaces (Tier S default) via `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-service-types.yaml`.
- Implemented (Gateway config): tenant gateways restrict `allowedRoutes` to namespaces with tenant labels (`darksite.cloud/tenant-id=<orgId>`) via the tenant provisioner controller (`components/platform/tenant-provisioner`) derived from `tenancy.darksite.cloud/v1alpha1 Tenant`.

### 8.5 DNS + TLS integration
Repo has:
- PowerDNS + ExternalDNS
- cert-manager + Step CA for the simpler internal/private issuance path, with Vault PKI implemented for external client-facing endpoints that require CRL/OCSP-backed revocation
- platform currently uses per-service TLS secrets and explicit listeners

Tenant DNS/TLS contract (Tier S; implemented):
- **Hostname space**: `<app>.<orgId>.workloads.<baseDomain>`
  - Example (dev): `api.smoke.workloads.dev.internal.example.com`
- **DNS**: platform publishes a wildcard A record per org:
  - `*.<orgId>.workloads.<baseDomain>` → the tenant gateway VIP (LoadBalancer IP for `Service/istio-system/tenant-<orgId>-gateway-istio`)
  - source of truth: `tenancy.darksite.cloud/v1alpha1 Tenant` (`spec.orgId`)
  - implementation: `components/dns/external-sync` (DNS wiring is controller-owned by `components/platform/tenant-provisioner`; tenant wildcards are auto-discovered from the Tenant API via `dns-external-sync-periodic`)
- **TLS**: platform provisions a wildcard certificate per org in `istio-system`:
  - `Certificate/istio-system/tenant-<orgId>-workloads-wildcard-tls`
  - `dnsNames`: `*.<orgId>.workloads.<baseDomain>`
  - implementation: tenant provisioner controller (`components/platform/tenant-provisioner`) (controller-owned; no repo-rendered overlay)
- **Gateway**: tenant gateways expose `http`+`https` listeners with `hostname: *.<orgId>.workloads.<baseDomain>` and terminate TLS using the wildcard cert Secret:
  - implementation: tenant provisioner controller (`components/platform/tenant-provisioner`) (controller-owned; no repo-rendered overlay)
- **Tenant route UX**:
  - Tenants publish `HTTPRoute` objects with a hostname under their org zone and attach to `Gateway/istio-system/tenant-<orgId>-gateway`.
  - Tenants do **not** create `Certificate` resources in v1; TLS is platform-managed via the wildcard cert.

Target end-state (planned and preferred):
- Retire the per-org wildcard certificate and wildcard DNS model for tenant endpoints.
- Keep endpoint TLS platform-owned, but reconcile **exact-host** DNS records and **exact-host** `Certificate` resources from tenant intent instead of granting tenants direct cert-manager access.
- The tenant route contract remains `HTTPRoute`-only; tenants still do not create `Certificate` or `Issuer` resources.
- This reduces wildcard certificate blast radius while preserving the GitOps/KRM-native control boundary.

---

<a id="dk-mtn-enforcement"></a>

## 9) Where enforcement happens (explicit)

### 9.1 Kubernetes NetworkPolicy (primary enforcement, v1)
- Implemented baseline already exists (Kyverno-generated)
- All “firewall allow” rules are additional NetworkPolicies

Why this is recommended first:
- portable
- aligns with current repo posture and docs
- easy to reason about and test

### 9.2 Istio (mTLS already enforced; L7 authz is optional)
- STRICT mTLS exists cluster-wide (with known exceptions)
- For tenant networking v1:
  - rely on NetworkPolicy for allow/deny
  - use Istio AuthorizationPolicy only when you need L7 constraints (planned)

### 9.3 Gateway API (attachment and exposure)
- Use Gateway API for ingress/exposure
- Repo reality: platform `Gateway/public-gateway` restricts route attachment via `allowedRoutes.namespaces.from: Selector` (label gate `deploykube.gitops/public-gateway=allowed`).
- Repo reality: per-org tenant gateways exist (`Gateway/istio-system/tenant-<orgId>-gateway`), with `allowedRoutes` restricted to namespaces labeled `darksite.cloud/tenant-id=<orgId>`; tenant `HTTPRoute` parentRefs are admission-restricted to the tenant gateway.
- Repo reality: tenant Gateway API guardrails (Kyverno) deny `Gateway`/`ReferenceGrant`, forbid tenant `HTTPRoute` attachment to `public-gateway`, deny cross-namespace `backendRefs`, and require hostname ownership.

### 9.4 CNI-specific policies (defer)
Cilium supports richer policy objects, but v1 should avoid them unless:
- you need features NetworkPolicy cannot provide (e.g., FQDN policies, egress gateway features)
- and you are willing to accept portability tradeoffs

Recommendation:
- start with K8s NetworkPolicy baseline + explicit allows
- later add Cilium-specific features as controlled, well-documented extensions

### 9.5 Scale mode (optional): Cilium clusterwide policy for the baseline
At higher tenant counts, “baseline per namespace” creates avoidable object churn:
- every tenant namespace gets multiple baseline NetworkPolicies
- every namespace add/remove triggers generate/reconcile activity

If we hit scale pain (budgets below), consider a “scale mode” where the **baseline** is enforced via Cilium clusterwide policies:
- `CiliumClusterwideNetworkPolicy` selects tenant namespaces by labels and enforces:
  - default deny
  - DNS allow
  - same-namespace allow

Notes:
- This reduces baseline object count and controller churn, but trades off portability.
- Keep v1 “portable mode” as the default, and treat this as an opt-in optimization with explicit evidence and smoke tests.

---

<a id="dk-mtn-evidence"></a>

## 10) Auditing and evidence

Multitenant networking must be auditable:
- Every policy change is a PR
- Evidence entries capture:
  - what was changed
  - which org/project
  - what smoke checks were run and results

Recommended evidence pattern:
- `docs/evidence/YYYY-MM-DD-tenant-networking-<orgId>-<projectId>.md`
  - include:
    - Argo status
    - policy diff summary
    - connectivity test outputs
    - (optional) Hubble flow snapshots

---

<a id="dk-mtn-smoke-tests"></a>

## 11) Smoke tests (required to claim it works)

Minimum suite (implemented for Tier S networking hardening; consistent with repo doctrine):
- Verify tenant namespace baseline netpols exist
- Verify:
  - same-namespace traffic works
  - cross-namespace traffic is denied by default
  - explicitly allowed flows work (with narrow selectors)
- Verify ingress guardrails:
  - tenant cannot attach route to platform gateway
  - tenant cannot attach routes to other tenant gateways
  - tenant cannot claim hostnames outside its tenant-id
- Verify ingress→tenant backend:
  - tenant gateway routes to an out-of-mesh backend when the tenant authors an allow NetworkPolicy (no global `*.local` client-side forcing)
- Verify egress posture:
  - DNS works
  - direct internet egress is denied by default
  - internet egress via the platform-managed egress proxy works (allowlisted host succeeds; non-allowlisted host is denied)

---

<a id="dk-mtn-budgets"></a>

## 12) Budgets + switch thresholds (required to productize)
This design needs explicit budgets so we don’t discover scalability limits by accident.

Budgets (v1; current implementation constraints):
- **Tenant shape**
  - max orgs per cluster: **10** (primary limiter: per-org tenant gateways consume LoadBalancer VIPs)
  - max projects per org: **20**
  - max tenant namespaces per org: **50**
  - max tenant namespaces per cluster: **200**
- **NetworkPolicy**
  - max tenant-authored allow NetworkPolicies per tenant namespace: **25** (excluding generated baseline)
  - max total tenant NetworkPolicy objects: **2000**
  - switch threshold: if we exceed **2000** tenant NetworkPolicies (or policy-change → dataplane > **60s** sustained), move to “scale mode” (clusterwide baseline + sparse deltas) or dedicated clusters
- **Ingress**
  - max HTTPRoutes per org: **100**
  - max HTTPRoutes per cluster: **1000**
  - max hostnames per org: **200**
  - TLS strategy: wildcard cert per org (1) + per-service certs for platform endpoints
  - switch threshold: if org count exceeds LoadBalancer VIP budget (or per-org gateway churn becomes material), switch from “per-org gateways” → “shared wildcard tenant gateway” (single LB service) with strict hostname/policy enforcement
- **DNS**
  - records per org (Tier S ingress): 1 wildcard A record `*.<orgId>.workloads.<baseDomain>` → the tenant gateway VIP
  - max ExternalDNS-managed records per cluster: **500**
  - switch threshold: if DNS propagation SLO > **60s** sustained, reduce churn (batching/debounce) or move to a dedicated controller
- **Egress**
  - opt-in per project via allowlist intent (absence of allowlist == no proxy rendered)
  - max allowlist entries per project: **50**
  - per-org egress proxy quota (enforced): `ResourceQuota/egress-<orgId>/egress-quota`:
    - `pods <= 20`
    - `requests.cpu <= 2`
    - `requests.memory <= 4Gi`
    - `limits.memory <= 8Gi`
  - switch threshold: if tenants need large allowlists / bandwidth guarantees / non-HTTP protocols, graduate to a dedicated egress gateway tier or dedicated clusters

Recommended SLOs to track (initial targets; adjust with measurement):
- Policy change → effective in dataplane: **< 60s**
- HTTPRoute merged → `Accepted/Programmed`: **< 60s**
- Certificate request → Ready: **< 10m**

Switch thresholds should be expressed in the tracker as “if we exceed X, we must move to Y” (e.g., shared gateways, clusterwide baseline policy, or dedicated clusters).

---

## 13) Blast radius and failure modes (networking-specific)
Networking is shared infrastructure; this section makes blast radius explicit:

- **Ingress misconfiguration**
  - a too-permissive `allowedRoutes` or weak hostname policy can impact multiple orgs (route hijack)
  - mitigation: separate platform vs tenant gateways, plus strict attach/hostname constraints
- **Admission/policy engine failure**
  - if Kyverno is fail-closed for tenant guardrails, a Kyverno outage can block tenant route/policy changes
  - mitigation: keep tenant guardrails tightly scoped; keep platform namespaces out of tenant guardrails; have a breakglass runbook + evidence requirements
- **Egress gateway/proxy failure**
  - shared egress can become a single point of failure or contention
  - mitigation: HA + per-org limits + clear fallback posture (deny is acceptable; silent allow is not)
- **DNS/cert control-plane overload**
  - many hostnames/certs can create churn (ExternalDNS updates, cert-manager issuance/renewals)
  - mitigation: budgets, wildcard strategy thresholds, and smoke tests that exercise the end-to-end provisioning path

---

## 14) Migration and multi-cluster considerations

### 14.1 Shared → Dedicated
Keep identifiers stable:
- orgId and projectId remain identical
- VPC and firewall intent is portable; only ingress demarcation changes (gateway IPs, DNS)

### 14.2 Multi-cluster
The same model applies per cluster:
- labels are stable
- policies are stable
- GitOps structure allows applying the same folder contract to multiple clusters (future Argo multi-destination)

---

## 15) Summary of decisions

- **Start** with:
  - labels + Git folder contract
  - NetworkPolicy as the primary firewall enforcement
  - explicit allow rules, reviewable and auditable
- **Implemented**:
  - strong ingress route hijack prevention (Gateway allowedRoutes + Kyverno constraints)
  - standardized egress proxy model (platform-managed; PR-authored allowlists)
  - explicit budgets + switch thresholds (recorded + tracked)
- **Plan**:
  - “peering-like” VPC connectivity expressed as narrow allowed flows
- **Never**:
  - provide cross-org internal peering shortcuts
  - claim shared-cluster tenancy is a hard isolation boundary
