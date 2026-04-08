# egress-proxy component issues

Canonical issue tracker for:
- `platform/gitops/components/networking/egress-proxy`

Design:
- `docs/design/multitenancy-networking.md`
- `docs/design/tenant-provisioning-controller.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
#### documentation-coverage-and-freshness
- **[low]** API docs index doesn’t point to the TenantProject egress proxy contract used by the component (ids: `dk.ca.finding.v1:egress-proxy:d115b61e22059c4a6f2bfb2ac1cccf9af1ff6e07be353134ee1026e1dac37188`). Add a short “TenantProject egress proxy” section to `docs/apis/tenancy/tenancy.darksite.cloud/README.md` that links to the contract entrypoint (`platform/gitops/components/networking/egress-proxy/README.md`) and names key fields like `TenantProject.spec.egress.httpProxy.allow[]` for discoverability.
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "", "evidence": [{"key": "tenancy.darksite.cloud/v1alpha1 TenantProject.spec.egress.httpProxy.allow[]", "path": "platform/gitops/components/networking/egress-proxy/README.md", "resource": "TenantProject egress allowlist contract"}, {"key": "tenant-egress-proxy-controller reconciles TenantProject \u2192 egress proxy namespace/service + policy", "path": "docs/apis/tenancy/tenancy.darksite.cloud/README.md", "resource": "Controller listing"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:egress-proxy:d115b61e22059c4a6f2bfb2ac1cccf9af1ff6e07be353134ee1026e1dac37188", "last_seen_at": "2026-02-25", "recommendation": "In `docs/apis/tenancy/tenancy.darksite.cloud/README.md`, add a short TenantProject egress proxy section that at least links to the contract entrypoint and names the key fields (e.g., `TenantProject.spec.egress.httpProxy.allow[]`) so operators can discover it from the API docs index.", "risk": "", "severity": "low", "status": "open", "template_id": "operational-10-documentation-coverage-and-freshness.md", "title": "API group README doesn\u2019t point to the TenantProject egress proxy contract used by the component", "topic": "documentation-coverage-and-freshness", "track_in": "docs/component-issues/egress-proxy.md"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- (none yet)
