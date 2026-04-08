# Multitenancy PR-by-PR implementation queue

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
- (none)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

This file is the concrete execution queue for delivering multitenancy as a “working product” per the design docs.

Master ordering (repo-wide): `docs/component-issues/master-delivery-queue.md`

Canonical implementation tracker (milestones + gates): `docs/component-issues/multitenancy-implementation.md`

Scope reminder:
- Queue #11 delivers **Tier S (shared-cluster multitenancy)** only.
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for this queue; do not “half-implement” multi-cluster/hardware concerns here.
- Hard requirement: Tier S work must remain compatible with moving tenants/projects to dedicated tiers later (stable IDs; portable Git contracts; reusable enforcement layers).

---

## Promotion gates (Tier S0 → S1)

These are the “do not claim hostile tenants” gates. A gate is only considered met when it has:
1) enforcement in manifests (admission/policy/Argo/RBAC), and
2) at least one evidence note under `docs/evidence/`.

- **G1 Identity:** tenant namespace identity labels enforced + immutable.
- **G2 Argo boundaries:** `AppProject/platform` and `AppProject/default` deny-by-default; tenant AppProjects constrain destinations/repos/kinds.
- **G3 Tenant RBAC:** label-driven RBAC propagation; tenants cannot create namespaces/labels or access access-plane APIs (including ESO kinds).
- **G4 Networking:** ingress hijack prevention + tenant NetworkPolicy guardrails + mesh posture validated.
- **G5 Secrets:** tenant ESO self-service denied until a scoped-store model exists.
- **G6 Storage:** tenant PVC surface constrained + storage backends not reachable from arbitrary tenant namespaces.

---

## Queue

Notes:
- “PR” numbers below are the **queue order**, not an existing PR/forgejo number.
- Every PR should update the relevant `docs/component-issues/*.md` checklists and add exactly one evidence note.

| Done | PR | Title | Milestone | Gates | Trackers to update | Evidence note | Validation (minimum) |
|---:|---:|---|---|---|---|---|---|
| [x] | 1 | M0: Tenant registry + templates scaffold | M0 | — | `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 2 | Tenant PR static gates (folder contract + prohibited kinds + render) | M2 (enablement) | — | `docs/component-issues/multitenancy-gitops-and-argo.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 3 | OIDC/groups end-to-end validation path (repeatable) | Prereq | — | `docs/component-issues/access-guardrails.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 4 | M1: Tenant namespace identity contract (VAP) | M1 | G1 | `docs/component-issues/multitenancy.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 5 | M2: Argo `AppProject/platform` + migrate platform apps | M2 | G2 | `docs/component-issues/multitenancy-gitops-and-argo.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 6 | M2: Lock down `AppProject/default` deny-by-default | M2 | G2 | `docs/component-issues/multitenancy-gitops-and-argo.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 7 | M2: Tenant AppProject templates + tenant registry wiring | M2 | G2 | `docs/component-issues/multitenancy-gitops-and-argo.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 8 | M3: Tenant RBAC propagation via namespace sync | M3 | G3 | `docs/component-issues/shared-rbac.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 9 | RBAC reliability: smoke jobs + `rbac-system` NetworkPolicy | Prereq | — | `docs/component-issues/shared-rbac.md`, `docs/component-issues/shared-rbac-secrets.md` | — | `./tests/scripts/validate-validation-jobs.sh` |
| [x] | 10 | M4: Tenant NetworkPolicy guardrails (Kyverno validate) | M4 | G4 | `docs/component-issues/multitenancy-networking.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 11 | M4: Ingress hijack prevention (gateway allowedRoutes + route guardrails) | M4 | G4 | `docs/component-issues/multitenancy-networking.md`, `docs/component-issues/istio.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 12 | M4: Mesh posture fix + smokes for ingress→tenant backends | M4 | G4 | `docs/component-issues/multitenancy-networking.md`, `docs/component-issues/istio.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 13 | M5 (Phase 1): Deny tenant ESO CRDs (Argo+RBAC+policy) | M5 | G5 (+G3) | `docs/component-issues/multitenancy-secrets-and-vault.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 14 | ESO hardening: smoke + NP + PDB + securityContext | Hardening | — | `docs/component-issues/external-secrets.md` | — | `./tests/scripts/validate-validation-jobs.sh` |
| [x] | 15 | Vault hardening: smoke + NetworkPolicy | Hardening | — | `docs/component-issues/vault.md` | — | `./tests/scripts/validate-validation-jobs.sh` |
| [x] | 16 | M6: Tenant PVC guardrails (StorageClass allowlist + RWX restrictions) | M6 | G6 | `docs/component-issues/multitenancy-storage.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 17 | Garage NetworkPolicy (S3 plane restricted; admin blocked from tenants) | M6 | G6 | `docs/component-issues/garage.md`, `docs/component-issues/multitenancy-storage.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 18 | Tenant-facing S3 primitive (Git intent → provisioner job → Vault → projection) | M6 / catalog | G6 (+G5) | `docs/component-issues/multitenancy-service-catalog.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-validation-jobs.sh` |
| [x] | 19 | M7: Tenant-aware backups (markers + restore drill) | M7 | — | `docs/component-issues/backup-system.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 20 | M8: Support sessions (folder contract + TTL gate + cleanup flow) | M8 | — | `docs/component-issues/multitenancy-lifecycle-and-data-deletion.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 21 | M8: Offboarding toils (inventory → destructive wipe follow-up) | M8 | — | `docs/component-issues/multitenancy-lifecycle-and-data-deletion.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |
| [x] | 22 | M2: Instantiate tenant AppProjects + migrate tenant intent Applications | M2 | G2 | `docs/component-issues/multitenancy-gitops-and-argo.md`, `docs/component-issues/multitenancy-implementation.md` | — | `./tests/scripts/validate-design-doc-tracking.sh` |

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->
