# Runbook: Loki request errors (`LokiRequestErrors`)

Alert meaning: Loki is returning elevated 5xx errors on one or more routes.

## Triage (kubectl-only)

1) Check Loki pods and recent restarts:

```bash
kubectl -n loki get pods -o wide
```

2) Check logs for gateway/distributor/querier components that match the failing route:

```bash
kubectl -n loki logs -l app.kubernetes.io/instance=loki --tail=300 --all-containers || true
```

3) If errors mention S3/object store, check Garage health and connectivity from Loki namespaces.

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/loki/**`.
- If the issue is capacity-related, consider tuning via the deployment overlay values (GitOps).

