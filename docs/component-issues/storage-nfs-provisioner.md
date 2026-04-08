# Storage: NFS provisioner (nfs-subdir-external-provisioner) issues

## Design / context

- Offline bootstrap + distribution bundles: `docs/design/offline-bootstrap-and-oci-distribution.md`
- Storage patterns: `docs/design/data-services-patterns.md`

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
- **High** (topic: `general`) Add component-specific smokes beyond `shared-rwo` (e.g., assert provisioner Deployment health + provisioning within an SLO window). (ids: `dk.ca.finding.v1:storage-nfs-provisioner:873dcf6062b6e03f75c88bc6403a3ed19eb104a4fe38a1c2e0fcc857836734e0`)
- **Medium** (topic: `documentation-coverage-and-freshness`) Expand `platform/gitops/components/storage/nfs-provisioner/README.md` (or add a referenced `docs/toils/*`) to document: required NFS export prerequisites; which Helm values/operators must set for NFS server/path and where they live (env patch file: `platform/gitops/apps/environments/<deploymentId>/patches/patch-app-storage-nfs-provisioner.yaml`); and a short troubleshooting section (PVC Pending, mount/auth errors) linking to the `shared-rwo` validation jobs. (ids: `dk.ca.finding.v1:storage-nfs-provisioner:709dd6504bb7138ed5107920d52c9c7ffa4a0e868ee4e8f8bf5c27bfccc5991b`)
- **Medium** (topic: `general`) Define the long-term “no in-flight YAML rendering” posture for this component (today: Argo CD Helm source with vendored chart; decide whether to move to pre-rendered YAML in GitOps vs a controller-owned storage plane). (ids: `dk.ca.finding.v1:storage-nfs-provisioner:496353c577200c65ce077a40a4a381babbc581bb7f36f8e9a9eaa4746f8a8ece`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Add component-specific smokes beyond `shared-rwo` (if needed):\n  - e.g. assert the provisioner Deployment is healthy and can provision within an SLO window.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:storage-nfs-provisioner:873dcf6062b6e03f75c88bc6403a3ed19eb104a4fe38a1c2e0fcc857836734e0", "last_seen_at": "2026-02-25", "recommendation": "Add component-specific smokes beyond shared-rwo (if needed):", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Add component-specific smokes beyond shared-rwo (if needed):", "topic": "general"}
{"class": "actionable", "details": "", "evidence": [{"key": "Environment-specific Helm values are patched via: platform/gitops/apps/environments/<deploymentId>/patches/patch-app-storage-nfs-provisioner.yaml", "path": "platform/gitops/components/storage/nfs-provisioner/README.md", "resource": "GitOps layout"}, {"key": "The NFS server/path are deployment-specific; do not hardcode them outside overlays/patches.", "path": "platform/gitops/components/storage/nfs-provisioner/README.md", "resource": "Notes"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:storage-nfs-provisioner:709dd6504bb7138ed5107920d52c9c7ffa4a0e868ee4e8f8bf5c27bfccc5991b", "last_seen_at": "2026-02-25", "recommendation": "Expand platform/gitops/components/storage/nfs-provisioner/README.md (or add a docs/toils/* entry referenced from it) to document: required NFS export prerequisites; the exact values/keys operators must set for NFS server/path and where they live (env patch file); and a short troubleshooting section for common failure modes (PVC Pending, mount/auth errors) that links to the shared-rwo validation jobs.", "risk": "", "severity": "medium", "status": "open", "template_id": "operational-10-documentation-coverage-and-freshness.md", "title": "Add operator-facing docs for NFS backend config and troubleshooting", "topic": "documentation-coverage-and-freshness", "track_in": "docs/component-issues/storage-nfs-provisioner.md"}
{"class": "actionable", "details": "- Define the long-term \u201cno in-flight YAML rendering\u201d posture for this component:\n  - today it is installed via an Argo CD Helm source using a vendored chart (no public Helm repo fetch),\n  - long-term we likely want either pre-rendered YAML in GitOps or a controller-owned storage plane.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:storage-nfs-provisioner:496353c577200c65ce077a40a4a381babbc581bb7f36f8e9a9eaa4746f8a8ece", "last_seen_at": "2026-02-25", "recommendation": "Define the long-term \u201cno in-flight YAML rendering\u201d posture for this component:", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define the long-term \u201cno in-flight YAML rendering\u201d posture for this component:", "topic": "general"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- Vendored the Helm chart in-repo so GitOps does not fetch a public Helm repo at sync time.
