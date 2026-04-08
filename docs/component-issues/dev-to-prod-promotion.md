# dev-to-prod-promotion design issues

Canonical issue tracker for the dev → prod promotion model.

Design:
- `docs/design/dev-to-prod-promotion.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### Medium

#### general
- None currently. (ids: `dk.ca.finding.v1:dev-to-prod-promotion:6fd0b0c22027512ea3e27ce4272d851fa4d28a9b0e069d11793249830564fb6a`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- None currently.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:dev-to-prod-promotion:6fd0b0c22027512ea3e27ce4272d851fa4d28a9b0e069d11793249830564fb6a", "last_seen_at": "2026-02-25", "recommendation": "None currently.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "None currently.", "topic": "general"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- [x] **2026-02-18 – Promotion evidence loop defined (minimum contract):** documented required evidence per promoted component in `docs/design/dev-to-prod-promotion.md`:
  - Argo status (`Synced Healthy`) for root + promoted app,
  - smoke/validation output path,
  - rollback note,
  - stateful durability evidence when applicable.
- [x] **2026-02-18 – Promotion guardrails decision:** decided against a repo-wide hard CI parity gate for now; current contract requires evidence-backed promotions to `proxmox-talos` and explicit rationale/rollback for intentional prod-like-only drift. Future tightening is triggered by customer/SLA requirements. See `docs/design/dev-to-prod-promotion.md`.
- **Overlays-first repo shape:** components use `overlays/<deploymentId>/...` and environments are assembled via app-of-apps under `platform/gitops/apps/environments/<deploymentId>/`.
