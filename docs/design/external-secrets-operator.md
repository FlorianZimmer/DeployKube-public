# External Secrets Operator (ESO) Design

Status: Design + implementation

## Tracking

- Canonical tracker: `docs/component-issues/external-secrets.md`
- Related docs:
  - `docs/design/openbao-secret-plane-kms-shim.md`
  - `docs/design/multitenancy-secrets-and-vault.md`
  - `docs/design/cluster-access-contract.md`

## Purpose

Define ESO's role as the secret projection plane from Vault/OpenBao into Kubernetes and document its security boundaries.

## Scope

In scope:
- ESO controller posture and secret projection responsibilities.
- Store model and tenancy boundary constraints.
- Operational expectations for readiness, sync, and failure handling.

Out of scope:
- Vault/OpenBao backend internals and seal model.
- App-specific secret data schemas.

## Architecture

1. Source of truth:
- Secret material is owned in Vault/OpenBao paths.

2. Projection plane:
- ESO reconciles `ExternalSecret` and store resources into namespaced Kubernetes `Secret` objects.

3. Trust path:
- `ClusterSecretStore` (and scoped stores where applicable) define how ESO authenticates and reads from Vault/OpenBao.

## Security boundaries

- ESO is platform-owned; tenant write access to ESO CRDs is constrained by policy/RBAC in Tier S shared-cluster mode.
- Secret projection objects are treated as access-plane-sensitive in multitenant contexts.
- Transport hardening and CA trust posture are tracked explicitly in the external-secrets and vault trackers.

## Implementation map (repo)

- ESO component: `platform/gitops/components/secrets/external-secrets/`
- Vault/OpenBao component: `platform/gitops/components/secrets/vault/`
- Tenant ESO constraints and patterns: `docs/design/multitenancy-secrets-and-vault.md`

## Invariants

- No plaintext credentials committed to Git.
- Store readiness and projection freshness must be observable and actionable.
- Secrets consumed by platform control-plane components remain declaratively managed via GitOps + ESO.

## Validation and evidence

Primary signals:
- ESO smoke verifies store readiness and projected-secret success.
- policy/guardrail tests confirm tenant boundaries for ESO resources.
- evidence notes capture readiness and reconciliation verification.
