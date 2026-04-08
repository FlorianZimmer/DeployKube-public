# Runbook: Observability smoke alerts (staleness / failure)

These alerts indicate that the platform’s observability continuous smokes are failing or not running.

## What is covered

The smokes live under `platform/gitops/components/platform/observability/smoke-tests` and include:
- Loki log write/query/delete (best-effort delete)
- Tempo trace push + search (best-effort tenant delete)
- Mimir metric push + query + tenant delete (best-effort)
- Loki ring health
- Mimir ring/memberlist health
- Alloy-metrics scrape presence (core targets appear in Mimir)
- Mimir alerting pipeline proof (rules visible + Watchdog present in Alertmanager)

## Immediate triage checklist (kubectl-only)

1) Confirm the CronJob exists and is scheduling:

```bash
kubectl -n observability get cronjob
```

2) Look at the most recent Job and pod logs for the failing smoke:

```bash
kubectl -n observability get jobs --sort-by=.metadata.creationTimestamp | tail -n 25
kubectl -n observability logs job/<job-name>
```

3) If the failure looks like “no data yet”, verify backends are healthy:

```bash
kubectl -n loki get pods
kubectl -n tempo get pods
kubectl -n mimir get pods
kubectl -n observability get pods -l app.kubernetes.io/name=alloy
kubectl -n observability get pods -l app.kubernetes.io/name=alloy-metrics
```

4) If failures correlate with network/timeouts, inspect NetworkPolicies in `observability` and the target namespaces.

## Common causes

- **Loki/Tempo eventual consistency**: queries can lag; smokes retry but may still hit tight time windows during backend restarts.
- **Ring instability**: ingesters not ACTIVE (Pending pods, resource pressure, or memberlist/DNS issues).
- **Mimir ingestion stalled**: alloy-metrics scrape presence smoke fails when remote_write cannot reach `mimir-distributor` or the apiserver proxy scraping path is broken.
- **Alerting pipeline not fully wired**: `mimir-alerting-pipeline-smoke` will fail until Ruler → Alertmanager consistently exposes firing alerts (e.g. Watchdog) via the Alertmanager API.
