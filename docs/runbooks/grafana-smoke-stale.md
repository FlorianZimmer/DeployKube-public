# Runbook: Grafana datasource smoke CronJob stale (`GrafanaSmokeCronNotRunning`)

Alert meaning: `CronJob/grafana/grafana-datasource-smoke` has not had a successful run recently.

## Triage (kubectl-only)

```bash
kubectl -n grafana get cronjob grafana-datasource-smoke -o wide
kubectl -n grafana get jobs --sort-by=.metadata.creationTimestamp | tail -n 20
kubectl -n grafana logs job/<job-name> --tail=300
```

If the alert is firing because kube-state-metrics is down (no cronjob metrics), first restore kube-state-metrics:
- `docs/runbooks/grafana-dashboards-no-kube-state-metrics-data.md`

## Remediation (preferred)

- Fix the CronJob or its dependencies via GitOps under `platform/gitops/components/platform/observability/grafana/**`.

