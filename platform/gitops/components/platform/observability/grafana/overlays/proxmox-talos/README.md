# Grafana (OIDC + Multi-Org + Correlation)

Grafana chart 10.1.4 with PVC-backed storage (`shared-rwo`). Datasources pre-wire to the in-cluster Loki/Tempo/Mimir gateways with full correlation support for the troubleshooting workflow.

External access is provided via Gateway API (`components/platform/observability/ingress`) using the shared `istio-system/public-gateway` listener `https-grafana` and TLS Secret `grafana-tls` issued by `components/certificates/ingress`.

## Datasource Correlation

Datasources are configured to enable seamless pivoting between signals:

| Datasource | Type | Correlation Features |
|------------|------|---------------------|
| `loki-platform` (`uid=lokiplatform`) | Loki | Derived fields extract `trace_id` → links to Tempo |
| `tempo-platform` (`uid=tempoplatform`) | Tempo | Trace-to-logs (Loki), Trace-to-metrics (Mimir), Service map, Node graph |
| `mimir-prometheus` (`uid=mimirprometheus`) | Prometheus | Exemplar navigation → links to Tempo traces |

Grafana datasource provisioning can fail hard on startup if datasource UIDs drift between revisions. We keep datasource names stable and explicitly delete/recreate the GitOps-managed datasources on startup via `values.yaml` (`deleteDatasources:`) so UID/name mismatches don’t brick rollouts.

### Trace → Logs
From a trace in Tempo, click "Logs for this span" to query Loki with matching `namespace`, `container`, `pod` labels.

### Logs → Trace
In Loki log lines, `trace_id` is extracted as a derived field. Click the trace ID to open the trace in Tempo.

### Metrics → Trace
In PromQL panels with exemplars enabled, click on exemplar dots to view corresponding traces.

## Dashboard Provisioning

Dashboards are provisioned as ConfigMaps under `dashboards/`:

```
grafana/dashboards/
├── kustomization.yaml
└── configmap-platform-dashboards.yaml  # Cluster overview + core metrics + VIP probes + LGTM health
```

**Adding new dashboards:**
1. Export dashboard JSON from Grafana (or create from scratch)
2. Add to `configmap-platform-dashboards.yaml` under `data:`
3. Ensure datasource UIDs match (`lokiplatform`, `tempoplatform`, `mimirprometheus`)
4. Commit and sync via Argo CD
5. Dashboard appears in the "Platform" folder

**Dashboard conventions:**
- Use `editable: false` for GitOps-managed dashboards
- Include required tags: `platform`, `<component>`
- Reference datasources by UID, not by name
- Set refresh interval appropriate for the use case

## Authentication

OIDC pulls client/URLs from `grafana-oidc` ExternalSecret (Vault path `secret/observability/grafana/oidc`) and injects env vars (`GF_AUTH_GENERIC_OAUTH_*`) instead of keeping secrets in git.

Keycloak must also have a matching OIDC client. The `deploykube-admin` realm defines `clientId: grafana` (rendered by the Keycloak bootstrap job), and the Grafana client secret is projected into the `keycloak` namespace via External Secrets so the realm template can be rendered without cross-namespace secret reads.

Grafana auto-provisions users on first successful OIDC login. If `GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP` is disabled, users will be redirected back with “Login failed / Sign up is disabled”.

**Role mapping** (from Keycloak groups):
- `dk-platform-admins` → Admin
- `dk-platform-operators` / `dk-security-ops` → Editor
- `dk-auditors` → Viewer

See `docs/design/rbac-architecture.md` for the full group model.

## Troubleshooting

### Datasource connection errors
Check that pods can reach backend services:
```bash
kubectl -n grafana exec -it deploy/grafana -- \
  wget -qO- http://loki-gateway.loki.svc.cluster.local/-/ready

kubectl -n grafana exec -it deploy/grafana -- \
  wget -qO- http://tempo.tempo.svc.cluster.local:3200/ready

kubectl -n grafana exec -it deploy/grafana -- \
  wget -qO- http://mimir-querier.mimir.svc.cluster.local:8080/ready
```

### Derived fields not working
Verify the Loki datasource has `derivedFields` configured:
```bash
kubectl -n grafana get cm grafana -o yaml | grep -A 20 derivedFields
```

Check that logs contain `trace_id` in the expected format:
- JSON: `"trace_id": "abc123..."`
- Plain: `trace_id=abc123...`

### Dashboards not appearing
1. Check ConfigMap exists: `kubectl -n grafana get cm grafana-dashboards-platform`
2. Verify mount: `kubectl -n grafana exec -it deploy/grafana -- ls /var/lib/grafana/dashboards/platform/`
3. Check Grafana logs: `kubectl -n grafana logs deploy/grafana | grep -i dashboard`

## Dev → Prod

- Promotion: keep the component identical; switch the environment app bundle/overlay.
- Verify: `platform-observability-grafana` is `Synced/Healthy`, OIDC login works, dashboards load.
- **OIDC endpoints**: Update Keycloak client redirect URIs for prod hostname.
- **Datasource headers**: Ensure `X-Scope-OrgID` matches prod tenant configuration.
