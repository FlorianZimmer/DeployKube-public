# Resource Requests and Limits Enforcement

Last updated: 2026-01-12  
Status: Implemented (Phase 1)

This document defines how DeployKube enforces a **resource contract**: every container must declare CPU/memory **requests** and a memory **limit** (CPU limits are treated as a separate tuning concern), and operators must be able to size those values using reliable observability.

## Tracking

- Canonical tracker: `docs/component-issues/resource-contract.md`

Scope / ground truth:
- Repo-first: design is grounded in how DeployKube is operated (GitOps, Argo CD, Kyverno, VAP). It does not claim live cluster state as truth.
- Applies to both **platform** and **tenant** workloads, but with different rollout risk profiles.

Related:
- Policy engine + baseline tenant constraints: `docs/design/policy-engine-and-baseline-constraints.md`
- Access-plane guardrails / admission change discipline: `docs/design/cluster-access-contract.md`
- Validation jobs doctrine (for smokes): `docs/design/validation-jobs-doctrine.md`
- Observability stack design: `docs/design/observability-lgtm-design.md`

---

## Problem Statement

We currently have two classes of problems:

1) **Missing resources** (requests/limits absent):
- The scheduler lacks accurate placement signals (requests are effectively zero).
- CPU-based autoscaling is meaningless without CPU requests.
- Usage vs. request/limit dashboards become misleading or impossible to interpret.
- Incidents get “fixed” by removing requests (making Pods schedulable) instead of right-sizing.

2) **Mis-sized resources** (requests/limits set but nonsensical):
- Over-requested Pods reduce cluster utilization and can prevent scheduling.
- Under-requested Pods get OOMKilled or throttled.
- “Set any limit to keep it schedulable” breaks the point of having a resource contract.

### Repo constraint: Kyverno is tenant-scoped today

DeployKube runs Kyverno with **tenant-scoped admission webhooks** (see `docs/design/policy-engine-and-baseline-constraints.md`). This is an intentional safety boundary: Kyverno policies currently **do not apply to platform namespaces** unless we change webhook scope (high blast radius).

Therefore, enforcing a platform-wide resource contract requires either:
- expanding/re-architecting Kyverno scope, or
- using Kubernetes **ValidatingAdmissionPolicy (VAP)** for platform namespaces.

---

## Goals

1) **No missing resources going forward**:
   - Every `containers[]` and `initContainers[]` entry has explicit CPU/memory requests and an explicit memory limit (CPU limits are optional tuning and not required in “strict”).

2) **Safe migration** for existing workloads:
   - Introduce enforcement in warn/audit mode first, then deny.
   - Avoid bricking critical namespaces (especially `kube-system`) during the transition.

3) **Operator sizing loop**:
   - Make it easy to compare CPU/memory usage vs request/limit per workload/container.
   - Make it easy to detect “limits being hit” (OOMKills, CPU throttling).

4) **Continuous detection**:
   - Alerts and/or smoke checks detect regressions (new Pods missing resources, broken metrics pipeline).

---

## Non-goals

- Automatic right-sizing (VPA) or “perfect” tuning is **out of scope for this document**. This design enforces **presence + discipline**, not optimality. For VPA policy and usage, see `docs/design/workload-rightsizing-vpa.md`.
- Enforcing the contract in `kube-system` in Phase 1 (many system Pods are not GitOps-owned end-to-end).
- Enforcing per-container QoS class or requiring `requests == limits` everywhere.

---

## Definitions: The Resource Contract

### Tier 1 (Critical) — Deny

For every container and initContainer in a Pod:

- `resources.requests.cpu`
- `resources.requests.memory`
- `resources.limits.memory`

This tier is intended to be safe for typical burstable workloads:
- requests are needed for scheduling and meaningful autoscaling,
- memory limits prevent node-level failure amplification and make OOM behavior explicit.

### CPU limits (optional tuning)

CPU limits (`resources.limits.cpu`) are hard caps (CFS quota) and can reduce performance by throttling even when a node has idle CPU. DeployKube treats CPU limits as an explicit, workload-specific tuning choice:
- allowed (rare edge cases),
- not required by the strict contract,
- not warned on by default.

