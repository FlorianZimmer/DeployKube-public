# gitops-operating-model design issues

Canonical issue tracker for the GitOps operating model.

Design:
- `docs/design/gitops-operating-model.md`
- `docs/design/architecture-overview.md`

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

- **Evidence discipline:** evidence format v1 documented + linted in CI (`docs/evidence/README.md`, `tests/scripts/validate-evidence-notes.sh`).
- **Stage 0/1 contract tests:** repo-only validation checks Stage 1 inputs exist for each deployment (Forgejo seed snapshot + Argo root app path wiring): `tests/scripts/validate-bootstrap-contract.sh`.
- **GitOps-first boundary:** host scripts only bootstrap/seed; steady-state is declarative under `platform/gitops/**`.
- **Design-doc tracking lint:** `./tests/scripts/validate-design-doc-tracking.sh` enforces that each `docs/design/*.md` has a canonical tracker under `docs/component-issues/` and that trackers link back to their design docs.
