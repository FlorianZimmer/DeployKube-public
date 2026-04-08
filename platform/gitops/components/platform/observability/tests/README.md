# Observability Smoke Tests (sync-gate / on-demand)

Wave 4 Jobs that validate core LGTM functionality using a unique temporary tenant per run.

Argo behavior:
- These Jobs run as `PostSync` hooks.
- `hook-delete-policy: BeforeHookCreation,HookSucceeded` avoids “Job spec.template is immutable” errors on re-syncs.

What each Job proves:
- `observability-log-smoke` posts a Loki stream, queries it back, then deletes it.
- `observability-trace-smoke` sends an OTLP trace to Tempo and verifies it appears via the search API. Tempo OSS lacks a guaranteed delete API, so traces are written to a temporary tenant and left for retention to prune.
- `observability-metric-smoke` runs a tiny Prometheus agent that remote_writes one scrape to the Mimir distributor, queries the series back via the querier, then calls the compactor tenant delete endpoint.

Notes:
- Loki/Tempo reads are eventually consistent; log/trace jobs retry queries for ~1 minute before failing.
- Query results should be checked in Grafana/Loki/Tempo/Mimir and captured in `docs/component-issues/observability.md`.

For continuous assurance CronJobs, see `platform/gitops/components/platform/observability/smoke-tests`.