Intentionally excluded (Phase 1):
- **Ephemeral containers** (`spec.ephemeralContainers[]`): these are typically injected interactively for debugging and are not expected to be Git-managed. We treat them as a separate hardening decision (see “Open Questions”).

Optional follow-up invariants (Phase 2+ once we have data and confidence):
- Requests/limits must be non-zero and within sane bounds (policy + CI; “sane” is workload-class dependent).

Optional follow-up: enforce CPU limits only where justified:
- For specific namespaces or workload classes (explicit opt-in label), or
- Only for known “noisy neighbor” workloads.

Note: Kubernetes already enforces `requests <= limits` for CPU/memory when both are present; we don’t need a separate policy for that invariant.

---

## Options Considered

### Option A — `LimitRange` Defaults (Rejected as primary mechanism)

`LimitRange.default` / `defaultRequest` can reduce the blast radius of missing fields, but it is **not enforcement** and is dangerous as a “global fix”:

- Not retroactive: existing Pods remain non-compliant.
- Masks drift: Git manifests can remain missing resources forever while the cluster silently defaults.
- Defaults can be wildly wrong for stateful systems.
- It makes “no missing requests/limits” unprovable from Git alone.

We only consider `LimitRange` as a temporary, narrowly-scoped mitigation in specific namespaces where we intentionally accept the trade-off.

### Option B — Kyverno `validate` Policy (Viable, but requires a scope decision)

Pros:
- Great GitOps ergonomics for a full policy-as-code workflow.
- Natural exception model via `PolicyException` (with expiry discipline).

Cons in DeployKube today:
- Kyverno admission is intentionally **tenant-scoped** via webhook `namespaceSelector`.
- Making it cluster-wide would require a deliberate redesign and updating:
  - webhook scope invariants in the Kyverno smoke suite,
  - access-guardrails allow-listing for webhook configuration updates,
  - rollout/safety story for platform namespaces.

Variants:
- Expand existing Kyverno webhook scope to include platform namespaces (high blast radius).
- Run a **second Kyverno instance** dedicated to platform enforcement (more components, lower blast radius).

### Option C — Kubernetes ValidatingAdmissionPolicy (Recommended for platform)

Pros:
- Built-in, minimal dependency surface.
- Already used in DeployKube for small, high-impact invariants (e.g. tenant namespace label contract).
- Supports **Warn/Audit → Deny** rollouts.
- Can be scoped safely by `namespaceSelector` without touching Kyverno’s tenant-only boundary.

Cons:
- CEL expressions are less ergonomic than Kyverno patterns.
- No mutation, no first-class exception objects.

---

## Decision (Proposed)

1) **Platform namespaces**: enforce the resource contract via **VAP**, scoped by a dedicated namespace label (opt-in first, then expand).

2) **Tenant namespaces**: keep the existing tenant baseline intact initially; decide later whether to:
   - add a Kyverno `validate` policy for resources (fits tenant exception model), or
   - adopt the same VAP mechanism if we want one enforcement primitive everywhere.

Rationale: we get strong enforcement for platform workloads without destabilizing the tenant baseline (or widening Kyverno’s blast radius prematurely).

Tenant decision criteria (Phase 3):
- Prefer **Kyverno validate + PolicyException** if we expect high exception volume and want first-class, expiring exceptions.
- Prefer **VAP** if we want a single enforcement primitive everywhere and can keep exceptions near-zero by fixing charts/manifests.
- Note: tenant namespaces already get `tenant-default-limits` (Kyverno-generated LimitRange defaults). This is a safety net, not enforcement of “explicit resources in Git”. If we decide to enforce explicit resources for tenants, it should complement (not silently depend on) that LimitRange.

---

## Coverage (Phase 0/1)

What this design **covers** in Phase 0/1:
- **Git-managed workload Pod templates** (Deployments/StatefulSets/DaemonSets/Jobs/CronJobs): enforced by CI (Tier 1) and by admission once their namespace opts into `resource-contract=strict`.
- **Direct Pod creation** in opted-in namespaces: enforced by admission (Tier 1).
- **Regressions**: detected by runtime alerts/smokes (Tier 1) even if CI misses something.

