# DeployKube Multitenancy — Label Registry (Contract)

Last updated: 2026-01-15  
Status: **Contract (mix of implemented + planned; see each label)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy.md`

---

## Purpose

DeployKube multitenancy is **label-driven**. This document is the canonical registry for:
- which labels exist,
- what they mean,
- where they apply,
- and whether they are **identity** labels (immutable) vs **behavior** labels (mutable).

MVP scope reminder:
- Queue #11 implements **Tier S (shared-cluster)** multitenancy guardrails first.
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for the MVP.
- The label registry is deliberately **tier-agnostic**: labels represent stable org/project identity and policy intent, regardless of whether a tenant later runs in a shared or dedicated cluster.

Related:
- Core model + invariants: `docs/design/multitenancy.md`
- Contracts + enforcement checklist (single-page): `docs/design/multitenancy-contracts-checklist.md`
- Networking model: `docs/design/multitenancy-networking.md`
- Storage model: `docs/design/multitenancy-storage.md`

---

## 1) Rules of the road

### 1.1 Identity labels (immutability contract)
For tenant namespaces, these are **identity** labels and must be treated as immutable after creation.
- `darksite.cloud/rbac-profile`
- `darksite.cloud/tenant-id`
- `darksite.cloud/project-id`
- `darksite.cloud/vpc-id` (if present)
- `observability.grafana.com/tenant`

Rationale and migration implications are defined in `docs/design/multitenancy.md#dk-mt-label-immutability`.

Implementation note:
- Phase 1 (VAP A2) enforces immutability for `darksite.cloud/{tenant-id,project-id,vpc-id}`.
- Immutability for `darksite.cloud/rbac-profile` and `observability.grafana.com/tenant` remains planned (beyond Phase 1).

### 1.2 GitOps-only changes, admission-enforced invariants
Tenants do not get Kubernetes RBAC to create namespaces or change identity labels (per `docs/design/cluster-access-contract.md`).
However, identity mistakes are still possible (platform PRs, breakglass), so **core invariants must also be enforced by admission**:
- Phase 0 (implemented): `darksite.cloud/tenant-id == observability.grafana.com/tenant` when `rbac-profile=tenant` (VAP A1).
- Phase 1 (implemented): require `darksite.cloud/project-id`, validate identifier formats, and enforce **identity label immutability** using `oldObject` on UPDATE (VAP A2).

### 1.3 Status vocabulary (use in tables below)
- **Enforced (admission)**: denied by `ValidatingAdmissionPolicy` / CEL.
- **Enforced (generate)**: continuously reconciled into namespaces by Kyverno generate (drift-resistant baseline).
- **Convention (GitOps)**: required by repo workflow/templates/code review, but not currently admission-enforced.
- **Planned**: documented contract; enforcement not yet shipped.

---

## 2) Namespace labels

### 2.1 Identity (org/project/VPC)

| Label | Applies to | Required when | Meaning | Status |
|---|---|---|---|---|
| `darksite.cloud/rbac-profile` | `Namespace` | convention: all Git-managed non-system namespaces | Namespace classification (`platform`, `app`, `tenant`) | Convention (GitOps); admission enforcement planned |
| `darksite.cloud/tenant-id` | `Namespace` | `rbac-profile=tenant` | Org identifier (`orgId`) | Enforced (admission, VAP A1) |
| `observability.grafana.com/tenant` | `Namespace` | `rbac-profile=tenant` | Observability tenant identifier (must equal `tenant-id`) | Enforced (admission, VAP A1) |
| `darksite.cloud/project-id` | `Namespace` | `rbac-profile=tenant` | Project identifier (`projectId`) | Enforced (admission, VAP A2) |
| `darksite.cloud/vpc-id` | `Namespace` | optional | VPC attachment (`vpcId`) | Enforced (admission, VAP A2) |

Notes:
- The existing invariant `tenant-id == observability.grafana.com/tenant` is enforced today by a `ValidatingAdmissionPolicy` (VAP A1):
  `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-label-contract.yaml`
- Tenant identity contract (VAP A2: `project-id` required + DNS-label-safe values + identity label immutability):
  `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-identity-contract.yaml`
- Value constraints (required for safe Kubernetes resource names, Keycloak group names, and Vault paths):
  - `darksite.cloud/tenant-id`, `darksite.cloud/project-id`, `darksite.cloud/vpc-id` must be valid DNS labels:
    - `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
    - max length 63

### 2.2 Behavior (RBAC + policy)

| Label | Applies to | Required when | Meaning | Status |
|---|---|---|---|---|
| `darksite.cloud/rbac-team` | `Namespace` | `rbac-profile=app` | App/team identifier used by namespace RBAC sync | Implemented |
| `darksite.cloud/quota-profile` | `Namespace` | optional | Selects a quota preset (`small`, `medium`, `large`, …) | Planned |
| `darksite.cloud/backup-scope` | `Namespace` | optional | Opts a tenant namespace into the backup plane (recommended value: `enabled`) | Implemented |

---

## 3) PVC labels (backup discovery)

PVC backup label contract is defined in:
- `docs/design/disaster-recovery-and-backups.md`

This registry does not redefine that contract; it exists here only as a pointer because tenant storage design references it:
- `darksite.cloud/backup=restic|native|skip` (applies to PVCs)
