# LGTM Observability — Design #2: Troubleshooting + Alerting (Logs/Metrics/Traces)

_Last updated: 2025-12-15_

## Tracking

- Canonical tracker: `docs/component-issues/observability.md`

## Context
We already run an LGTM stack (Grafana + Loki + Tempo + Mimir). This document defines the **end-to-end operator experience** for troubleshooting and alerting so that any on-call engineer can:
- pivot **metrics → traces → logs** (and back) in Grafana
- understand and follow a consistent **application telemetry contract**
- receive actionable alerts via **Mimir Ruler → Alertmanager** with sane routing and runbook links

This doc complements:
- `docs/design/observability-lgtm-design.md` (overall architecture)
- `docs/design/observability-lgtm-log-ingestion.md` (log ingestion deep dive)

## Goals
- Make Grafana the default “single pane” for troubleshooting across platform + app workloads.
- Standardize conventions so telemetry is **correlatable** (common attributes/labels, trace context propagation, structured logs).
- Use **Prometheus-style** alert rules evaluated by **Mimir Ruler** and routed by **Alertmanager**.
- Keep dashboards, rules, and routing **GitOps-managed** (with secrets in Vault/ESO).
- Enforce multi-tenancy for reads and writes via `X-Scope-OrgID`.

## Non-goals (v1)
- Replacing team-specific APM tooling; the LGTM stack is the default baseline.
- Automated SLO generation for every service; we start with golden signals and a small curated set of alerts.
- Public access to Loki/Tempo/Mimir APIs; v1 is Grafana-first.

## Correlation Model in Grafana (Metrics ↔ Logs ↔ Traces)
### Datasource linking (provisioned, not click-ops)
Grafana must be provisioned so correlation works immediately after Argo sync:
- Tempo datasource: enable **Trace to logs** (`tracesToLogs`) pointing at the tenant’s Loki datasource.
- Loki datasource: add **derived fields** that extract `trace_id` (JSON field preferred) and link to the tenant’s Tempo datasource.
- Mimir/Prometheus datasource: enable exemplar navigation (when exemplars are present) and ensure the tenant header is applied.

In this repo, datasource provisioning starts in `platform/gitops/components/platform/observability/grafana/values.yaml` and must evolve from the single `platform` tenant to per-tenant/org provisioning.

### Identity keys (the “join columns”)
To correlate reliably, all three signal types must agree on these identifiers:
- `cluster`: which DeployKube cluster the signal originated from
- `namespace`: Kubernetes namespace
- `service.name`: stable service identifier (application-level)
- `tenant`: derived from `X-Scope-OrgID` (not a label for Loki indexing; a boundary)

### Metrics → Traces (exemplars)
Target state:
- Instrumented apps attach **exemplars** (trace IDs) to request duration histograms and/or error counters.
- Grafana panels can “View trace” directly from spikes in PromQL graphs.

Implementation note:
- Exemplars typically arrive via Prometheus scrape/remote_write; if apps emit via OpenTelemetry, the collector path must preserve exemplar IDs and map them into Prometheus samples.

### Alloy spanmetrics (OTel traces → metrics)
To improve correlation even when apps do not emit Prometheus-native metrics, Alloy can generate RED-style metrics from spans using an OpenTelemetry Collector connector (e.g., `spanmetrics`).

Design constraints:
- This is **CPU/memory intensive** on high-traffic services; enable with intent.
- Apply sampling and/or scope spanmetrics to selected namespaces/services first.
- Treat spanmetrics as a complement, not a replacement, for `/metrics` where feasible.

### Traces → Logs (trace ID in structured logs)
Required:
- Applications include `trace_id` (and ideally `span_id`) in **structured logs** for request-scoped entries.
- Grafana Loki datasource is configured with a **derived field** mapping `trace_id` → Tempo trace view.

### Logs → Traces (derived fields)
Grafana configuration should provide:
- A derived field for `trace_id` (JSON field or regex fallback) that links to Tempo with the same tenant header.
- Optional derived field for `request_id` for intra-service correlation.

## Required App Conventions (Telemetry Contract)
These conventions apply to **all platform and app workloads** unless explicitly exempted.

### 1) Metrics
**Preferred:** Prometheus exposition on `GET /metrics` (text format).

