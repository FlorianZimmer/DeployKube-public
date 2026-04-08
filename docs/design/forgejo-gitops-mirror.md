# Forgejo GitOps Mirror Design

Status: Design + implementation

## Tracking

- Canonical tracker: `docs/component-issues/forgejo.md`
- Related docs:
  - `docs/design/gitops-operating-model.md`
  - `docs/design/offline-bootstrap-and-oci-distribution.md`
  - `docs/design/multitenancy-gitops-and-argo.md`

## Purpose

Define Forgejo's role as the Git source that Argo CD consumes, plus the platform contracts around bootstrap seeding, repository custody, and tenant-facing Git boundaries.

## Scope

In scope:
- Platform mirror repo model and seeding contract.
- Forgejo availability and security posture relevant to GitOps control-plane continuity.
- Boundaries between platform-owned repos and tenant-owned repos.

Out of scope:
- Argo reconciliation internals (see `argocd-control-plane.md`).
- Registry/package distribution design (see `distribution-bundles.md` and `registry-harbor.md`).

## Architecture

1. Platform mirror:
- Argo CD reads desired state from Forgejo repository `platform/cluster-config`.
- The mirror is seeded from this monorepo's `platform/gitops/` tree.

2. Bootstrap model:
- Stage 0/1 establish Forgejo and seed the mirror.
- After bootstrap, all platform changes continue through GitOps PR flow and reconcile.

3. Tenant boundary:
- Tenant repositories are separate from platform mirror custody.
- Platform-side Argo/AppProject rules control what tenant repos can apply.

## Security and custody contracts

- Mirror seeding uses root git `HEAD`; uncommitted changes are excluded.
- Seeding and repo administration are privileged operations and require evidence.
- Platform credentials for automation are managed through Vault + ESO projections.

## Implementation map (repo)

- Forgejo base and app wiring: `platform/gitops/components/platform/forgejo/`
- Forgejo jobs (bootstrap/team sync): `platform/gitops/components/platform/forgejo/jobs/`
- Repo seeding helper: `shared/scripts/forgejo-seed-repo.sh`
- Tenant/project GitOps boundaries: `docs/design/multitenancy-gitops-and-argo.md`

## Invariants

- Argo source repository remains reachable and readable via declared credentials.
- Forgejo must preserve repo history integrity for auditability.
- Critical repo auth/custody changes must include rollback notes and operator runbook steps.

## Validation and evidence

Primary signals:
- Forgejo smoke checks pass in reconcile hooks.
- Argo repo connection remains healthy after Forgejo changes.
- Evidence notes capture verification commands and outcomes.
