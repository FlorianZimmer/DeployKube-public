# VPA recommendations (cluster-wide, long-lived workloads)

This component provides **recommendations-only** Vertical Pod Autoscaler (VPA) objects (`updateMode: Off`, `RequestsOnly`) for long-lived Kubernetes workload controllers:

- `Deployment`
- `StatefulSet`
- `DaemonSet`

Notes:
- Short-lived workloads (Jobs/CronJobs) are intentionally excluded.
- `mimir` is intentionally excluded here because it uses explicit, curated per-workload VPA objects in the Mimir component overlays.
- `istio-proxy` is excluded from sizing (`mode: Off`) so sidecar sizing is tracked separately from app sizing.

Source of truth:
- `vpas.yaml` is an explicit workload inventory captured from the cluster and checked into GitOps.