Expectations:
- A Kubernetes `Service` exposes the metrics port.
- A `ServiceMonitor`/scrape config exists (GitOps) to collect it.
- Metrics include stable labels:
  - `cluster`, `namespace`, `service`/`service_name` (or map to `service.name`)
  - avoid high-cardinality labels (request IDs, user IDs, full URLs)

Baseline service metrics (HTTP/gRPC)
- Request rate counter (e.g., `http_server_requests_total`)
- Error counter (4xx/5xx split for HTTP; status codes for gRPC)
- Latency histogram (e.g., `http_server_request_duration_seconds_bucket`)
- Saturation: CPU/memory usage is cluster-provided; apps should expose queue depths, worker pool utilization, and dependency latencies where relevant

Optional (OTel metrics pipeline):
- Apps can emit OTLP metrics to the in-cluster collector if `/metrics` is impractical, but the pipeline must still yield Prometheus-queryable series in Mimir with the same naming/labeling conventions.

### 2) Structured logging
**Required default:** one-line JSON to stdout/stderr.

Minimum required fields (recommended keys)
- `ts` (RFC3339 or epoch millis)
- `level` (`debug|info|warn|error`)
- `msg` (short message)
- `service.name` (or `service`)
- `service.version` (optional but recommended)
- `environment` (e.g., `dev|lab|prod`)

Request-scoped fields (required when a request context exists)
- `trace_id`
- `span_id` (recommended)
- `request_id` (if you already have one)
- `http.method`, `http.route` (prefer route templates over raw paths), `http.status_code`, `duration_ms`

PII posture
- Do not log secrets or PII by default; use explicit allowlists/redaction for user-facing apps.

### 3) Trace propagation + instrumentation
**Propagation standard:** W3C Trace Context (`traceparent`/`tracestate`) plus `baggage` when needed.

Expectations:
- Every incoming request starts/continues a trace (server span).
- Outbound calls propagate context (client spans).
- `service.name` is stable and matches dashboards/alerts.
- Use OpenTelemetry SDK/auto-instrumentation where feasible.

Inject trace IDs into logs:
- Use your language’s logging MDC/context mechanism to include `trace_id`/`span_id` on request logs.
- If you cannot inject globally, ensure request middleware adds the fields for all access logs.

## Golden Signals Dashboards (RED/USE)
### Cluster overview (platform-wide)
Curated dashboards should cover:
- Node health, CPU/memory/disk, filesystem pressure
- Pod restarts, CrashLoopBackOff, pending pods and scheduling constraints
- Control plane and core platform components (Istio ingress, DNS, storage)
- Loki/Mimir/Tempo health (ingestion error rates, ring/memberlist, object store latency)

### Per-service dashboards (app/team-owned)
Standardize per service on:
- **RED** (Rate, Errors, Duration) for request-driven services (HTTP/gRPC)
- **USE** (Utilization, Saturation, Errors) for resources (queues, caches, workers)

Dashboards should be treated as code and provisioned via GitOps (ConfigMaps/sidecar or Grafana provisioning), with environment overlays for dev vs prod retention and thresholds.

## Alerting Strategy (Mimir Ruler → Alertmanager)
### Principles
- Alerts must be **actionable** and link to a **runbook**.
- Prefer SLO-ish symptom alerts over noisy cause alerts; keep cause alerts to a small, curated set.
- Multi-tenancy: all rule evaluations and notifications must preserve the tenant boundary.

### Rule lifecycle (GitOps)
**Source of truth:** Git (this repo), under the observability component.

Proposed repo layout:
- Rules: `platform/gitops/components/platform/observability/mimir/base/rules/<tenant>/<group>.yaml`
- Alertmanager routing: `platform/gitops/components/platform/observability/mimir/alertmanager/`
- Example rules and docs live next to the manifests and are referenced from component READMEs.

Validation (local/CI future):
- Lint Prometheus rules (`promtool check rules`) and Alertmanager config (`amtool check-config`) before merge.
- Tenant label/header checks: enforce required labels and forbid high-cardinality labels in rule selectors.

Rollout mechanics:
- Use GitOps to deploy a sync Job/controller that applies rule groups to Mimir Ruler (via API or mounted rule files, depending on the chosen Mimir configuration).
- Changing a rule is a normal Git PR → Argo sync → ruler reload/sync → alert behavior change is auditable.