What this design explicitly **does not cover** (Phase 0/1):
- **`kube-system` and stage0-installed system namespaces**: not opted in until proven compliant and GitOps-owned end-to-end.
- **Ephemeral containers** (`spec.ephemeralContainers[]`): excluded by design (debug/breakglass path).
- **Operator/CRD-created Pods** (e.g., CNPG database Pods): CI cannot see these via `kustomize build`. They are covered by runtime detection, and by admission only once their namespaces are opted in (which must be done carefully).

---

## Proposed Architecture (Three Layers)

### Layer 1 — Repo Validation (CI + local)

Fail PRs if rendered manifests would create Pods missing the required resource fields.

Implementation direction:
- Add a validator under `tests/scripts/` that renders each environment and extracts Pod templates from:
  - `Deployment`, `StatefulSet`, `DaemonSet`
  - `Job`, `CronJob`
  - (and any other workload kinds used in repo)
- Validate every `containers[]` and `initContainers[]` entry satisfies Tier 1 (requests + memory limit).

Important nuance (Git provability):
- The CI validator is what enforces “explicit resources in Git”.
- Admission enforcement cannot prove “explicit in Git” in namespaces where a `LimitRange` (or other mutating admission) injects defaults (e.g., tenant namespaces with `tenant-default-limits`).

Exception handling (during migration only):
- Prefer a **repo allowlist file** with explicit tuples (`namespace/kind/name/container`) and an expiry date.
- Avoid “magic annotations” that permanently encode exceptions in workload manifests.

Suggested structure:

`tests/fixtures/resource-contract-exceptions.yaml`

```yaml
# Example
- namespace: observability
  kind: DaemonSet
  name: alloy
  containers: ["alloy"] # optional; omit for all containers
  expires: "2026-02-01T00:00:00Z"
  ticket: "docs/component-issues/observability.md"
```

### Layer 2 — Cluster Admission Enforcement (Platform via VAP)

We enforce at the **Pod** level because all workload controllers eventually create Pods.

Namespace selection model (opt-in):
- Label: `darksite.cloud/resource-contract: "strict"`
- Phase 1: apply to a small, audited set of platform namespaces we own (track the exact rollout set in `docs/component-issues/policy-kyverno.md` to avoid staleness here).
- Do not enable for `kube-system` until all system components are proven compliant and GitOps-managed.

Scope clarity:
- In Phase 1, `darksite.cloud/resource-contract=strict` is intended for **platform namespaces only**.
- Do not apply it to tenant namespaces while `tenant-default-limits` defaulting is in place unless we accept that admission enforcement is about runtime safety (not “explicit in Git”) and/or we redesign tenant enforcement (Kyverno validate, CI-only, or remove defaults).

Tentative Phase 1 strict namespaces (initial opt-in):
- `grafana`, `mimir`, `loki`, `tempo`, `observability`
- Exclusions until audited: `argocd`, `vault-system`, and any namespace that mainly hosts operator-created Pods (e.g., CNPG-managed databases).

Rollout model:
- Start `validationActions: ["Warn", "Audit"]`.
- Move Tier 1 to `["Deny"]` only after the namespaces labeled `resource-contract=strict` are fully compliant.

Conceptual CEL (presence-only, no quantity math):

Tier 1 (Deny once compliant):

```cel
object.spec.containers.all(c,
  has(c.resources) &&
  has(c.resources.requests) &&
  has(c.resources.requests.cpu) &&
  has(c.resources.requests.memory) &&
  has(c.resources.limits) &&
  has(c.resources.limits.memory)
) &&
(!has(object.spec.initContainers) ||
  object.spec.initContainers.all(c,
    has(c.resources) &&
    has(c.resources.requests) &&
    has(c.resources.requests.cpu) &&
    has(c.resources.requests.memory) &&
    has(c.resources.limits) &&
    has(c.resources.limits.memory)
  )
)
```

### Layer 3 — Runtime Detection (Alerts + Optional Smoke CronJob)

