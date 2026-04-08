# Runbook: Alloy DaemonSet not scheduled/ready (`AlloyNotScheduled`)

Alert meaning: `DaemonSet/observability/alloy` desired pods != ready pods.

## Triage (kubectl-only)

```bash
kubectl -n observability get ds alloy -o wide
kubectl -n observability describe ds alloy
kubectl -n observability get pods -l app.kubernetes.io/name=alloy -o wide
kubectl -n observability describe pod <pod>
```

Common causes:
- node taints / missing tolerations
- node selector / affinity mismatch
- insufficient resources (CPU/memory) on one or more nodes
- image pull/auth issues

## Remediation (preferred)

- Fix via GitOps (tolerations, resources, node selectors, image).
- If only a subset of nodes are impacted, focus on the failing nodes’ conditions and taints first.

