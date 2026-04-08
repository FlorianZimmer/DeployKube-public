# data-services-patterns design issues

Canonical issue tracker for reusable data service scaffolding patterns.

Design:
- `docs/design/data-services-patterns.md`

Related components (own their own issue trackers):
- CNPG operator: `docs/component-issues/cnpg-operator.md`
- Valkey pattern: `docs/component-issues/valkey.md`
- Postgres overlays: `docs/component-issues/postgres-keycloak.md`, `docs/component-issues/postgres-powerdns.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
- (none)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **Bases exist in-repo:** `platform/gitops/components/data/valkey/base` and `platform/gitops/components/data/postgres/base` exist as reusable patterns, and are consumed by overlays (e.g., Keycloak/PowerDNS Postgres).
- **2026-01-09 – Clarified “pattern vs component” boundaries:** documented the shared-library vs workload-owned responsibility split in `docs/design/data-services-patterns.md`.
- **2026-01-09 – Postgres NetworkPolicy posture documented:** standardized on “ingress allow-list per workload overlay, avoid CNPG default-deny egress until required flows are proven” in `docs/design/data-services-patterns.md`.