Even with CI + admission, we want runtime detection for:
- regressions due to Helm chart updates / missed values,
- non-GitOps sources of Pods (breakglass, one-off testing, etc.),
- “metrics pipeline broken” scenarios (dashboards show nonsense or no data).

We add PromQL-based rules scoped to opted-in namespaces, e.g.:

- Missing CPU requests:
  - `count(kube_pod_container_info unless on(namespace,pod,container) kube_pod_container_resource_requests{resource="cpu",unit="core"})`
- Missing memory requests:
  - `count(kube_pod_container_info unless on(namespace,pod,container) kube_pod_container_resource_requests{resource="memory",unit="byte"})`
- Missing memory limits:
  - `count(kube_pod_container_info unless on(namespace,pod,container) kube_pod_container_resource_limits{resource="memory",unit="byte"})`

During Phase 0/1, an optional CronJob smoke can run the same queries and fail if counts are non-zero. Once alert routing is robust, prefer alerts over CronJobs.

---

## Implementation Sketch (GitOps)

This is the intended “where it lives” mapping once we implement the design.

### Admission (VAP)

- Add a VAP + binding under `platform/gitops/components/shared/policy-kyverno/vap/`:
  - Tier 1: core resource contract (requests + memory limit), eventually `Deny`.
- Scope the binding via `matchResources.namespaceSelector` on `darksite.cloud/resource-contract=strict`.
- Tier 1 rollout starts with `validationActions: ["Warn", "Audit"]` and moves to `["Deny"]` once compliant.
- Keep `failurePolicy: Fail` (admission should be deterministic; warnings/audit provide the safety net during rollout).
- Clarify failure mode: VAP runs **in the apiserver** (no external webhook). `failurePolicy` controls behavior on **evaluation errors**, not “webhook unavailability”.
- Access-plane discipline: VAPs/bindings are “authorization state” per `docs/design/cluster-access-contract.md` and must remain GitOps-only (Argo) or breakglass-with-evidence.
- No additional access-guardrails allow-listing is required (unlike the Kyverno webhook `caBundle` update case), because VAP resources are not expected to be mutated by in-cluster controllers.

CPU limits are intentionally not enforced by admission. If a workload needs a CPU limit, set it explicitly in that workload’s manifest/values.

### Namespace opt-in labels

- Apply `darksite.cloud/resource-contract=strict` via GitOps namespace manifests for a small set of platform namespaces first.
- Do **not** label `kube-system` (or any stage0-installed namespace) until verified compliant.

### Repo validation

- Add `tests/scripts/validate-resource-contract.sh` (name TBD) that renders each environment and checks Pod templates.
- Rendering should use `kustomize build --enable-helm` (requires Helm v3; see Kyverno doc note about Helm v4 incompatibility).
- Introduce a temporary allowlist file under `tests/fixtures/` with explicit, expiring exceptions.
- Wire the validator into CI alongside `./tests/scripts/validate-validation-jobs.sh`.

Known limitation (Phase 0/1):
- Pods created indirectly by operators from CRDs (e.g., CNPG `Cluster` → Postgres Pods) won’t appear as Pod templates in `kustomize build` output.
- These are still covered by **admission (VAP)** and **runtime detection** if they run in a `resource-contract=strict` namespace (expect warn/audit in Phase 1 if operator CRDs don’t set resources).
- Optional future enhancement: add CRD-aware checks in CI (e.g., verify CNPG `Cluster.spec.resources` is set) for the operators we use.

### Runtime detection

- Add Mimir alert rules under `platform/gitops/components/platform/observability/mimir/base/rules/`:
  - Tier 1: “missing core resource contract in strict namespaces” (counts > 0)
  - (optional) “CPU throttling elevated” and “OOMKills present” for workload sizing feedback
- Prefer alerts over CronJobs once Alertmanager routing is implemented; a CronJob smoke is still useful as a “break glass” validation during Phase 0/1.

---

## Sizing Guidance (Operator Loop)

Enforcement only helps if we can choose sensible values. The baseline loop:

