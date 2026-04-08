# LGTM Observability Design (Grafana + Loki + Tempo + Mimir)

_Last updated: 2025-12-15_

## Tracking

- Canonical tracker: `docs/component-issues/observability.md`

## Related Design Docs
- Log ingestion deep dive: `docs/design/observability-lgtm-log-ingestion.md`
- Troubleshooting + alerting deep dive: `docs/design/observability-lgtm-troubleshooting-alerting.md`

## Goals and Scope
- Deliver a GitOps-managed, multi-tenant observability stack (metrics, logs, traces) built from Grafana, Loki, Tempo, and Mimir/Prometheus.
- Enforce tenant isolation for reads and writes by propagating `X-Scope-OrgID` (and matching Mimir/Tempo headers) from the edge to backends; tenants must only see their own logs/metrics/traces.
- Standardize on the existing platform patterns: platform-managed internal TLS, Istio mesh + Gateway API ingress, Vault/ESO for secrets, NetworkPolicies/PDBs by default, and object storage via Garage S3.
- Keep all configuration declarative under `platform/gitops/` with per-component READMEs, issue tracking, and smoke tests; avoid host scripts beyond bootstrap.

## Assumptions and Prerequisites
| Area | Requirement | Status / Notes |
| --- | --- | --- |
| Storage | Garage S3 reachable inside cluster; create buckets for `loki`, `tempo`, `mimir` with server-side encryption. **Retention deletion is owned by the apps (Loki/Mimir/Tempo compactors)**; S3 lifecycle deletion should be **disabled** or set **higher than app retention** (e.g., app=14d, S3=21d) to avoid lifecycle drift. `shared-rwo` is available for small PVs (NFS-backed in standard profiles; node-local in the single-node profile v1). | Pending confirmation per environment. |
| TLS | cert-manager is already live; current internal/private issuance uses Step CA. The Vault PKI path is implemented for external client-facing certificates that require CRL/OCSP, not for routine internal observability endpoints. Mesh defaults to STRICT mTLS; Gateway HTTPRoute slots remain available for `https-grafana`, `https-loki-api`, `https-tempo-api`, `https-prometheus-api` as needed. | Ready as current implementation; external high-assurance issuer path exists when an observability endpoint needs it. |
| Identity | Keycloak OIDC in place; group/role claims available in ID tokens. Grafana will map groups -> Orgs/Roles; Argo automation SA can create service accounts per tenant for datasources. | Ready; needs Grafana client + scopes. |
| Secrets | Vault paths for S3 credentials (`secret/observability/{loki,tempo,mimir}`), Grafana admin bootstrap, and per-tenant datasource tokens. ESO ClusterSecretStore is healthy. | To be added. |
| CRDs | Will rely on upstream Helm charts (Loki 3.x monolithic or distributed, Tempo 2.9+, Mimir 3.0+, Grafana 12.x). ServiceMonitor/PodMonitor CRDs exist via Prometheus Operator stub. | CRDs present (Prom stub already vendored). |
| Traffic Policy | Istio sidecars enabled for namespaces; need mesh egress to Garage S3 endpoint and ingress via mesh gateway. | Istio present; add namespace and egress policies. |
| Object Store Semantics | Confirm Garage behavior for Loki/Mimir workloads: `ListObjectsV2` listing patterns and HTTP range reads (blocks/chunks). Capture a dedicated smoke test as evidence. | Not yet captured as an explicit compatibility test. |

## Architecture Overview
- **Collectors / Agents**: Grafana Alloy (preferred) deployed **per tenant** with a static `X-Scope-OrgID` per workload.
  - **Logs/traces**: DaemonSet per tenant (node log access for stdout/stderr; OTLP receive for traces).
  - **Metrics**: a per-tenant **single-writer** Deployment (`alloy-metrics`) scrapes and remote_writes into Mimir to avoid duplicate/out-of-order samples from multi-replica scrapers.
  - For opt-in app-pushed telemetry, a namespace-scoped Deployment/sidecar can be used.
  This avoids complex “dynamic multi-tenancy” logic inside one giant agent config. Legacy promtail can be a fallback.
