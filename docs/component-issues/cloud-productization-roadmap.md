# cloud-productization-roadmap design issues

Canonical issue tracker for `docs/design/cloud-productization-roadmap.md`.

Design:
- `docs/design/cloud-productization-roadmap.md`
- `docs/design/vendor-integration-and-provider-abstractions.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
Open: None currently.
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- 2026-03-14: resolved with a live Proxmox rehearsal on `cert-manager`, which is stronger than the original dev-only ask. The repo now has evidence for a GitOps rollback from `v1.19.4` to `v1.19.3`, a GitOps forward upgrade back to `v1.19.4`, post-change functional smokes for self-signed, Step CA, and Vault-backed issuance, and the observed Argo `startupapicheck` prune/finalizer breakglass needed to complete both halves of the rehearsal.", "evidence": [{"key": "component upgrade/rollback procedure", "path": "platform/gitops/components/certificates/cert-manager/README.md", "resource": "README"}, {"key": "rollback rehearsal commit", "path": "platform/gitops/components/certificates/cert-manager/helm/values.yaml", "resource": "cert-manager values"}, {"key": "roadmap design now reflects the practiced baseline", "path": "docs/design/cloud-productization-roadmap.md", "resource": "Roadmap"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-productization-roadmap:adcfd20b2a57d46c629a56f4465bd959668ccbe4f5f5a7d3cb8556938eeab870", "last_seen_at": "2026-03-14", "recommendation": "Keep tier-0 upgrade/rollback rehearsal evidence in component-local docs/evidence after the roadmap-level baseline is closed; prioritize the next rehearsal where the operational risk is materially different.", "severity": "medium", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Tier-0 upgrade/rollback rehearsal (dev): pick one high-value platform component and prove an upgrade + rollback procedure with evidence.", "topic": "cross-cutting-items-tracked-here"}
{"class": "actionable", "details": "- 2026-03-14: closed by defining the v0 provisioning contract as a validated multi-document bundle of `DeploymentConfig` + `Tenant` + `TenantProject`, with example manifests and repo validation.", "evidence": [{"key": "v0 contract decision + invariants", "path": "docs/design/provisioning-contract-v0.md", "resource": "Provisioning Contract v0"}, {"key": "dev example bundle", "path": "platform/gitops/deployments/examples/provisioning-v0/minimal-dev-first-tenant.yaml", "resource": "example bundle"}, {"key": "prod example bundle", "path": "platform/gitops/deployments/examples/provisioning-v0/minimal-prod-first-tenant.yaml", "resource": "example bundle"}, {"key": "bundle validator", "path": "tests/scripts/validate-provisioning-bundle-examples.sh", "resource": "validate-provisioning-bundle-examples.sh"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-productization-roadmap:3fa53f1bad4e2c10e59197aff79e26e850b741d68a1df4294a0d09a0bd8f33ba", "last_seen_at": "2026-03-14", "recommendation": "Provisioning schema v0: publish a validated \u201csingle YAML\u201d schema + examples (even if runtime controller work comes later), and keep it compatible with the DeploymentConfig contract direction.", "severity": "medium", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Provisioning schema v0: publish a validated \u201csingle YAML\u201d schema + examples (even if runtime controller work comes later), and keep it compatible with the DeploymentConfig contract direction.", "topic": "cross-cutting-items-tracked-here"}
{"class": "actionable", "details": "- 2026-03-14: resolved. The access-contract closure is already implemented and evidenced in the dedicated component tracker (`access-guardrails`), so it no longer belongs in the roadmap backlog.", "evidence": [{"key": "component tracker now open-none", "path": "docs/component-issues/access-guardrails.md", "resource": "access-guardrails tracker"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-productization-roadmap:15f3d4299d163f4c9d635bf19cfdd65be28dc4143811741ead2e0c971b7c6155", "last_seen_at": "2026-03-14", "recommendation": "Access contract OIDC smoke + prod breakglass drill + alerting/staleness: docs/component-issues/access-guardrails.md.", "severity": "high", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Access contract OIDC smoke + prod breakglass drill + alerting/staleness: docs/component-issues/access-guardrails.md.", "topic": "delegated-items-track-in-the-component-trackers-not-here"}
{"class": "actionable", "details": "- 2026-03-14: suppressed in this roadmap tracker because the remaining Kyverno smoke alerting/staleness work is component-local and already has a canonical home in `docs/component-issues/policy-kyverno.md`.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-productization-roadmap:bfa88558b3791554e923f1374a7ee38e3e71f2fb0e040ca1b2fa0b3e864a9f57", "last_seen_at": "2026-03-14", "recommendation": "Kyverno baseline smoke alerting/staleness: docs/component-issues/policy-kyverno.md.", "severity": "medium", "status": "suppressed", "suppression": {"reason": "Delegated component-local follow-up; do not duplicate in roadmap tracker.", "review_by": "2026-06-14"}, "template_id": "legacy-component-issues.md", "title": "Kyverno baseline smoke alerting/staleness: docs/component-issues/policy-kyverno.md.", "topic": "delegated-items-track-in-the-component-trackers-not-here"}
{"class": "actionable", "details": "- 2026-03-14: resolved at the roadmap level. The repo now ships a real `backup-system` baseline (backup target, smokes, restore tooling, full-restore staleness enforcement), so this is no longer an open roadmap blocker here. Remaining hardening stays in `docs/component-issues/backup-system.md`.", "evidence": [{"key": "implemented baseline in repo truth summary", "path": "target-stack.md", "resource": "Target stack"}, {"key": "restore tooling entrypoint", "path": "scripts/ops/restore-from-backup.sh", "resource": "restore-from-backup.sh"}, {"key": "backup-system tracker", "path": "docs/component-issues/backup-system.md", "resource": "backup-system tracker"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-productization-roadmap:ee1a03cdcec1c6af5c1ee54ea1e4c187d9b17f8ea7a0ec2da0882fc210445493", "last_seen_at": "2026-03-14", "recommendation": "Full-deployment DR baseline (backup plane + restore flow + restore drill enforcement): docs/component-issues/backup-system.md.", "severity": "medium", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Full-deployment DR baseline (backup plane + restore flow + restore drill enforcement): docs/component-issues/backup-system.md.", "topic": "delegated-items-track-in-the-component-trackers-not-here"}
{"class": "actionable", "details": "- 2026-03-14: resolved at the roadmap level using the existing restore evidence already in-repo: OpenBao/Vault restore flow is documented in the platform restore guide and OpenBao rollout evidence, and a tier-0 Postgres restore drill is evidenced for a CNPG consumer.", "evidence": [{"key": "platform restore guide includes Vault raft snapshot restore", "path": "docs/guides/restore-from-backup.md", "resource": "Restore from Backup guide"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-productization-roadmap:6c3994dcc4fd6f24c1eb65d74a2384cdb2c1df2f8e7b35625ed0650e16208511", "last_seen_at": "2026-03-14", "recommendation": "Tier-0 restore drill evidence (dev): restore at least OpenBao + one Postgres cluster with evidence (part of DR baseline): docs/component-issues/backup-system.md.", "severity": "medium", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Tier-0 restore drill evidence (dev): restore at least OpenBao + one Postgres cluster with evidence (part of DR baseline): docs/component-issues/backup-system.md.", "topic": "delegated-items-track-in-the-component-trackers-not-here"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **2026-03-14 – Tier-0 cert-manager upgrade/rollback rehearsal on Proxmox:**
  - Closed the last roadmap-level open item by rehearsing a real GitOps rollback (`v1.19.4` -> `v1.19.3`) and forward upgrade (`v1.19.3` -> `v1.19.4`) for cert-manager on the Proxmox cluster.
  - Captured the required breakglass for the known Argo `startupapicheck` Role/RoleBinding prune wedge and reran all three functional certificate paths after the forward upgrade.
  -
- **2026-03-14 – Roadmap tracker cleanup + provisioning contract v0:**
  - Closed stale roadmap-level duplicates for access-contract closure and DR baseline/restore proof.
  - Stopped duplicating the remaining Kyverno component-local backlog here; it stays in `docs/component-issues/policy-kyverno.md`.
  - Added `docs/design/provisioning-contract-v0.md`, example bundles under `platform/gitops/deployments/examples/provisioning-v0/`, and CI validation via `tests/scripts/validate-provisioning-bundle-examples.sh`.
  -
- **Platform/tenant separation:** example apps are shipped as an opt-in Argo bundle under `platform/gitops/apps/opt-in/examples-apps/` (not part of default “platform core”).
- **2026-02-18 – Supply-chain pinning policy + lint (tier-0 baseline):**
  - Added policy doc `docs/design/supply-chain-pinning-policy.md`.
  - Added machine-readable tier-0 register `tests/fixtures/supply-chain-tier0-pinning.tsv` (pins + temporary exceptions with expiry/tracker refs).
  - Added CI validator `tests/scripts/validate-supply-chain-pinning.sh` and wired it into `tests/scripts/ci.sh` (`deployment-contracts` suite).
  -
- **2026-02-18 – Supply-chain pinning follow-up: removed temporary mac Stage 0 exceptions:**
  - `bootstrap-mac-orbstack-stage0.sh` now pins Cilium (`--version 1.18.5`) and MetalLB (`--version 0.15.2`) during Stage 0 installs.
  - `tests/fixtures/supply-chain-tier0-pinning.tsv` now contains only pin rows (no temporary exceptions).
  - `docs/design/supply-chain-pinning-policy.md` now reports no active temporary exceptions.
  -
