# Runbook: Loki ingester not ready (`LokiIngesterNotReady`)

Alert meaning: one or more Loki ingester pods are not ready for an extended period; log ingestion may be impacted.

## Triage (kubectl-only)

```bash
kubectl -n loki get pods -o wide
kubectl -n loki describe pod <pod>
kubectl -n loki logs <pod> --tail=300
```

If this correlates with storage/S3 errors, also check Garage:

```bash
kubectl -n garage get pods -o wide
```

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/loki/**`.
- See the stack overview: `platform/gitops/components/platform/observability/README.md`.

