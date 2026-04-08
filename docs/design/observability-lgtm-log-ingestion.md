# LGTM Observability — Design #1: Log Ingestion (Loki)

_Last updated: 2025-12-15_

## Tracking

- Canonical tracker: `docs/component-issues/observability.md`

## Context
We already run an LGTM stack (Grafana + Loki + Tempo + Mimir). This document specifies the **log ingestion** contract and implementation approach so that **all platform and app workloads** emit and can query logs in Loki via Grafana, following DeployKube’s GitOps-first patterns (Istio mTLS, platform-managed internal PKI, Vault/ESO, NetworkPolicies, app-of-apps).

This doc is the log-specific deep dive. For the high-level LGTM architecture see `docs/design/observability-lgtm-design.md`.

## Goals
- Collect **stdout/stderr** logs from all Kubernetes Pods (platform + apps) with minimal operator toil.
- Provide a **low-cardinality label strategy** that supports fast queries and prevents Loki index blow-ups.
- Provide an explicit **multi-tenancy** model and `X-Scope-OrgID` policy for writes and reads.
- Keep everything **GitOps-managed** under `platform/gitops/` (with overlays for environment differences).
- Enforce **deny-by-default** NetworkPolicies and keep log transport **in-mesh** (Istio STRICT mTLS).

