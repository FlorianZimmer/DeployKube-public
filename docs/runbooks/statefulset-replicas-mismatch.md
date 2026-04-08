# Runbook: StatefulSet replicas mismatch (`StatefulSetReplicasMismatch`)

Alert meaning: a `StatefulSet` has fewer ready replicas than desired.

## Triage (kubectl-only)

```bash
kubectl -n <namespace> get sts <statefulset> -o wide
kubectl -n <namespace> describe sts <statefulset>
kubectl -n <namespace> get pods -l app=<label> -o wide
kubectl -n <namespace> get pvc
```

Common “StatefulSet-specific” causes:
- PVC not bound or volume attachment issues
- ordered startup blocked by a single ordinal
- strict anti-affinity/topology constraints

## Remediation (preferred)

- Fix via GitOps (storage class, resources, affinity/tolerations, app config).
- Avoid deleting PVCs unless the component runbook explicitly calls for it.

