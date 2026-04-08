# Runbook: Tempo query errors (`TempoQueryErrors`)

Alert meaning: Tempo query requests are failing at an elevated rate (trace search/query degraded).

## Triage (kubectl-only)

```bash
kubectl -n tempo get pods -o wide
kubectl -n tempo logs -l app.kubernetes.io/instance=tempo --tail=300 --all-containers || true
```

If errors mention object store reads/timeouts, also check Garage:

```bash
kubectl -n garage get pods -o wide
```

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/tempo/**`.

