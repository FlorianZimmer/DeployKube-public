# Runbook: Pod stuck Pending (`PodPending`)

Alert meaning: a pod in `namespace/pod` remained `Pending` for an extended period (not scheduled or waiting on a dependency such as PVC binding).

## Triage (kubectl-only)

1) Describe the pod and read the scheduling events:

```bash
kubectl -n <namespace> get pod <pod> -o wide
kubectl -n <namespace> describe pod <pod>
```

Look for messages like:
- `0/… nodes are available: Insufficient cpu/memory`
- `node(s) had taint...`
- `pod has unbound immediate PersistentVolumeClaims`
- affinity/anti-affinity / topology spread failures

2) Check cluster-wide constraints quickly:

```bash
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase=Pending -o wide
```

3) If PVCs are involved:

```bash
kubectl -n <namespace> get pvc
kubectl -n <namespace> describe pvc <pvc>
```

## Remediation (preferred)

- Fix the root cause via GitOps:
  - add/adjust resource requests
  - fix node selectors/affinity/tolerations
  - provision/resize storage (or fix StorageClass/PV binding)

If this is a platform component, check the owning component README under `platform/gitops/components/**/**/README.md` for component-specific constraints.

