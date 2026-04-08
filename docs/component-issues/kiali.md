# Kiali Component Issues

Design:
- `docs/design/multitenancy-networking.md`
- `docs/design/observability-lgtm-design.md`

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### deferred-post-queue-6
- Renderer retirement: eliminate kustomize helmCharts: usage for Kiali and remove DeploymentConfig-hardcoded identity in overlays. (ids: `dk.ca.finding.v1:kiali:9f1995473da8c24f5a86f06c128bcd35c5c4219bed792bb0f13e4af6f186e4b8`)

### Medium

#### deferred-post-queue-6
- Provide a Prometheus instance for Istio telemetry and point external_services.prometheus.url to it so Kiali dashboards populate (likely Queue #10: Observability). (ids: `dk.ca.finding.v1:kiali:cfc26a4aac559fee618d5f1ea4327002aa6c0c222f5b76e3cda45e9c0b1c372a`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

### Notes

*None.* (Queue #6 scope complete: Kiali reachability + auth posture stabilized.)

## Deferred (post-Queue #6)
- Provide a Prometheus instance for Istio telemetry and point `external_services.prometheus.url` to it so Kiali dashboards populate (likely Queue #10: Observability).
- **Renderer retirement:** eliminate `kustomize helmCharts:` usage for Kiali and remove DeploymentConfig-hardcoded identity in overlays.
  - Target: static/vendored manifests and hostnames derived from the deployment API (controller-owned), not per-deployment rendered overlays.

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Provide a Prometheus instance for Istio telemetry and point `external_services.prometheus.url` to it so Kiali dashboards populate (likely Queue #10: Observability).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:kiali:cfc26a4aac559fee618d5f1ea4327002aa6c0c222f5b76e3cda45e9c0b1c372a", "last_seen_at": "2026-02-25", "recommendation": "Provide a Prometheus instance for Istio telemetry and point external_services.prometheus.url to it so Kiali dashboards populate (likely Queue #10: Observability).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Provide a Prometheus instance for Istio telemetry and point external_services.prometheus.url to it so Kiali dashboards populate (likely Queue #10: Observability).", "topic": "deferred-post-queue-6"}
{"class": "actionable", "details": "- **Renderer retirement:** eliminate `kustomize helmCharts:` usage for Kiali and remove DeploymentConfig-hardcoded identity in overlays.\n  - Target: static/vendored manifests and hostnames derived from the deployment API (controller-owned), not per-deployment rendered overlays.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:kiali:9f1995473da8c24f5a86f06c128bcd35c5c4219bed792bb0f13e4af6f186e4b8", "last_seen_at": "2026-02-25", "recommendation": "Renderer retirement: eliminate kustomize helmCharts: usage for Kiali and remove DeploymentConfig-hardcoded identity in overlays.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Renderer retirement: eliminate kustomize helmCharts: usage for Kiali and remove DeploymentConfig-hardcoded identity in overlays.", "topic": "deferred-post-queue-6"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved
- **2026-01-07 – OIDC auth enabled:** Kiali now uses Keycloak OIDC (`auth.strategy: openid`) with a Vault-backed client secret projected into `Secret/istio-system/kiali`.