- **Logs (Loki 3.4)**: Distributed mode (ingester, querier, query-frontend, compactor, ruler, gateway). Object storage backend in Garage S3; index/cache via memcached (in-cluster, tiny size for kind). Authentication/authorization enforced by Gateway + Loki `multitenancy_enabled: true`; queries require `X-Scope-OrgID`.
- **Traces (Tempo 2.9)**: Tempo monolithic for dev, with blocks in S3; receiver protocols OTLP/HTTP+gRPC. Multi-tenancy enabled; same header enforcement as Loki. Tempo can optionally use Mimir/Memcached for metrics to power exemplars.
- **Metrics (Mimir 3.0 + Prometheus agent)**: Mimir for long-term storage + alerting rules; Prometheus Agent mode in Alloy for scraping and remote_write into Mimir with tenant header (implemented as the `alloy-metrics` Deployment). Alertmanager can be multi-tenant or shared with route-level filtering.
- **Dashboards (Grafana 12.1)**: Multi-org model; each org corresponds to a tenant. Datasources are provisioned per org with custom headers that inject `X-Scope-OrgID=<tenant>`. Login via Keycloak OIDC; roles derived from group claims (e.g., `observability-<tenant>-admin`, `observability-<tenant>-viewer`).
- **Ingress**: HTTPRoutes on the shared Istio ingress gateway terminate TLS using platform-managed certificates. Current internal/private implementation uses Step CA-backed cert-manager issuance. If a client-facing observability endpoint later requires high-assurance revocation, it should move to the separate Vault PKI-backed issuer path. Route rules forward to Grafana and per-backend gateways (or read APIs) with Envoy `requestHeadersToAdd` enforcing/overriding tenant headers where required.

## Tenancy Model
- **Write path**: Each tenant uses static `X-Scope-OrgID=<tenant>` writers:
  - `alloy` DaemonSet: logs + traces
  - `alloy-metrics` Deployment: metrics scrape + remote_write (single writer to avoid out-of-order samples)
  The platform tenant acts as a catch-all for namespaces without a tenant label. Tenant agents must filter at discovery/target stage to avoid read amplification and duplicates.
- **Read path**: Grafana datasources pinned to a single tenant via static header; users only see datasources for their org. Direct API access to Loki/Tempo/Mimir requires passing through the mesh gateway, which enforces JWT validation (Keycloak audience) and sets `X-Scope-OrgID` from the token’s tenant claim.
- **Isolation**: Per-tenant S3 prefixes, separate retention configs per tenant, NetworkPolicies that restrict backend API to Grafana + gateway, and PDBs to keep quorum during upgrades.

## Component Layout (proposed)
All paths under `platform/gitops/components/platform/observability/` with matching Argo Applications (app-of-apps entries under `platform/gitops/apps/base/`). Sync waves assume core networking/mesh/certs already exist.

| Wave | Component | Purpose |
| --- | --- | --- |
| 0.5 | `observability-namespaces` | Creates `observability`, `loki`, `tempo`, `mimir`, `grafana` namespaces with mesh labels + baseline NetworkPolicies. |
| 1 | `observability-secrets` | ESO ExternalSecrets for S3 creds, Grafana admin, tenant tokens; CA bundle ConfigMaps. |
| 1.4 | `observability-metrics` | Installs cluster exporters (`node-exporter`, `kube-state-metrics`). |
| 1.45 | `observability-alloy-metrics` | Single-writer metrics scrape + remote_write into Mimir (kubelet/cAdvisor/apiserver + exporters). |
| 1.5 | `observability-alloy` | DaemonSet for logs + traces (no metrics remote_write). |
| 2 | `observability-loki` | Loki distributed chart values, S3 config, memcached, retention, ruler, Gateway for API. |
| 2.5 | `observability-tempo` | Tempo monolithic chart values, S3 config, otlp ingress, Gateway. |
| 2.5 | `observability-mimir` | Mimir (single binary or minimal HA) with blocks in S3, Alertmanager + ruler; Gateway for query-frontend. |
| 3 | `observability-grafana` | Grafana Helm release, OIDC config, org/datasource provisioning per tenant, dashboards. |
| 3.5 | `observability-dashboards` | Folder of curated dashboards + alerting rules; links to app dashboards as they arrive. |
| 4 | `observability-tests` | Smoke jobs that push sample log/trace/metric for a test tenant and read it back via Grafana/Loki/Tempo/Mimir APIs. |

## Ingress, Security, and Policies
- **TLS**: Certificates are issued per hostname via cert-manager. Current internal/private implementation uses `ClusterIssuer/step-ca`. Vault-backed issuer resources are implemented for external client-facing endpoints that require active revocation. Certificates are stored in each namespace and referenced by HTTPRoutes/DestinationRules.
- **Mesh**: Namespaces labeled for Istio injection; PeerAuthentication remains STRICT. Allow egress to Garage S3 host via ServiceEntry and egress policy.
- **NetworkPolicies**: Deny-by-default; allow ingress from Grafana, Alloy, and gateway to Loki/Tempo/Mimir; allow health checks and monitoring as needed.
- **AuthZ**: Keycloak clients for Grafana and for direct API access. JWT claims mapped to tenant; EnvoyFilter/AuthorizationPolicy enforces claim-to-tenant mapping and rewrites `X-Scope-OrgID`.
- **Secrets**: All credentials supplied via ESO from Vault; no plaintext in Git. S3 keys stored per service/tenant; Grafana admin password stored in Vault and rotated manually.

