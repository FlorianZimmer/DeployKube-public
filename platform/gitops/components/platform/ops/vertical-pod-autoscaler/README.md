# Vertical Pod Autoscaler (VPA)

Installs the Kubernetes **Vertical Pod Autoscaler** (VPA) controllers so platform workloads can get **CPU/memory request recommendations** based on observed usage (reduce waste, reduce starvation).

This component installs:
- VPA CRDs (`autoscaling.k8s.io`)
- VPA recommender in `kube-system` (recommendations-only)

## How it works (high level)
- **Recommender** watches historical usage via metrics API (metrics-server) and produces recommendations.
- VPA objects (namespaced) opt workloads in and provide safety bounds (`minAllowed`/`maxAllowed`).

## Operating notes
- DeployKube runs VPA in **recommendations-only** mode (`updateMode: Off`): no automatic request mutations and no evictions.
- Use VPA recommendations as input for manual tuning and dashboards, or to decide where (if anywhere) automated VPA is safe.
- DeployKube tunes the recommender to:
  - avoid inflated "cold start" recommendations (lower `pod-recommendation-min-*` defaults), and
  - quantize CPU/memory recommendations (rounding) to improve bin packing.

## Upgrade/source
Vendored from upstream `kubernetes/autoscaler` tag `vertical-pod-autoscaler/v1.5.1` (`vertical-pod-autoscaler/deploy/*`). DeployKube currently applies CRDs + recommender only (no webhook/admission-controller/updater).
