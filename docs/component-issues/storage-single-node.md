# storage-single-node design issues

Canonical issue tracker for the single-node storage strategy design.

Design:
- `docs/design/storage-single-node.md`

Related components (own their own issue trackers):
- Garage S3: `docs/component-issues/garage.md`
- Shared RWO StorageClass: `docs/component-issues/shared-rwo-storageclass.md`
- Backup plane / DR: `docs/component-issues/backup-system.md`

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

- **v1 single-node profile documented:** node-local `shared-rwo` and Garage LMDB posture are described in the design doc and backed by in-repo manifests.
- **Garage LMDB + latency smoke present:** `platform/gitops/components/storage/garage/base/configmap.yaml` sets `db_engine = "lmdb"`, and `platform/gitops/components/storage/garage/smoke-tests/base/cronjob-s3-latency.yaml` exists as continuous S3 tail-latency validation.
- **2026-01-09 – Design hygiene:** `docs/design/storage-single-node.md` now has explicit “implemented v1” vs “future / planned” section separation.
- **2026-01-09 – Contract correctness:** backup-plane smoke contracts and marker paths in `docs/design/storage-single-node.md` match the shipped backup target layout (`/backup/<deploymentId>/tier0/**`, `/backup/<deploymentId>/s3-mirror/**`) and the operator guide (`docs/guides/backups-and-dr.md`).
- **2026-01-09 – Tracker added:** `docs/component-issues/local-path-provisioner.md` added for the implemented `platform/gitops/components/storage/local-path-provisioner/` component.
