# Runbook: Grafana dashboards missing kube-state-metrics data (`GrafanaDashboardsNoKubeStateMetricsData`)

Alert meaning: Mimir has no healthy `kube-state-metrics` scrapes (Grafana dashboards will show “No data”).

## Triage (kubectl-only)

1) Confirm kube-state-metrics is running:

```bash
kubectl -n observability get deploy | rg -n 'kube-state-metrics' || true
kubectl -n observability get pods | rg -n 'kube-state-metrics' || true
```

2) Confirm Alloy-metrics and Mimir are healthy:

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=alloy-metrics -o wide || true
kubectl -n mimir get pods -o wide
```

## Remediation (preferred)

- Fix via GitOps in `platform/gitops/components/platform/observability/metrics/**` and `platform/gitops/components/platform/observability/alloy-metrics/**`.
- If this also breaks CronJob staleness metrics, `GrafanaSmokeCronNotRunning` may be noisy/incorrect until kube-state-metrics recovers.

