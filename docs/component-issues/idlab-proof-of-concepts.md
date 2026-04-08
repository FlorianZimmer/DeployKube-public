# Identity Lab Proof Of Concepts

Schema: `docs/component-issues/SCHEMA.md`

## Open

### Version Lock Coverage
- `versions.lock.yaml` does not yet include this component. Keep this gap tracked here until a curated entry is added.
<!-- DK:VERSION_LOCK_GAP_TRACKED -->

### Component Assessment Findings (Manual)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### Medium

#### validation-jobs-and-smoke-coverage
- The `idlab` PoC has broad manual proof coverage and a scheduled external E2E workflow, but it still lacks an in-cluster `CronJob` health signal for canonical ongoing assurance in proxmox. Detailed private evidence was omitted from the public mirror. (id: `dk.ca.finding.v1:idlab-proof-of-concepts:3ef7a1e0c4463c2e0d6201d78d2c7db1b050b95f0d6e89693d4d1d0f36a3eb4a`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

Open items:
- The `idlab` PoC has no `smoke-tests/` or `CronJob` bundle yet. Continuous proof currently depends on suspended manual `Job` templates plus the scheduled external workflow, so proxmox does not yet have an in-cluster staleness/failure signal for the canonical ongoing health check.
- The PoC uses plaintext lab-only credentials in Git-managed `Secret` manifests because the user explicitly requested fixed test credentials for the proof workflow. This must not be promoted into a long-term platform surface.
- The PoC relies on external image availability for `quay.io/keycloak/keycloak` and `mcr.microsoft.com/playwright`; if proxmox image pull policy changes, mirror/pinning work is needed before this can be treated as durable.
- The original draft asked to use tenants if applicable. On proxmox this was not applicable in practice: the tenant namespace baseline denied the Keycloak/runtime pods and the proof job egress pattern, so the implementation intentionally uses a dedicated non-tenant namespace instead.
- The PoC still ignores HA/logging/monitoring hardening on purpose. That is acceptable for the current manufacturer-fit PoC scope, but it remains out of bounds for promotion into a productized identity surface.
- Design input for manufacturer requirements is tracked in `docs/design/middle-keycloak-herstelleranforderungen.md`.

## Component Assessment Findings (v1)

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"id":"dk.ca.finding.v1:idlab-proof-of-concepts:3ef7a1e0c4463c2e0d6201d78d2c7db1b050b95f0d6e89693d4d1d0f36a3eb4a","status":"open","class":"actionable","severity":"medium","title":"Idlab PoC lacks an in-cluster continuous smoke signal","topic":"validation-jobs-and-smoke-coverage","template_id":"operational-12-validation-jobs-and-smoke-coverage.md","evidence":[{"path":"platform/gitops/components/proof-of-concepts/idlab/tests/base/jobs.yaml","resource":"Job bundle/idlab tests","key":"contains suspended Job resources only; no CronJob resources"},{"path":"docs/design/validation-jobs-doctrine.md","resource":"Validation doctrine","key":"Scheduled CronJob (continuous assurance) and prod actionable enforcement"},{"path":".github/workflows/idlab-idp-poc-e2e.yml","resource":"GitHub Actions workflow/idlab-idp-poc-e2e","key":"scheduled external E2E complements manual jobs"},{"path":"platform/gitops/apps/opt-in/idlab-poc/README.md","resource":"Opt-in README","key":"Prod entrypoint for proxmox"}],"recommendation":"Add a narrow `smoke-tests/` CronJob bundle for the canonical proxmox health signal, keep the suspended manual Jobs for evidence capture, and leave the broader workflow E2E as the matrix complement.","first_seen_at":"2026-03-10","last_seen_at":"2026-03-10","track_in":"docs/component-issues/idlab-proof-of-concepts.md"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **2026-03-15 – IDLab PoC moved behind the platform-owned Postgres API:** the PoC now declares `PostgresInstance/idlab-postgres` against the disposable `PostgresClass/platform-poc-disposable`, so the database stays explicitly outside the durable backup/monitoring plane without shipping raw CNPG manifests in the PoC component.
- **2026-03-11 – Explicitly marked disposable IDLab storage out of the backup plane:** labeled `Cluster/idlab-postgres` generated PVCs and `PersistentVolumeClaim/proofs-pvc` with `darksite.cloud/backup=skip` plus `darksite.cloud/backup-skip-reason=proof-of-concept`, and documented that this opt-in PoC is intentionally outside the durable backup contract.
