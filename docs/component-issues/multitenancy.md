# multitenancy design issues

Canonical issue tracker for:
- `docs/design/multitenancy.md`
- `docs/design/multitenancy-label-registry.md`
- `docs/design/multitenancy-gitops-ux.md`
- `docs/design/multitenancy-contracts-checklist.md`

Implementation tracker:
- `docs/component-issues/multitenancy-implementation.md`

Related trackers:
- Multi-tenancy networking: `docs/component-issues/multitenancy-networking.md`
- Multi-tenancy storage: `docs/component-issues/multitenancy-storage.md`
- Argo CD: `docs/component-issues/argocd.md`
- Keycloak: `docs/component-issues/keycloak.md`
- Vault: `docs/component-issues/vault.md`
- Shared RBAC: `docs/component-issues/shared-rbac.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### identity-access-propagation
- Define and enforce budgets for OIDC group claims (token size) and group count per user. (ids: `dk.ca.finding.v1:multitenancy:f0cd4f379f20fcd0003cba7147047a4f6694c8b1c0b947a0669397eb827a6e99`)

#### mvp-scope-clarity-tier-s-now-do-not-block-d-h-later
- Ensure Tier S contracts stay portable: stable tenant identifiers and a GitOps layout that supports later “move to dedicated cluster” without renaming identities. (ids: `dk.ca.finding.v1:multitenancy:30d05541fd2d0afbbcd1c16e9f46de42a6daa99eba91f10c7b9c4eab30014b31`)

- Queue #11 implements Tier S (shared-cluster) multitenancy first; Tier D/H are explicitly out of scope for that queue. (ids: `dk.ca.finding.v1:multitenancy:a9f79a513bf1a783f578dd3e7cd974a664b0c2c2c25fd41736d66e9b5eafd213`)

#### operational-flows-support-migrations
- Document dedicated tenancy GitOps layout and a shared→dedicated migration runbook that preserves identifiers and evidence. (ids: `dk.ca.finding.v1:multitenancy:51595d6be77026a5c56b98f322d36384d57cb5cb99c1de80873137a4199b692c`)

- Implement a SupportSession-style time-bound exception mechanism with enforced expiry + evidence trail. (ids: `dk.ca.finding.v1:multitenancy:b6c23ac68daeab9b9e12574e869fc2792987941eb5ace88752218ba31c1f415c`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Queue #11 implements Tier S (shared-cluster) multitenancy first; Tier D/H are explicitly out of scope for that queue.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy:a9f79a513bf1a783f578dd3e7cd974a664b0c2c2c25fd41736d66e9b5eafd213", "last_seen_at": "2026-02-25", "recommendation": "Queue #11 implements Tier S (shared-cluster) multitenancy first; Tier D/H are explicitly out of scope for that queue.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Queue #11 implements Tier S (shared-cluster) multitenancy first; Tier D/H are explicitly out of scope for that queue.", "topic": "mvp-scope-clarity-tier-s-now-do-not-block-d-h-later"}
{"class": "actionable", "details": "- Ensure Tier S contracts stay portable: stable tenant identifiers and a GitOps layout that supports later \u201cmove to dedicated cluster\u201d without renaming identities.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy:30d05541fd2d0afbbcd1c16e9f46de42a6daa99eba91f10c7b9c4eab30014b31", "last_seen_at": "2026-02-25", "recommendation": "Ensure Tier S contracts stay portable: stable tenant identifiers and a GitOps layout that supports later \u201cmove to dedicated cluster\u201d without renaming identities.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Ensure Tier S contracts stay portable: stable tenant identifiers and a GitOps layout that supports later \u201cmove to dedicated cluster\u201d without renaming identities.", "topic": "mvp-scope-clarity-tier-s-now-do-not-block-d-h-later"}
{"class": "actionable", "details": "- Define and enforce budgets for OIDC group claims (token size) and group count per user.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy:f0cd4f379f20fcd0003cba7147047a4f6694c8b1c0b947a0669397eb827a6e99", "last_seen_at": "2026-02-25", "recommendation": "Define and enforce budgets for OIDC group claims (token size) and group count per user.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define and enforce budgets for OIDC group claims (token size) and group count per user.", "topic": "identity-access-propagation"}
{"class": "actionable", "details": "- Implement a SupportSession-style time-bound exception mechanism with enforced expiry + evidence trail.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy:b6c23ac68daeab9b9e12574e869fc2792987941eb5ace88752218ba31c1f415c", "last_seen_at": "2026-02-25", "recommendation": "Implement a SupportSession-style time-bound exception mechanism with enforced expiry + evidence trail.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Implement a SupportSession-style time-bound exception mechanism with enforced expiry + evidence trail.", "topic": "operational-flows-support-migrations"}
{"class": "actionable", "details": "- Document dedicated tenancy GitOps layout and a shared\u2192dedicated migration runbook that preserves identifiers and evidence.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy:51595d6be77026a5c56b98f322d36384d57cb5cb99c1de80873137a4199b692c", "last_seen_at": "2026-02-25", "recommendation": "Document dedicated tenancy GitOps layout and a shared\u2192dedicated migration runbook that preserves identifiers and evidence.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Document dedicated tenancy GitOps layout and a shared\u2192dedicated migration runbook that preserves identifiers and evidence.", "topic": "operational-flows-support-migrations"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

### 2026-01-21
- Implemented tenant Argo CD RBAC via `AppProject.spec.roles[].groups` (no per-tenant growth in global `argocd-rbac-cm`).

### 2026-01-15
- Implemented tenant namespace identity admission contract (VAP A2): require `darksite.cloud/project-id`, enforce DNS-label-safe identifiers, and deny identity label mutation (set-once immutability via CEL `oldObject`).

### 2026-01-14
- Implemented tenant RBAC propagation in `rbac-namespace-sync` (`tenant-id` + `project-id` → RoleBindings).

### 2026-01-20
- Made tenant RBAC propagation scale-safe (hash-annotated RoleBindings; skip unchanged; backoff under API pressure) and added smoke assertions for access-plane API non-grants.

### 2026-01-07
- Created a dedicated multitenancy implementation tracker to track milestone delivery and promotion gates separately from design issues.

### 2026-01-06
- Normalized the multitenancy GitOps folder contract examples, clarified the tenant `NetworkPolicy` `ipBlock` stance, and added a label registry.
