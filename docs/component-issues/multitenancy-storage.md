# multitenancy-storage design issues

Canonical issue tracker for:
- `docs/design/multitenancy-storage.md`

Related trackers:
- Multi-tenancy core: `docs/design/multitenancy.md` (tracker: `docs/component-issues/multitenancy.md`)
- Multi-tenancy networking: `docs/design/multitenancy-networking.md` (tracker: `docs/component-issues/multitenancy-networking.md`)
- Backup plane / DR: `docs/component-issues/backup-system.md`
- Single-node storage strategy: `docs/component-issues/storage-single-node.md`
- Garage S3: `docs/component-issues/garage.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### deploymentconfig-extension
- Keep tenant egress as “gateway/proxy only” (no ipBlock in tenant namespaces); do not introduce a protectedEndpoints maintenance surface unless this posture changes. (ids: `dk.ca.finding.v1:multitenancy-storage:d3a99bd5d5c405e5ea9462a167dc88297caae33914935c95632b57b3ec882f48`)

#### s2-s4-guardrails-must-have-before-shared-cluster-tenants
- Remaining work is tracked in the multitenancy access-plane milestones (AppProjects + tenant RBAC): (ids: `dk.ca.finding.v1:multitenancy-storage:f2567347b7ed54cadc640b3946317b1c64548ed344a5c0fc0401ce1fec8d6242`)

### Medium

#### deploymentconfig-extension
- Add spec.storage.profile to the DeploymentConfig contract, aligned with docs/design/storage-single-node.md. (ids: `dk.ca.finding.v1:multitenancy-storage:ee4e41d171323c4d1512a11e3850018b1f9908f591a44f835ddb23a298d01320`)

#### tenant-aware-backup-plane
- Decide per-tenant restic repo granularity (per tenant vs per namespace vs per PVC). (ids: `dk.ca.finding.v1:multitenancy-storage:eb4873b3ea04b15f1b5f31a18225a5479fa050524e917a725971a7ec04a28903`)

- Define backup target directory layout under /backup/<deploymentId>/tenants/<orgId>/... and marker freshness contracts. (ids: `dk.ca.finding.v1:multitenancy-storage:46dc8ab0680d8bd409cfbe9da9184fe8bbec9d74b58d8e7759912d9315435fe7`)

- Define budgets/switch thresholds for “too many tenants to back up in one cluster”. (ids: `dk.ca.finding.v1:multitenancy-storage:dead5f95038e2149fe3246ea0184c0962ec492873f31d386c2ddb8c0affa4114`)

#### tenant-facing-s3-primitive-optional-but-must-be-safe
- Offboarding workflow (bucket deletion + Vault subtree wipe) is still to define. (ids: `dk.ca.finding.v1:multitenancy-storage:c305a9fb4bfbc6b85269157d802480b642888707cb1c37d7aa80452263903a76`)

- Rotation/revocation workflow (key disable, re-provisioning, and consumer rollout) is still to define. (ids: `dk.ca.finding.v1:multitenancy-storage:62324dc4a18168e7ab7ec1655e127dbb108cff4ebe8ea691c030c3d220531c55`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Remaining work is tracked in the multitenancy access-plane milestones (AppProjects + tenant RBAC):\n  - `docs/component-issues/multitenancy-gitops-and-argo.md`\n  - `docs/component-issues/multitenancy-secrets-and-vault.md`", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:f2567347b7ed54cadc640b3946317b1c64548ed344a5c0fc0401ce1fec8d6242", "last_seen_at": "2026-02-25", "recommendation": "Remaining work is tracked in the multitenancy access-plane milestones (AppProjects + tenant RBAC):", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Remaining work is tracked in the multitenancy access-plane milestones (AppProjects + tenant RBAC):", "topic": "s2-s4-guardrails-must-have-before-shared-cluster-tenants"}
{"class": "actionable", "details": "- Rotation/revocation workflow (key disable, re-provisioning, and consumer rollout) is still to define.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:62324dc4a18168e7ab7ec1655e127dbb108cff4ebe8ea691c030c3d220531c55", "last_seen_at": "2026-02-25", "recommendation": "Rotation/revocation workflow (key disable, re-provisioning, and consumer rollout) is still to define.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Rotation/revocation workflow (key disable, re-provisioning, and consumer rollout) is still to define.", "topic": "tenant-facing-s3-primitive-optional-but-must-be-safe"}
{"class": "actionable", "details": "- Offboarding workflow (bucket deletion + Vault subtree wipe) is still to define.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:c305a9fb4bfbc6b85269157d802480b642888707cb1c37d7aa80452263903a76", "last_seen_at": "2026-02-25", "recommendation": "Offboarding workflow (bucket deletion + Vault subtree wipe) is still to define.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Offboarding workflow (bucket deletion + Vault subtree wipe) is still to define.", "topic": "tenant-facing-s3-primitive-optional-but-must-be-safe"}
{"class": "actionable", "details": "- Decide per-tenant restic repo granularity (per tenant vs per namespace vs per PVC).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:eb4873b3ea04b15f1b5f31a18225a5479fa050524e917a725971a7ec04a28903", "last_seen_at": "2026-02-25", "recommendation": "Decide per-tenant restic repo granularity (per tenant vs per namespace vs per PVC).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide per-tenant restic repo granularity (per tenant vs per namespace vs per PVC).", "topic": "tenant-aware-backup-plane"}
{"class": "actionable", "details": "- Define backup target directory layout under `/backup/<deploymentId>/tenants/<orgId>/...` and marker freshness contracts.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:46dc8ab0680d8bd409cfbe9da9184fe8bbec9d74b58d8e7759912d9315435fe7", "last_seen_at": "2026-02-25", "recommendation": "Define backup target directory layout under /backup/<deploymentId>/tenants/<orgId>/... and marker freshness contracts.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define backup target directory layout under /backup/<deploymentId>/tenants/<orgId>/... and marker freshness contracts.", "topic": "tenant-aware-backup-plane"}
{"class": "actionable", "details": "- Define budgets/switch thresholds for \u201ctoo many tenants to back up in one cluster\u201d.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:dead5f95038e2149fe3246ea0184c0962ec492873f31d386c2ddb8c0affa4114", "last_seen_at": "2026-02-25", "recommendation": "Define budgets/switch thresholds for \u201ctoo many tenants to back up in one cluster\u201d.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define budgets/switch thresholds for \u201ctoo many tenants to back up in one cluster\u201d.", "topic": "tenant-aware-backup-plane"}
{"class": "actionable", "details": "- Add `spec.storage.profile` to the DeploymentConfig contract, aligned with `docs/design/storage-single-node.md`.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:ee4e41d171323c4d1512a11e3850018b1f9908f591a44f835ddb23a298d01320", "last_seen_at": "2026-02-25", "links": ["docs/design/storage-single-node.md"], "recommendation": "Add spec.storage.profile to the DeploymentConfig contract, aligned with docs/design/storage-single-node.md.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Add spec.storage.profile to the DeploymentConfig contract, aligned with docs/design/storage-single-node.md.", "topic": "deploymentconfig-extension"}
{"class": "actionable", "details": "- Keep tenant egress as \u201cgateway/proxy only\u201d (no `ipBlock` in tenant namespaces); do not introduce a `protectedEndpoints` maintenance surface unless this posture changes.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-storage:d3a99bd5d5c405e5ea9462a167dc88297caae33914935c95632b57b3ec882f48", "last_seen_at": "2026-02-25", "recommendation": "Keep tenant egress as \u201cgateway/proxy only\u201d (no ipBlock in tenant namespaces); do not introduce a protectedEndpoints maintenance surface unless this posture changes.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Keep tenant egress as \u201cgateway/proxy only\u201d (no ipBlock in tenant namespaces); do not introduce a protectedEndpoints maintenance surface unless this posture changes.", "topic": "deploymentconfig-extension"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **2026-01-16 – Tenant-facing S3 primitive (M6):**
  - Implemented per-tenant buckets + per-tenant credentials from Vault, projected into tenant namespaces via platform-owned ExternalSecrets.
  - Tightened Garage NetworkPolicies: S3 (`:3900`) reachable only from explicitly allowlisted tenant identities and select platform namespaces; admin/RPC remain garage-internal only.
  -
- **2026-01-09 – Contract correctness:** `docs/design/multitenancy-storage.md` reflects shipped storage repo reality:
  - Garage ingress posture (`NetworkPolicy/garage-ingress`)
  - Backup target layout (`/backup/<deploymentId>/tier0/**`, `/backup/<deploymentId>/s3-mirror/**`)
- **2026-01-09 – Tenant S2/S4 guardrails (admission layer v1):**
  - Tenant namespaces cannot author `NetworkPolicy` with `ipBlock` (prevents direct backend endpoint egress allowlists).
  - Tenant PVC surface is constrained (StorageClass allowlist + deny RWX).
  - Tenant namespaces cannot create/update `ExternalSecret`.
  -
- Baseline tenant quotas include storage (`requests.storage`, `persistentvolumeclaims`) via Kyverno. (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`)
- StorageClass contract is stable (`shared-rwo`; `shared-rwx` reserved). (`docs/design/storage-single-node.md`, `platform/gitops/components/storage/shared-rwo-storageclass/README.md`)
