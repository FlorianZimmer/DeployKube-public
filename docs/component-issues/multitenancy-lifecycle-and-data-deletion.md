# Multitenancy lifecycle + data deletion — design issues

Canonical issue tracker for:
- `docs/design/multitenancy-lifecycle-and-data-deletion.md`

Related trackers:
- Multitenancy storage: `docs/component-issues/multitenancy-storage.md`
- Backup plane / DR: `docs/component-issues/backup-system.md`
- Access contract guardrails: `docs/component-issues/access-guardrails.md`
- Policy engine: `docs/component-issues/policy-kyverno.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### backups-tenant-scoped-boundaries
- Define what “delete tenant from backups” means for Tier S vs Tier D, and enforce the “Tier D required for strict deletion SLA” rule if applicable. (ids: `dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:bbf6fe8ba46640f946123b36038de338c23aa13f387613e6c555e95d6317bc9c`)

### Medium

#### backups-tenant-scoped-boundaries
- Implement per-tenant backup target layout under /backup/<deploymentId>/tenants/<orgId>/... (contract exists in docs/design/multitenancy-storage.md). (ids: `dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:3d6beb5e8c90b75dc75ba08deb0a5ec7f40cd9183b140f921f68a2d4d5d0f4ce`)

- Implement per-tenant restic repo granularity (decided default below) with clear retention and deletion semantics. (ids: `dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:59fb9146887106969b638f9d7cee0fd2c88cd439f0101704c7d766da51c16e96`)

#### evidence-tooling-optional
- Consider adding reusable evidence helpers/templates beyond the shipped toils to reduce ad-hoc commands during onboarding/offboarding while keeping GitOps boundaries intact. (ids: `dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:ed1252457f3ff01b64fe83dcf6cf20b0d3b182aa0aa391a1ac381db8ade3b6d8`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Decided (design; implementation pending)

- Tenant folder contract:
  - `platform/gitops/tenants/<orgId>/metadata.yaml` records tier + retention + backup-deletion semantics
  - folder placeholder `<env>` means `overlayMode` (`dev|prod`), not `deploymentId`
- Tenant status surface: Argo CD `Application` objects are the “status” surface (no new CRD); label with `darksite.cloud/tenant-id=<orgId>`.
- Support session TTL enforcement: CI gate + scheduled Git cleanup PR; in-cluster loop is alert-only unless Git is also updated.
- PV wipe scope: standardize on the `rwo/<namespace>-<pvc>` directory contract and require allowlist/prefix validation + dry-run.
- Tenant-facing S3: per-tenant buckets + per-tenant keys; provision/teardown via platform-owned Jobs (Garage now; RGW later).
- Backups:
  - Tier S: “delete from backups” is only claimable once backups are tenant-scoped (per-tenant repo/key + `/backup/<deploymentId>/tenants/<orgId>/...`)
  - strict deletion SLA requires Tier D unless/until tenant-scoped boundaries are implemented and budgeted
  - restic granularity default: one restic repo per tenant org per cluster (split per project only if “project is a hard delete boundary” becomes a requirement)

---

## Resolved (implemented)

- Tenant namespace label contract exists and is enforced by VAP (`tenant-id == observability tenant`). See `docs/design/policy-engine-and-baseline-constraints.md` and `docs/design/multitenancy.md`.
- Baseline tenant constraints exist (deny-by-default netpols, quotas/limits) via Kyverno generate policies.
- Implemented the v1 tenant registry GitOps UX scaffold:
  - canonical tenant folder contract under `platform/gitops/tenants/<orgId>/...` with required `metadata.yaml`
  - `<env>` placeholder means `overlayMode` (`dev|prod`), not `deploymentId`
  - wired tenant intent into the root app-of-apps (`platform-apps`) without enabling ApplicationSet via static tenant intent `Application` objects
  - kept the tenant status surface as Argo CD `Application` objects labeled `darksite.cloud/tenant-id=<orgId>` (no new CRD)
  - enforced coherence between registry ↔ folders ↔ tenant intent Applications via repo-only validation

- Implemented support sessions (Git folders + TTL enforcement + Git-driven cleanup):
  - Tenant intent contract: `platform/gitops/tenants/README.md`.
  - CI TTL gate: `tests/scripts/validate-support-sessions.sh`.
  - Scheduled cleanup PR (GitHub): `.github/workflows/support-session-cleanup.yml`.
  - Operator cleanup toil: `scripts/toils/support-sessions/cleanup-expired.sh`.

- Implemented v1 offboarding toils (inventory + safe wipe primitives; operator-driven, evidence-friendly logs):
  - Inventory: `scripts/toils/tenant-offboarding/inventory.sh`.
  - PV backend wipe Job generator: `scripts/toils/tenant-offboarding/wipe-pv-data.sh`.
  - Garage tenant S3 teardown Job: `scripts/toils/tenant-offboarding/delete-garage-tenant-s3.sh`.
  - Vault KV v2 subtree wipe: `scripts/toils/tenant-offboarding/wipe-vault-tenant-kv.sh`.

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Implement per-tenant backup target layout under `/backup/<deploymentId>/tenants/<orgId>/...` (contract exists in `docs/design/multitenancy-storage.md`).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:3d6beb5e8c90b75dc75ba08deb0a5ec7f40cd9183b140f921f68a2d4d5d0f4ce", "last_seen_at": "2026-02-25", "links": ["docs/design/multitenancy-storage.md"], "recommendation": "Implement per-tenant backup target layout under /backup/<deploymentId>/tenants/<orgId>/... (contract exists in docs/design/multitenancy-storage.md).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Implement per-tenant backup target layout under /backup/<deploymentId>/tenants/<orgId>/... (contract exists in docs/design/multitenancy-storage.md).", "topic": "backups-tenant-scoped-boundaries"}
{"class": "actionable", "details": "- Implement per-tenant restic repo granularity (decided default below) with clear retention and deletion semantics.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:59fb9146887106969b638f9d7cee0fd2c88cd439f0101704c7d766da51c16e96", "last_seen_at": "2026-02-25", "recommendation": "Implement per-tenant restic repo granularity (decided default below) with clear retention and deletion semantics.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Implement per-tenant restic repo granularity (decided default below) with clear retention and deletion semantics.", "topic": "backups-tenant-scoped-boundaries"}
{"class": "actionable", "details": "- Define what \u201cdelete tenant from backups\u201d means for Tier S vs Tier D, and enforce the \u201cTier D required for strict deletion SLA\u201d rule if applicable.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:bbf6fe8ba46640f946123b36038de338c23aa13f387613e6c555e95d6317bc9c", "last_seen_at": "2026-02-25", "recommendation": "Define what \u201cdelete tenant from backups\u201d means for Tier S vs Tier D, and enforce the \u201cTier D required for strict deletion SLA\u201d rule if applicable.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define what \u201cdelete tenant from backups\u201d means for Tier S vs Tier D, and enforce the \u201cTier D required for strict deletion SLA\u201d rule if applicable.", "topic": "backups-tenant-scoped-boundaries"}
{"class": "actionable", "details": "- Consider adding reusable evidence helpers/templates beyond the shipped toils to reduce ad-hoc commands during onboarding/offboarding while keeping GitOps boundaries intact.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-lifecycle-and-data-deletion:ed1252457f3ff01b64fe83dcf6cf20b0d3b182aa0aa391a1ac381db8ade3b6d8", "last_seen_at": "2026-02-25", "recommendation": "Consider adding reusable evidence helpers/templates beyond the shipped toils to reduce ad-hoc commands during onboarding/offboarding while keeping GitOps boundaries intact.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Consider adding reusable evidence helpers/templates beyond the shipped toils to reduce ad-hoc commands during onboarding/offboarding while keeping GitOps boundaries intact.", "topic": "evidence-tooling-optional"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->
