# Workload Right-Sizing with VPA

Last updated: 2026-01-05  
Status: Implemented (platform baseline); iterating per workload

## Tracking

- Canonical tracker: `docs/component-issues/platform-ops.md`

This document describes how DeployKube uses Kubernetes **Vertical Pod Autoscaler (VPA)** to produce **CPU/memory request recommendations** from observed usage, reducing wasted reserved capacity while avoiding starvation (with a recommendations-only baseline by default).

Related:
- Resource contract (requests/limits must exist): `docs/design/resource-requests-and-limits-enforcement.md`
- Observability LGTM stack: `docs/design/observability-lgtm-design.md`
-

---

## Problem Statement

Even with correct “presence” of requests/limits, **manual sizing drifts** as workloads and usage patterns change:
- Over-requesting wastes cluster capacity (scheduler reserves resources that aren’t used).
- Under-requesting increases throttling/OOM risk and can destabilize noisy nodes.

We want a Kubernetes-native mechanism that:
- stays GitOps-friendly,
- can be opt-in per workload,
- has explicit safety bounds.

---

## Goals

1. **Reduce waste**: bring usage/request ratios closer to ~1.0 over time.
2. **Avoid starvation**: increase requests when sustained usage indicates need.
3. **Keep GitOps boundary**: configuration lives in Git; runtime request mutation is an expected, controlled behavior.
4. **Bounded behavior**: VPA must not recommend absurd values (use min/max).

---

## Non-goals

- Replacing the resource contract enforcement layer (Tier 1 still requires explicit requests/memory limits).
- Automatically changing **limits** cluster-wide (DeployKube uses VPA in `RequestsOnly` mode by default).
- Enabling automated VPA updates cluster-wide without workload-specific safety review.

---

## Design: How DeployKube Uses VPA

### 1) Install VPA controllers (cluster baseline)

DeployKube installs:
- VPA CRDs (`autoscaling.k8s.io`)
- `vpa-recommender` in `kube-system` (recommendations-only baseline)

GitOps source:
- Component: `platform/gitops/components/platform/ops/vertical-pod-autoscaler`
- Argo app: `platform/gitops/apps/base/platform-ops-vertical-pod-autoscaler.yaml`

Notes:
- DeployKube intentionally does **not** run the VPA admission-controller/updater by default to avoid automated evictions or admission-time request mutations for core services.
- VPA is still useful in this mode: it writes recommendations into the VPA object `status`, which we can inspect and dashboard.
- Grafana dashboards depend on kube-state-metrics exporting VPA recommendation metrics via custom resource state metrics (`platform/gitops/components/platform/observability/metrics`).

### 2) Opt-in per workload via `VerticalPodAutoscaler` objects

Workloads are opted in by creating namespaced `VerticalPodAutoscaler` resources that point at a `Deployment`/`StatefulSet`.

DeployKube defaults:
- `updateMode: Off` for opted-in workloads (recommendations-only; no evictions / no admission mutations).
- `controlledValues: RequestsOnly` so limits remain Git-defined.
- Explicit `minAllowed`/`maxAllowed` to keep recommendations sane.
- `istio-proxy` excluded (`mode: Off`) so sidecar sizing is not conflated with app sizing.

### 2b) Cluster-wide recommendations for long-lived workloads (GitOps inventory)

DeployKube also supports a **cluster-wide recommendations-only baseline** (still `updateMode: Off`) by shipping an explicit GitOps-managed inventory of VPA objects for long-lived controllers:

- `Deployment`
- `StatefulSet`
- `DaemonSet`

This is implemented as a dedicated component + Argo app:

- Component: `platform/gitops/components/platform/ops/vpa-recommendations`
- Argo app: `platform/gitops/apps/base/platform-ops-vpa-recommendations.yaml`

Guardrails:
- Jobs/CronJobs are not targeted (no VPA objects are generated for them).
- `istio-proxy` is excluded (`mode: Off`) so sidecar sizing is tracked separately.

### 3) Safe initial baseline still matters

VPA needs time/metrics to converge. For critical workloads we keep a conservative initial request baseline so pods start schedulable and stable before VPA learns.

---

## Implementation: Mimir Right-Sizing

Mimir is opted in via:
- `platform/gitops/components/platform/observability/mimir/overlays/dev/vpa.yaml`
- `platform/gitops/components/platform/observability/mimir/overlays/prod/vpa.yaml`

Initial ingester requests are also set explicitly to avoid a too-low starting point before VPA converges.

---

## Operations

### Inspect recommendations

```bash
kubectl -n <ns> get vpa
kubectl -n <ns> describe vpa <name>
```

### Apply recommendations (toil)

If you want to accept VPA recommendations without enabling VPA automation, use:
- `docs/toils/vpa-apply-recommendations.md`

### Dashboard recommendations

Grafana includes a “VPA Recommendations” dashboard which graphs:
- target CPU/memory recommendations per VPA/container
- VPA `updateMode` (should be `Off`)

---

## Risks / guardrails

- Avoid “maxAllowed too low”: can lock workloads into starvation. Prefer a safe ceiling and tighten once you have data.
- Treat “turning on automation” (admission-controller/updater + `updateMode: Auto`) as a higher-risk access-plane change: it can cause evictions and runtime drift in requests.