## Non-goals (v1)
- Application logging best-practices beyond basic requirements (covered in Design #2).
- External/public Loki ingest endpoints (v1 uses in-mesh only; external pushes remain opt-in later).
- Guaranteed lossless buffering for multi-hour Loki outages on every node (see “Failure modes”).

## Decision: Log Agent = Grafana Alloy (One Agent Per Tenant)
**Chosen:** Grafana Alloy, deployed as **one lightweight agent per tenant** with a **static** `X-Scope-OrgID` per agent.

This deliberately avoids “dynamic multi-tenancy” logic inside one giant DaemonSet config. Each tenant has a small, easy-to-reason-about Alloy config, and tenants are isolated operationally (a failure in tenant A’s agent does not block tenant B).

**Why Alloy**
- **Converges** logs + metrics + traces collection under one agent family (Alloy). In practice we run:
  - an Alloy **DaemonSet** for node-level Pod logs (and OTLP traces), and
  - a tenant-scoped Alloy **Deployment** (`alloy-metrics`) for metrics scrape + remote_write (single writer to avoid out-of-order samples).
- Native **Kubernetes discovery + metadata** enrichment and Loki pipelines (River) without maintaining separate Promtail/Fluent Bit stacks.
- Aligns with our existing component layout and current bring-up (`platform/gitops/components/platform/observability/alloy`).

**Alternatives considered**
- **Promtail**: great Loki-native log shipper, but would keep us on a logs-only agent while we still need an OTel pipeline for traces/metrics.
- **Fluent Bit**: excellent for log parsing and filesystem buffering, but adds a separate operational surface area and does not help with Tempo/Mimir ingestion.

## Deployment Model (Kubernetes)
### Per-tenant agent types
For log ingestion we distinguish between:

- **Node-level Pod logs (stdout/stderr)**: requires access to node log files ⇒ use a **DaemonSet**.
- **Application-pushed logs (optional)**: if an app sends logs over OTLP/HTTP (or writes to a shared file volume), a **sidecar** or small **Deployment** can be used, scoped to that tenant/namespace. This is opt-in and not the default for “collect every pod’s stdout”.

### Default posture (v1)
- `platform` tenant: one Alloy **DaemonSet** in `observability` with `X-Scope-OrgID=platform` that acts as the **catch-all** so every namespace gets logs by default.
- Additional tenants (e.g., `app-demo`): one Alloy **DaemonSet per tenant**, still node-level, but configured to **only keep** streams from the tenant’s namespaces and to push with `X-Scope-OrgID=<tenant>`.

When a dedicated tenant agent is enabled, the platform agent must exclude that tenant’s namespaces to avoid duplicate ingestion.

Trade-off: more Pods running (higher resource usage). Benefit: simple static configs and strong failure isolation.

### DaemonSet scheduling (baseline)
**Workload type:** `DaemonSet` (one instance per node) in namespace `observability` (one DaemonSet per tenant).

**Scheduling**
- Tolerate control-plane nodes and dedicated nodes so platform-critical logs aren’t missed.
- Keep a small footprint via requests/limits; tune per environment overlay.

**Recommended tolerations (baseline)**
- `node-role.kubernetes.io/control-plane:NoSchedule`
- `node-role.kubernetes.io/master:NoSchedule` (if present)
- “Dedicated workload” taints used in this repo (example): `<workload>=dedicated:NoSchedule`

Exact taints differ per environment; express them via overlays and keep the base permissive enough to avoid “silent log gaps”.

**Resource sizing (starting point)**
- Requests: `cpu: 100m`, `memory: 200Mi`
- Limits: `cpu: 500m`, `memory: 600Mi`

**RBAC**
- Read pod/namespace metadata for discovery/enrichment (ClusterRole with list/watch on Pods, Namespaces, Nodes as required by the Alloy Kubernetes discovery components we use).

**Where it lives in Git**
- Agent config entrypoint: `platform/gitops/components/platform/observability/alloy/values.yaml`
- Namespace + baseline NetworkPolicies: `platform/gitops/components/platform/observability/namespaces`

## Log Pipeline (Alloy → Loki)
### Sources
- Primary source: Kubernetes pod logs (container runtime logs) from the node via `loki.source.kubernetes` (or equivalent in River), enriched with Kubernetes metadata.

### Read amplification risk (multiple DaemonSets)
Because we run **one Alloy DaemonSet per tenant**, we must avoid having every agent scan and tail every file under `/var/log/pods` and then “drop later”.

**Hard requirement:** filtering must happen at the **discovery/target stage** so the agent never opens file handles for Pods it should not ingest.

Implementation guidance (River concept, not exact syntax):
- Discover Pods using the Kubernetes API.
- Apply a **discovery selector / relabel** stage that keeps only Pods in namespaces that belong to the tenant.
- Only the filtered target set is passed to `loki.source.kubernetes`.

Tenant selector contract:
- Tenant agents keep: namespaces where `observability.grafana.com/tenant == <tenant>`
- Platform catch-all keeps:
  - namespaces where `observability.grafana.com/tenant` **does not exist**, and
  - namespaces where `observability.grafana.com/tenant == platform`

This keeps per-node I/O overhead bounded even as tenant count grows, and prevents accidental duplicate ingestion (the platform agent must exclude namespaces that are served by a dedicated tenant agent).

### JSON parsing vs. “unpacking” (performance + evolvability)
**Decision:** keep the **original log line as raw JSON** (when apps log JSON) and do **query-time parsing** with LogQL (e.g., `| json`) instead of heavy ingestion-time processing.

Rationale (Loki 3.x+):
- Lower ingestion CPU and fewer surprises under load.
- Schema changes in logs do not require re-ingestion or agent config churn.
- We still extract a small set of low-cardinality labels for fast filtering.

In other words: Alloy may **extract** fields to set labels (e.g., `level`) but must not rewrite the stored log line into a different format by default.

### Parsing strategy (fields vs labels)
**Default posture:** keep most data as **query-time fields**, not labels.

- If log lines are JSON, keep the raw JSON line and use LogQL query-time parsers (`| json`) to extract fields.
- Promote to **labels only** when values are low-cardinality and useful for index filtering (e.g., `level`, `app`, `namespace`).
- Never promote per-request or per-user IDs (including `trace_id`) to labels.

### Label strategy (low-cardinality)
**Required labels (v1)**
- `cluster`: stable cluster identifier (e.g., `deploykube`).
- `namespace`: Kubernetes namespace.
- `app`: derived from `app.kubernetes.io/name` (fallbacks: `k8s-app`, workload name).
- `container`: container name.

**Allowed / recommended labels (case-by-case)**
- `level`: `debug|info|warn|error` (only if the app emits it consistently).
- `component`: stable internal subsystem label for platform apps (e.g., `controller`, `api`).
- `team`, `environment`, `tenant`: only if they are **low-cardinality and stable**.

**Explicitly disallowed labels**
- Pod UID, container ID, image digest, request ID, trace/span IDs, full pod name as primary filter (pod name can be present, but should not be required for normal queries).

**Rationale**
Loki performance depends heavily on keeping label cardinality bounded. We optimize for:
- common queries like “errors for app X in namespace Y”
- correlation via **fields** (LogQL JSON parsing) rather than indexing everything as labels

## Multi-tenancy and Authentication Model
### Onboarding policy (platform + apps)
- **Default:** logs are collected for all namespaces/workloads.
- If a namespace is not onboarded to a dedicated tenant agent, its logs land in the `platform` tenant so “it just works”.
- Teams that need isolation must:
  1) set `observability.grafana.com/tenant=<tenant-id>`, and
  2) enable the tenant’s Alloy agent (DaemonSet for stdout/stderr logs), and
  3) use the matching Grafana org/datasource pinned to `X-Scope-OrgID=<tenant-id>`.

**Orphaned / unlabeled namespaces**
- No explicit `observability.grafana.com/tenant=platform` label is required.
- The platform Alloy agent is a **catch-all** and selects namespaces where the tenant label is **missing**.

### Tenant definition
Tenant is derived from the namespace label:
- `observability.grafana.com/tenant: <tenant-id>`
- If absent: default tenant is `platform`.

This label is the **contract** for onboarding namespaces and must be documented for app teams.

### Tenant onboarding (GitOps)
Adding a new tenant requires:
1. Label the tenant namespaces with `observability.grafana.com/tenant=<tenant>`.
2. Add a tenant-specific Alloy instance (DaemonSet for node-level logs) with:
   - `X-Scope-OrgID=<tenant>` hardcoded in its Loki client config
   - stream filtering to only keep namespaces labeled for that tenant
