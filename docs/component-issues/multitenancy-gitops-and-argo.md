# multitenancy-gitops-and-argo design issues

Canonical issue tracker for:
- `docs/design/multitenancy-gitops-and-argo.md`

Related trackers:
- Multi-tenancy core: `docs/component-issues/multitenancy.md`
- Multi-tenancy networking: `docs/component-issues/multitenancy-networking.md`
- Multi-tenancy storage: `docs/component-issues/multitenancy-storage.md`
- Tenant lifecycle/deletion: `docs/component-issues/multitenancy-lifecycle-and-data-deletion.md`
- Access guardrails: `docs/component-issues/access-guardrails.md`
- Argo CD: `docs/component-issues/argocd.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### scale-budgets-validation-and-tier-thresholds
- Define the Tier S2 sharding plan: (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:499404b15bdf7b7c440e8274794fa0264ab1ebe6785a9a9b56081f14349c284c`)

#### tenant-pr-flow-validation-gates-adoption
- Tenant AppProject templates (org-scoped + project-scoped) that deny cluster-scoped and access-plane resources by default: (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:ae434de8a21e5d05fda1a714d79aa12e866063a88eff2bfafb7a735ee96bd688`)

- Tenant repo “happy path” guide + gate runner: (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:3e519733a11314bf6d094eacc8f8056b491bc9b66c4b9b24ad69ec253b1b2be5`)

### Medium

#### scale-budgets-validation-and-tier-thresholds
- Measure Argo reconcile latency under increasing Application counts (dev first), then ratify Tier S0/S1 ceilings as measured budgets. (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:c04b3a9669b9813d7fa0f96f476143e1f236d37e9224909b4430d048daad3804`)

#### tenant-appprojects-registry-integration
- Align tenant allowlists (repos/destinations/kinds) to the multitenancy/storage/networking contracts as they evolve. (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:19d3782cb0e82ca108b85f2f6c6a30f70c072f5fc55ab283924dc3efbe7b2be5`)

#### tenant-pr-flow-validation-gates-adoption
- Evidence (prod rollout):  (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:6482b714adfdbc9238dd31cc74f336f4ee0bf81120ce35c51f790b9bfd4bbd56`)

- Evidence (repo-only):  (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:e21cb3f1a2399c1eb69e24d9c4b517e9aec0711b7d54d301bea78397bef29729`)

