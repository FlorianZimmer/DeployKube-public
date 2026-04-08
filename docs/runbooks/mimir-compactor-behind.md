# Runbook: Mimir compactor behind (`MimirCompactorBehind`)

Alert meaning: Mimir compactor has not had a successful run recently (compaction/backfill may fall behind).

## Triage (kubectl-only)

```bash
kubectl -n mimir get pods -o wide
kubectl -n mimir logs -l app.kubernetes.io/component=compactor --tail=300 --all-containers || true
kubectl -n garage get pods -o wide
```

Common causes:
- object store (Garage) errors/timeouts
- compactor resource starvation
- ring/memberlist issues

## Remediation (preferred)

- Fix via GitOps (resources/values, storage connectivity) under `platform/gitops/components/platform/observability/mimir/**`.