### Alert label conventions
All alerts must include:
- `severity`: `critical|warning|info`
- `service`: service identifier (matches `service.name`)
- `team`: owning team (used for routing)
- `environment`: `dev|lab|prod`
- `cluster`: cluster identifier
- `runbook_url`: URL/relative path to the runbook (e.g., docs path or external wiki)
Tenant handling:
- Prefer tenant isolation via `X-Scope-OrgID` boundaries (Grafana datasources, Mimir tenancy) rather than relying on a free-form `tenant` label.
- Only include a `tenant` label when a shared pipeline requires it for routing/debugging (and keep it low-cardinality).

### Routing policy (team-based)
Top-level routing:
- Group by `[team, service, severity, cluster]` to avoid alert storms.
- **Default route** goes to `platform-ops` only.
- Team routes override for app teams (e.g., `team=app-demo`) and must be explicit.

Fan-out policy (avoid spamming tenants):
- A platform alert does **not** broadcast to all tenants by default.
- “Broadcast” alerts must set an explicit label (e.g., `broadcast="true"`) and are routed to a dedicated receiver that pages the platform on-call (and optionally sends FYI email to tenant lists). No implicit tenant-wide paging.

Who applies `broadcast="true"`:
- **Rule level (Git):** the label is set in the alert rule YAML by platform operators when the alert is truly global.
- Enforcement: require code review + (preferred) a repo policy check that rejects broadcast labels outside platform-owned rule groups. We do not rely on runtime relabeling to “add” broadcast.

Inhibition/silencing:
- Inhibit `warning` when a `critical` alert for the same `service` is firing.
- Provide a documented silence policy (who can silence, max duration, required comment format).

## Notification Channels
### Email (SMTP)
- Alertmanager sends email using SMTP credentials stored in Vault and projected via ESO.
- Credentials must be reloadable without hand-editing pods (config reloader or controlled restart).

### Primary escalation: PagerDuty
**Chosen primary:** PagerDuty (phone/SMS handled by PagerDuty).

Rationale:
- Widely adopted on-call workflow with schedules/escalations managed outside the cluster.
- Keeps the cluster responsible only for creating high-signal incidents, not paging logic.

Optional support:
- Provide an Opsgenie receiver as a secondary option if needed, but keep PagerDuty as the default integration to reduce branching.

Secrets handling:
- Integration keys live in Vault (ESO projects into Kubernetes).
- Alertmanager config must be reloadable safely when keys rotate.

### Safe reload / rotation procedure (GitOps-friendly)
Target workflow for changing notification endpoints or rotating keys:
1. Update the relevant Vault secret (SMTP password, PagerDuty integration key).
2. ESO reconciles the Kubernetes Secret (no manual `kubectl edit`).
3. A config-reloader mechanism triggers Alertmanager to pick up the change:
   - preferred: a sidecar/operator that watches the mounted Secret/Config and calls `/-/reload`
   - acceptable fallback: a GitOps-driven rollout triggered by a checksum annotation on the Deployment/StatefulSet

This keeps the live system convergent with Git/Vault state and avoids hand edits in running Pods.

## RBAC / Access Model (Troubleshooting End-to-End)
### Grafana access
- Grafana uses Keycloak OIDC.
- Tenants map to Grafana Orgs (or equivalent isolation boundary).
- Group-to-role mapping should follow the project’s RBAC conventions (`docs/design/rbac-architecture.md`), e.g.:
  - `dk-observability-<tenant>-admins` → Grafana Org Admin
  - `dk-observability-<tenant>-editors` → Editor
  - `dk-observability-<tenant>-viewers` → Viewer

### Data access boundaries
- Loki/Tempo/Mimir datasources are provisioned per Org and pinned to the tenant via `X-Scope-OrgID`.
- Agents/collectors write with a static `X-Scope-OrgID` per tenant agent (one-agent-per-tenant pattern) to keep write isolation simple.
- Direct API access to Loki/Tempo/Mimir remains mesh-only and is not required for normal troubleshooting.
- Rule/route management is restricted to platform operators (GitOps workflow), not done in Grafana UI.

## Operator Workflow (happy path)
1. **Alert fires** (Mimir Ruler) → routed in Alertmanager → email + PagerDuty incident.
2. On-call opens the linked **dashboard** (Grafana) and checks RED/USE panels.
3. From a metric spike panel, pivot to **exemplars/traces** (Tempo) when available.
4. From traces, pivot to **logs** (Loki) using `trace_id` derived fields.
5. Apply remediation from the linked **runbook**; then confirm recovery and close incident.
