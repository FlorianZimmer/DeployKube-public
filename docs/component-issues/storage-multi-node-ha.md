# storage-multi-node-ha design issues

Canonical issue tracker for the multi-node HA storage design placeholder.

Design:
- `docs/design/storage-multi-node-ha.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### general
- Decide Ceph deployment shape: in-cluster (Rook) vs external (Proxmox-managed), and document the chosen operational constraints for Talos. (ids: `dk.ca.finding.v1:storage-multi-node-ha:29041b7c2ba39e289bfb118e9da7434456c7bedab9643d8c6fa6aae090d50b60`)

- Decide promotion trigger: when this becomes the default for Proxmox/Talos (likely via an explicit DeploymentConfig storage profile selector) and what “promotion evidence” is required. (ids: `dk.ca.finding.v1:storage-multi-node-ha:3a4792fadf7c3868bd09be1c38d204488c4f3657660c7336853d240a1df66c3d`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- **Decide Ceph deployment shape:** in-cluster (Rook) vs external (Proxmox-managed), and document the chosen operational constraints for Talos.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:storage-multi-node-ha:29041b7c2ba39e289bfb118e9da7434456c7bedab9643d8c6fa6aae090d50b60", "last_seen_at": "2026-02-25", "recommendation": "Decide Ceph deployment shape: in-cluster (Rook) vs external (Proxmox-managed), and document the chosen operational constraints for Talos.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide Ceph deployment shape: in-cluster (Rook) vs external (Proxmox-managed), and document the chosen operational constraints for Talos.", "topic": "general"}
{"class": "actionable", "details": "- **Decide promotion trigger:** when this becomes the default for Proxmox/Talos (likely via an explicit DeploymentConfig storage profile selector) and what \u201cpromotion evidence\u201d is required.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:storage-multi-node-ha:3a4792fadf7c3868bd09be1c38d204488c4f3657660c7336853d240a1df66c3d", "last_seen_at": "2026-02-25", "recommendation": "Decide promotion trigger: when this becomes the default for Proxmox/Talos (likely via an explicit DeploymentConfig storage profile selector) and what \u201cpromotion evidence\u201d is required.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide promotion trigger: when this becomes the default for Proxmox/Talos (likely via an explicit DeploymentConfig storage profile selector) and what \u201cpromotion evidence\u201d is required.", "topic": "general"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **2026-01-09 – Design written:** `docs/design/storage-multi-node-ha.md` describes the Ceph-backed HA profile (RBD/RGW, StorageClass + S3 contracts, reachability model, upgrade/rollback posture, restore drills, and migration outline).
- **2026-01-09 – Threat model + decision gates:** added S1–S4 mapping for Ceph surfaces and explicit decision gates + minimum sizing assumptions (Rook vs external, failure domains, replication). (`docs/design/storage-multi-node-ha.md`)
