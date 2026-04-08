# Runbook: Grafana dashboards missing node-exporter data (`GrafanaDashboardsNoNodeExporterData`)

Alert meaning: Mimir has no healthy `node-exporter` scrapes (Grafana dashboards will show “No data”).

## Triage (kubectl-only)

1) Confirm node-exporter is deployed and running:

```bash
kubectl -n observability get ds | rg -n 'node-exporter' || true
kubectl -n observability get pods | rg -n 'node-exporter' || true
```

2) Confirm the metrics pipeline is healthy:
- exporter → Alloy (scrape) → Mimir (remote_write)

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=alloy-metrics -o wide || true
kubectl -n mimir get pods -o wide
```

3) If pods exist but `up{job="node-exporter"}` is missing, check Alloy-metrics logs/config.

## Remediation (preferred)

- Fix via GitOps in `platform/gitops/components/platform/observability/metrics/**` and `platform/gitops/components/platform/observability/alloy-metrics/**`.
- See `platform/gitops/components/platform/observability/README.md`.

