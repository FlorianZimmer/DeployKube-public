# Trivy Operator Issues

Tracks the planned in-cluster Trivy Operator component for continuous cluster-native security reports.

Design:
- `docs/design/vulnerability-scanning-and-security-reports.md`
- `docs/design/observability-lgtm-design.md`
- `docs/design/offline-bootstrap-and-oci-distribution.md`

## Open

- Add a dedicated GitOps-managed Trivy Operator component with explicit namespace, sync order, RBAC scope, and upgrade/rollback contract.
- Start with platform-namespace scope only; document how tenant namespaces are handled later so the initial rollout creates useful signal without cross-tenant report leakage.
- Make report CRDs and metrics first-class outputs:
  - `VulnerabilityReport`
  - `ConfigAuditReport`
  - exposed secret / RBAC / compliance reports where enabled
  - Prometheus metrics scraped into Mimir
- Deliver operator value through observability:
  - Grafana dashboards for vulnerability, config audit, compliance, and scan freshness
  - Alertmanager rules for operator unhealthy, report staleness, critical platform findings, and compliance regressions
  - runbooks for triage and risk acceptance
- Define retention, label strategy, and report cardinality limits so the operator remains useful at scale.
- Define the Trivy DB refresh/mirror story for the operator so it remains compatible with offline and curated-ingress deployments.

## Resolved

- None currently.