- Keep the prohibited-kinds contract in sync with the policy/admission surface (deny new access-plane kinds by default). (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:7f21ac285cd841987cce8ec61faeb45c42494a25aa0a4be414b34a8ab5c8408b`)

- Prohibited-kinds contract + validator script: (ids: `dk.ca.finding.v1:multitenancy-gitops-and-argo:398d70e30a336e8c554c570589c052527fb2831b526f4c109bb989b4546f4e3f`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Align tenant allowlists (repos/destinations/kinds) to the multitenancy/storage/networking contracts as they evolve.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:19d3782cb0e82ca108b85f2f6c6a30f70c072f5fc55ab283924dc3efbe7b2be5", "last_seen_at": "2026-02-25", "recommendation": "Align tenant allowlists (repos/destinations/kinds) to the multitenancy/storage/networking contracts as they evolve.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Align tenant allowlists (repos/destinations/kinds) to the multitenancy/storage/networking contracts as they evolve.", "topic": "tenant-appprojects-registry-integration"}
{"class": "actionable", "details": "- Keep the prohibited-kinds contract in sync with the policy/admission surface (deny new access-plane kinds by default).\n\nImplemented building blocks:", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:7f21ac285cd841987cce8ec61faeb45c42494a25aa0a4be414b34a8ab5c8408b", "last_seen_at": "2026-02-25", "recommendation": "Keep the prohibited-kinds contract in sync with the policy/admission surface (deny new access-plane kinds by default).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Keep the prohibited-kinds contract in sync with the policy/admission surface (deny new access-plane kinds by default).", "topic": "tenant-pr-flow-validation-gates-adoption"}
{"class": "actionable", "details": "- Prohibited-kinds contract + validator script:\n  - `shared/contracts/tenant-prohibited-kinds.yaml`\n  - `shared/scripts/tenant/validate-prohibited-kinds.sh`", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:398d70e30a336e8c554c570589c052527fb2831b526f4c109bb989b4546f4e3f", "last_seen_at": "2026-02-25", "recommendation": "Prohibited-kinds contract + validator script:", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Prohibited-kinds contract + validator script:", "topic": "tenant-pr-flow-validation-gates-adoption"}
{"class": "actionable", "details": "- Tenant repo \u201chappy path\u201d guide + gate runner:\n  - `docs/guides/tenant-repo-layout-and-pr-gates.md`\n  - `shared/scripts/tenant/run-tenant-pr-gates.sh`", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:3e519733a11314bf6d094eacc8f8056b491bc9b66c4b9b24ad69ec253b1b2be5", "last_seen_at": "2026-02-25", "links": ["docs/guides/tenant-repo-layout-and-pr-gates.md"], "recommendation": "Tenant repo \u201chappy path\u201d guide + gate runner:", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Tenant repo \u201chappy path\u201d guide + gate runner:", "topic": "tenant-pr-flow-validation-gates-adoption"}
{"class": "actionable", "details": "- Tenant AppProject templates (org-scoped + project-scoped) that deny cluster-scoped and access-plane resources by default:\n  - `platform/gitops/apps/tenants/_templates/appproject-tenant-org.yaml`\n  - `platform/gitops/apps/tenants/_templates/appproject-tenant-project.yaml`", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:ae434de8a21e5d05fda1a714d79aa12e866063a88eff2bfafb7a735ee96bd688", "last_seen_at": "2026-02-25", "recommendation": "Tenant AppProject templates (org-scoped + project-scoped) that deny cluster-scoped and access-plane resources by default:", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Tenant AppProject templates (org-scoped + project-scoped) that deny cluster-scoped and access-plane resources by default:", "topic": "tenant-pr-flow-validation-gates-adoption"}
{"class": "actionable", "details": "- Evidence (repo-only): ", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:e21cb3f1a2399c1eb69e24d9c4b517e9aec0711b7d54d301bea78397bef29729", "last_seen_at": "2026-02-25", "links": [], "recommendation": "Evidence (repo-only): ", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Evidence (repo-only): ", "topic": "tenant-pr-flow-validation-gates-adoption"}
{"class": "actionable", "details": "- Evidence (prod rollout): ", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:6482b714adfdbc9238dd31cc74f336f4ee0bf81120ce35c51f790b9bfd4bbd56", "last_seen_at": "2026-02-25", "links": [], "recommendation": "Evidence (prod rollout): ", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Evidence (prod rollout): ", "topic": "tenant-pr-flow-validation-gates-adoption"}
{"class": "actionable", "details": "- Measure Argo reconcile latency under increasing `Application` counts (dev first), then ratify Tier S0/S1 ceilings as measured budgets.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:c04b3a9669b9813d7fa0f96f476143e1f236d37e9224909b4430d048daad3804", "last_seen_at": "2026-02-25", "recommendation": "Measure Argo reconcile latency under increasing Application counts (dev first), then ratify Tier S0/S1 ceilings as measured budgets.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Measure Argo reconcile latency under increasing Application counts (dev first), then ratify Tier S0/S1 ceilings as measured budgets.", "topic": "scale-budgets-validation-and-tier-thresholds"}
{"class": "actionable", "details": "- Define the Tier S2 sharding plan:\n  - pick Argo CD sharding mechanism and allocation strategy\n  - implement sharding when S1 ceilings/SLOs require it\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-gitops-and-argo:499404b15bdf7b7c440e8274794fa0264ab1ebe6785a9a9b56081f14349c284c", "last_seen_at": "2026-02-25", "recommendation": "Define the Tier S2 sharding plan:", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define the Tier S2 sharding plan:", "topic": "scale-budgets-validation-and-tier-thresholds"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- Tier boundary: introduce `AppProject/platform` and make `default` deny-by-default (decision; see design doc).
- _2026-01-15_ – Implemented tenant AppProject templates + standardized tenant PR gate suite (repo-only evidence: ).
- _2026-01-15_ – Rolled out Argo project boundaries to prod (including migrating the root `platform-apps` `Application` to `spec.project: platform`).
- _2026-01-16_ – Implemented the canonical tenant intent folder contract and wired tenant intent `Application`s into `platform-apps` without enabling ApplicationSet.
- _2026-01-20_ – Instantiated tenant `AppProject`s from the tenant registry and moved tenant intent `Application`s off `project: platform` into per-project `tenant-intent-<orgId>-p-<projectId>` `AppProject`s.
- _2026-01-21_ – Enforced tenant PR gate suite as a required PR check (tenant repo CI workflow template + Forgejo protected-branch enforcer CronJob).
- _2026-01-21_ – Implemented tenant Argo RBAC via `AppProject.spec.roles[].groups` (no per-tenant growth in global `argocd-rbac-cm`).
- Tier S2 strategy: shard Argo CD first; use Tier D (dedicated clusters) for isolation/contract triggers; multi-cluster control-plane topology remains a longer-term direction.
