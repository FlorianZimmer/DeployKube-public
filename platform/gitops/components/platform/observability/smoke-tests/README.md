# Observability Smoke Tests (continuous assurance)

This folder contains scheduled `CronJob`s that continuously validate core LGTM functionality using a unique temporary tenant per run:

- `observability-log-smoke` posts a Loki stream, queries it back, then best-effort deletes it.
- `observability-trace-smoke` sends an OTLP trace to Tempo and verifies it appears via the search API. Tempo OSS lacks a guaranteed delete API, so traces are written to a temporary tenant and left for retention to prune (tenant delete is best-effort).
- `observability-metric-smoke` runs a tiny Prometheus agent that `remote_write`s one scrape to Mimir, queries the series back, then best-effort calls the compactor tenant delete endpoint.
- `observability-loki-ring-smoke` validates Loki ingesters are present and ACTIVE in the ring.
- `observability-mimir-ring-smoke` validates Mimir memberlist indicates healthy membership.
- `alloy-metrics-scrape-smoke` validates the `alloy-metrics` scraper is ingesting core targets into Mimir with expected labels.
- `mimir-alerting-pipeline-smoke` validates that rules are visible and that Alertmanager reports a firing Watchdog alert (proves ruler → alertmanager pipeline).
- `observability-offenders-snapshot` queries Mimir for recent OOMKilled pods/containers and CPU throttling ratios, and writes a snapshot ConfigMap (`ConfigMap/observability-offenders-snapshot`).

Manual triggering (when you want evidence on-demand):

```bash
kubectl -n observability create job --from=cronjob/observability-log-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/observability-trace-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/observability-metric-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/observability-loki-ring-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/observability-mimir-ring-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/alloy-metrics-scrape-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/mimir-alerting-pipeline-smoke smoke-manual-$(date +%s)
kubectl -n observability create job --from=cronjob/observability-offenders-snapshot smoke-manual-$(date +%s)
```

Read the latest offenders snapshot:

```bash
kubectl -n observability get configmap observability-offenders-snapshot -o jsonpath='{.metadata.annotations.deploykube\.dev/generated-at}{"\n"}{.data.report\.txt}{"\n"}'
```

Notes:
- Loki/Tempo reads are eventually consistent; log/trace jobs retry queries for ~1 minute before failing.
- These CronJobs run in an Istio-injected namespace and use the native-sidecar exit helper so Jobs complete cleanly.
- The ring smokes intentionally target mesh-internal endpoints that fit the NetworkPolicy posture:
  - Loki ring: `http://loki-gateway.loki.svc.cluster.local/ring`
  - Mimir memberlist: `http://mimir-distributor.mimir.svc.cluster.local:8080/memberlist`
- Schedule note: CronJobs are intentionally staggered (avoid `:00`) to reduce top-of-hour API request bursts.
