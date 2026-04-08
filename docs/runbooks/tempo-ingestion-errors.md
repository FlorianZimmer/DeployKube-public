# Runbook: Tempo ingestion errors (`TempoIngestionErrors`)

Alert meaning: Tempo is reporting trace push/ingestion errors.

## Triage (kubectl-only)

```bash
kubectl -n tempo get pods -o wide
kubectl -n tempo logs -l app.kubernetes.io/instance=tempo --tail=300 --all-containers || true
kubectl -n garage get pods -o wide
```

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/tempo/**`.
- If errors are S3-related, resolve Garage or credentials projection issues first.

