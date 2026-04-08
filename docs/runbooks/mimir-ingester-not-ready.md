# Runbook: Mimir ingester not ready (`MimirIngesterNotReady`)

Alert meaning: one or more Mimir ingester pods are not ready; metric ingestion may be impacted.

## Triage (kubectl-only)

```bash
kubectl -n mimir get pods -o wide
kubectl -n mimir describe pod <pod>
kubectl -n mimir logs <pod> --tail=300
```

If this correlates with storage/S3 errors, also check Garage:

```bash
kubectl -n garage get pods -o wide
```

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/mimir/**`.
- See the stack overview: `platform/gitops/components/platform/observability/README.md`.

