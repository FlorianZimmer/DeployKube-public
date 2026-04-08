# multitenancy-service-catalog design issues

Canonical issue tracker for:
- `docs/design/multitenancy-service-catalog.md`

Related trackers:
- Multi-tenancy core: `docs/component-issues/multitenancy.md`
- Multi-tenancy networking: `docs/component-issues/multitenancy-networking.md`
- Multi-tenancy storage: `docs/component-issues/multitenancy-storage.md`
- Data services patterns: `docs/component-issues/data-services-patterns.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### tenant-facing-storage-primitives-dependencies
- Track tenant-aware backups (who backs up what; where restore drills live) per catalog item. (ids: `dk.ca.finding.v1:multitenancy-service-catalog:9de47837a5433c583489d3d93b563aa3a4050c7de0c3550f887d0920886d773d`)

### Medium

#### managed-data-services-planned
- Postgres tenant instance model (naming, onboarding/offboarding, backups, quota/budgets). (ids: `dk.ca.finding.v1:multitenancy-service-catalog:c1f3152d978c30358da3875e122f1c619851573d33fc903099d3bb398f6c637d`)

- Valkey tenant instance model (best-effort posture, persistence/backup stance, budgets). (ids: `dk.ca.finding.v1:multitenancy-service-catalog:b0f72684d0eb75c9a7b12eb0d0a0d307886a60f5811ae7b431da26c7feff2869`)

#### tenant-facing-storage-primitives-dependencies
- Track tenant-facing S3 follow-ups (rotation/offboarding, quotas/budgets, restore semantics) as a catalog item. (ids: `dk.ca.finding.v1:multitenancy-service-catalog:928f77454bdb655b3c52b20a0620bf5ab83a63388f29e55b8f19040d7518742c`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Track tenant-facing S3 follow-ups (rotation/offboarding, quotas/budgets, restore semantics) as a catalog item.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-service-catalog:928f77454bdb655b3c52b20a0620bf5ab83a63388f29e55b8f19040d7518742c", "last_seen_at": "2026-02-25", "recommendation": "Track tenant-facing S3 follow-ups (rotation/offboarding, quotas/budgets, restore semantics) as a catalog item.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Track tenant-facing S3 follow-ups (rotation/offboarding, quotas/budgets, restore semantics) as a catalog item.", "topic": "tenant-facing-storage-primitives-dependencies"}
{"class": "actionable", "details": "- Track tenant-aware backups (who backs up what; where restore drills live) per catalog item.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-service-catalog:9de47837a5433c583489d3d93b563aa3a4050c7de0c3550f887d0920886d773d", "last_seen_at": "2026-02-25", "recommendation": "Track tenant-aware backups (who backs up what; where restore drills live) per catalog item.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Track tenant-aware backups (who backs up what; where restore drills live) per catalog item.", "topic": "tenant-facing-storage-primitives-dependencies"}
{"class": "actionable", "details": "- Postgres tenant instance model (naming, onboarding/offboarding, backups, quota/budgets).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-service-catalog:c1f3152d978c30358da3875e122f1c619851573d33fc903099d3bb398f6c637d", "last_seen_at": "2026-02-25", "recommendation": "Postgres tenant instance model (naming, onboarding/offboarding, backups, quota/budgets).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Postgres tenant instance model (naming, onboarding/offboarding, backups, quota/budgets).", "topic": "managed-data-services-planned"}
{"class": "actionable", "details": "- Valkey tenant instance model (best-effort posture, persistence/backup stance, budgets).\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-service-catalog:b0f72684d0eb75c9a7b12eb0d0a0d307886a60f5811ae7b431da26c7feff2869", "last_seen_at": "2026-02-25", "recommendation": "Valkey tenant instance model (best-effort posture, persistence/backup stance, budgets).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Valkey tenant instance model (best-effort posture, persistence/backup stance, budgets).", "topic": "managed-data-services-planned"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

### 2026-01-16
- Tenant-facing S3 primitive implemented (Git intent → platform provisioner → Vault → platform-owned ESO projection) with safe reachability constraints.

### 2026-01-06
- Canonical tracker created to satisfy the design doc tracking doctrine.
- Clarified enforceable readiness levels (“tenant-facing”, “managed”, “Tier S-ready”) and added an explicit GitOps ordering surface for tenant primitives.