1) Observe real usage (per container) over a meaningful window (e.g. 7d/30d).
2) Set **requests** to a value that makes scheduling reliable and matches typical demand.
3) Set **limits** to protect the node and cap pathological behavior without causing constant throttling/OOM.
4) Re-check after changes (new releases, new traffic patterns, new nodes).

Heuristics (starting points; refine with evidence):
- **CPU requests**: set near p95 of `rate(container_cpu_usage_seconds_total)` for the container, with headroom if bursty.
- **CPU limits**: if required, set high enough to avoid sustained throttling; if throttling becomes systemic, revisit the “CPU limits required” decision.
- **Memory requests**: set near p95 of `container_memory_working_set_bytes` (or a justified lower percentile if memory is extremely spiky and eviction risk is acceptable).
- **Memory limits**: set above expected peak with headroom; memory limits are a hard cap and should not be tight unless intentionally used as a safety brake.

Phase 0 dependency:
- This sizing loop assumes the observability stack is complete enough to provide per-container usage and “limit hit” signals (kube-state-metrics, node-exporter, and kubelet/cAdvisor metrics). See `docs/design/observability-lgtm-design.md`.

---

## Rollout Plan

### Phase 0 — Inventory + Right-Sizing

1) Inventory missing resources (per-namespace, per-workload, per-container).
2) Fix offenders in GitOps manifests/values (chart overrides, patches).
3) Ensure dashboards exist for “usage vs request/limit” and “limit hits” to make sizing non-guessy.
4) Capture evidence (Argo status + query outputs) in `docs/evidence/` and track remaining work in `docs/component-issues/`.

### Phase 1 — Add enforcement in audit/warn mode

1) Ship the VAP (warn/audit only).
2) Apply `darksite.cloud/resource-contract=strict` to a small set of platform namespaces.
3) Fix remaining non-compliant workloads until warning/audit noise is zero.
4) Add CI validation to prevent regressions.

### Phase 2 — Deny in opted-in namespaces

1) Flip `validationActions` to include `Deny`.
2) Expand the label to additional platform namespaces until all GitOps-owned platform namespaces are covered.

### Phase 3 — Extend to tenants and system namespaces (optional)

- Tenants:
  - Decide between Kyverno validate (best exception model) or VAP (one primitive everywhere).
- `kube-system` and other system namespaces:
  - Only after stage0/bootstrapped components are GitOps-owned and proven compliant.

---

## Risks and Trade-offs

- **Bricking risk**: cluster-wide deny on Pods can break critical controllers. Mitigation: opt-in namespaces + warn/audit first.
- **CPU limits trade-off**: CPU limits are hard caps (CFS quota) and can cause throttling/latency even when nodes are idle. Mitigation: default to **no CPU limits**; allow CPU limits only as an explicit, workload-specific tuning choice.
- **Exception ergonomics**: VAP lacks `PolicyException` objects. For platform namespaces we control, prefer “fix the chart” over exceptions; for tenant namespaces, Kyverno may be the better fit.

---

## Rollback Strategy

If deny enforcement causes disruption:
- Remove the `darksite.cloud/resource-contract=strict` label from the affected namespace(s), or
- Revert the VAP change in Git and resync Argo.

Any breakglass changes to admission must follow `docs/design/cluster-access-contract.md` with evidence.

---

## Decisions (As Of 2026-01-04)

- **Sanity invariants** (non-zero, bounded maxima, per-class heuristics): CI-only in Phase 0/1. If needed, add a warn-only safety net later for obviously-wrong maxima (without blocking).
- **Exception mechanism**:
  - Platform: repo allowlist with expiry (temporary).
  - Tenants: Kyverno `PolicyException` with expiry (matches existing tenant baseline discipline).
- **Tenants + LimitRange**: keep `tenant-default-limits` as a cluster-side safety net, but treat it as *not satisfying* “explicit resources in Git”. Explicitness is enforced in CI for Git-managed workloads; runtime enforcement for tenants is a Phase 3 decision (Kyverno validate recommended).
- **Ephemeral containers**: excluded from enforcement (debug/breakglass path).
- **Policy engine split**: keep VAP for platform + Kyverno for tenants; do not widen Kyverno scope (or run a second instance) in Phase 1.