## Storage, Retention, and Sizing (dev defaults)
- **Loki**: S3 chunks/index; 3x ingesters, 2x queriers, 1x query-frontend, 1x compactor; retention is DeploymentConfig-driven (dev: 1d, proxmox: 7d). Small PVCs (1–5 Gi) for cache where S3 latency is high.
- **Tempo**: S3 blocks; 2 replicas (HA), retention 7 days; memcached for search index cache optional.
- **Mimir**: Minimal HA must be explicit about ingester quorum:
  - Preferred (upgrade-safe): **3 ingesters** with `replication_factor=3`.
  - Dev/min-resource option: **2 ingesters** with `replication_factor=2` (less durable; documented and not used for prod-like).
  Retention 30 days; compactor enabled; remote_write from `observability-alloy-metrics` (Alloy Prometheus agent mode).
- **Grafana**: 2 replicas, `shared-rwo` PVC for sqlite/cache unless we attach Postgres later; dashboards provisioned via ConfigMaps, not DB writes.

## Observability for Observability
- ServiceMonitors/PodMonitors for all components; Loki/Tempo/Mimir expose metrics to Mimir; alerts for ingestion backpressure, query errors, ruler failures, object storage latency, and header-missing violations.
- Loki audit/logs shipped to itself with a dedicated system tenant to avoid recursion loops.

## Testing and Evidence Plan
- Argo apps must show `Synced/Healthy`.
- Smoke Jobs under `observability-tests`:
  - Write a log line with tenant `demo` via Alloy Push API; query via Loki with `X-Scope-OrgID=demo` and expect one line.
  - Emit OTLP span with tenant `demo`; retrieve via Tempo search.
  - Push a metric sample via remote_write (tenant `demo`); query via Grafana/Mimir PromQL.
- Capture outputs and attach paths in `docs/component-issues/observability.md` when created.
- Document how to obtain tokens and headers for tenants; include curl examples in component README.

## Alerting Model (decision)
- Single shared Alertmanager per environment for v1.
- Default routing must **not** fan-out platform alerts to all tenants. Default receiver is `platform-ops` only; team-specific routes are explicit (by `team` label).
- “Broadcast” alerts must be explicitly labeled (e.g., `broadcast="true"`) and routed to a dedicated receiver; no implicit tenant-wide paging.
- Future isolation: a high-security tenant can move to a dedicated Alertmanager instance (or dedicated receiver/policy boundary) if required.

## Pre-manifest Checklist (Blocking)
- **Orphaned logs**: Platform Alloy agent is a **catch-all** and must explicitly select namespaces where `observability.grafana.com/tenant` is **missing** (plus `tenant=platform`), so unlabelled namespaces are still visible without extra labeling.
- **Alert broadcast**: `broadcast="true"` is applied **in the rule definition** (Git) by platform operators. Enforce via code review and (preferred) a CI lint/policy check that rejects broadcast in non-platform rule groups.
- **Garage S3 compatibility**: The stack already uses Garage for Loki/Tempo/Mimir, but we still require a dedicated smoke test run and recorded evidence for `ListObjectsV2` + range reads and “compactor + query” behavior before we expand retention and alerting rules.

## Alloy Deployment Mode (decision)
- Default: **one Alloy agent per tenant** with a static `X-Scope-OrgID` per agent.
  - For stdout/stderr Pod logs: tenant DaemonSet(s) with node log access.
  - For opt-in app-pushed telemetry: tenant Deployment/sidecar (scoped to namespaces) is allowed.
- Benefits: small static configs, clear blast radius, avoids complex dynamic multi-tenant agent logic.

## Retention Profiles (decision)
- Implement environment profiles with Helm values overlays. If S3 lifecycle deletion is used at all, it must be a **safety net** set **higher than** the application retention (not “matching”), to avoid lifecycle drift:
  - `dev-small` (kind/laptop): Loki 3d, Tempo 2d, Mimir 7d.
  - `lab` (Proxmox/staging): Loki 7d (override to 14d allowed), Tempo 7d, Mimir 30d.
  - `prod-like` (future managed): Loki 14–30d, Tempo 7–14d, Mimir 90d with compaction/downsampling later.
- Tenants can override within bounded limits; if S3 lifecycle deletion exists it should be **>=** the app retention and is not relied upon for correctness.

## API Exposure and SSO (decision)
- v1: Tenant-facing access is via Grafana only (Keycloak OIDC). Loki/Tempo/Mimir APIs stay internal/mesh-only for Alloy, rulers, and smoke tests.
- Future: Optional HTTPRoutes (loki/tempo/mimir hostnames) with JWT validation and header rewrite to `X-Scope-OrgID` can be enabled per-tenant when needed; keep the gateway/AuthorizationPolicy pattern documented but disabled by default.