3. Add/enable the matching Grafana org + datasource header `X-Scope-OrgID=<tenant>` (see Design #2).

### `X-Scope-OrgID` policy
- **Loki is multi-tenant** (`multitenancy_enabled: true`).
- **Writes require** `X-Scope-OrgID=<tenant-id>`.
- **Reads require** the same header and are only exposed via Grafana (v1).

### How the header is set (write path)
**Decision:** no dynamic tenant resolution in the agent.

Instead:
- Each tenant runs its own Alloy instance with a **hardcoded** `X-Scope-OrgID=<tenant>`.
- Each tenant agent only forwards logs from namespaces that belong to that tenant (filtering based on `observability.grafana.com/tenant=<tenant>` on the namespace).

To avoid read amplification, this filtering must happen before `loki.source.kubernetes` opens files (i.e., at discovery/target selection time), not after reading lines.

Hardening option (future):
- Add an in-mesh “tenant gateway” that rejects missing/invalid tenant headers and (optionally) rewrites headers based on workload identity (SA/namespace) to prevent spoofing.

### Read path enforcement
- Grafana datasources are provisioned per tenant/org and include a static `X-Scope-OrgID` header.
- Loki API stays mesh-only by default (no public HTTPRoute in v1).

## TLS + NetworkPolicy Constraints
**Transport security**
- Inside-cluster traffic is **Istio mTLS** (STRICT). Application-layer HTTPS for Loki ingest is optional and deferred (keep it in-mesh).

**NetworkPolicies (deny-by-default)**
- In `observability`: allow egress to `loki-gateway` in `loki` namespace (include both Service ports commonly encountered in-cluster, e.g. `80` and `8080`).
- In `loki`: allow ingress to gateway from `observability` (Alloy) and `grafana` namespaces.
- Allow DNS egress where required.

## Failure Modes and Backpressure
### Loki/Gateway unavailable
- Agent retries with exponential backoff and batches sends.
- If the outage exceeds local buffering capacity, logs may be dropped once node log files rotate.

**Mitigations**
- Keep label cardinality low to avoid self-inflicted backpressure.
- Alert on ingestion errors/retries and on Loki ring health.
- For “prod-like” environments, consider enabling disk-backed buffering (if/when we choose to add a buffering tier) for higher durability.

### High volume / noisy workloads
- Ensure ingestion limits are configured on Loki per tenant (rate limits, line size, burst).
- Prefer dropping/denying known-noise at the agent (namespace/container allow/deny) rather than indexing everything.

### Mis-parsing / multiline
- Multiline stack traces can cause partial events or poor searchability if not handled.
- v1 posture: keep logs single-line JSON where possible; treat multiline support as opt-in per workload.

**Opt-in mechanism (per Pod)**
- Annotation: `observability.grafana.com/multiline: "true"`
- When present, the tenant’s Alloy pipeline routes that Pod’s log stream through a `multiline` stage (e.g., “first line” regex-based).
- Optional override (future): allow a custom first-line regex via an annotation (e.g., `observability.grafana.com/multiline-firstline: "<regex>"`) for workloads with non-standard formats.

This keeps the default ingestion fast and predictable while still supporting workloads that genuinely need multiline reconstruction (Java stack traces, etc.).

## Operational Runbook
### Debug: “Logs missing in Grafana/Loki”
1. Confirm the Pod is producing logs: `kubectl -n <ns> logs <pod> -c <container> --tail=50`.
2. Confirm the tenant’s Alloy agent is running on the node hosting the Pod:
   - Identify the tenant (`platform` if no namespace tenant label is in effect).
   - `kubectl -n observability get pods -l app.kubernetes.io/name=alloy -o wide`
3. Check Alloy logs for Loki push errors/retries:
   - `kubectl -n observability logs ds/<alloy-agent-name> -c alloy --tail=200`
4. Validate network policy allows the flow:
   - `kubectl -n observability get networkpolicy`
   - `kubectl -n loki get networkpolicy`
5. Validate tenant header expectations:
   - Check namespace label `observability.grafana.com/tenant`.
   - If Loki is multi-tenant, ensure queries in Grafana use the expected tenant (datasource header).
6. Query Loki directly (in-mesh) from a debug Pod with `X-Scope-OrgID` set (see `platform/gitops/components/platform/observability/tests` for patterns).
7. If Loki returns ring/ingester errors, check Loki health and ring stability before debugging the agent.

### Onboard a namespace / app
1. Ensure the namespace exists and is mesh-enabled (per cluster policy).
2. Label the namespace with the tenant:
   - `observability.grafana.com/tenant=<tenant-id>`
3. Enable the tenant’s Alloy agent (DaemonSet for stdout/stderr logs) so logs are written with `X-Scope-OrgID=<tenant-id>`.
4. (Recommended) Ensure the app emits JSON logs with at least `level` and `msg` fields (see Design #2).
5. Verify in Grafana:
   - Filter by `namespace=<ns>` and `app=<app>`
   - Confirm results appear for the tenant datasource.

### Opt-out (exception process)
Opt-out should be rare. If needed (e.g., PII concerns), define a namespace label that the Alloy pipeline honors (e.g., `observability.grafana.com/logs=disabled`) and document it in the component README and RBAC/security docs.
