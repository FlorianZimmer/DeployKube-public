# Runbook: Pod not ready (`PodNotReady`)

Alert meaning: a pod is running but not becoming ready (readiness probes failing, init not completing, or dependencies missing).

## Triage (kubectl-only)

1) Describe the pod and find the readiness gate/probe failures:

```bash
kubectl -n <namespace> get pod <pod> -o wide
kubectl -n <namespace> describe pod <pod>
```

2) Check logs for the not-ready container:

```bash
kubectl -n <namespace> logs <pod> -c <container> --tail=200
```

3) If this pod is behind a Service, verify endpoints:

```bash
kubectl -n <namespace> get svc
kubectl -n <namespace> get endpoints <service>
```

## Remediation (preferred)

- Fix dependency/config issues via GitOps (env vars, secrets, network policies, backing services).
- If readiness probe thresholds are too strict for cold start, tune via GitOps (do not hand-edit pods).

