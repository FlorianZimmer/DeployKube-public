# Design: Multi-Tenancy Storage Implementation (PVC + S3 + Backups)

Last updated: 2026-01-16  
Status: **Design + implementation (Phase 1: tenant storage guardrails + tenant-facing S3 primitive shipped; follow-ups planned)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy-storage.md`

## Related docs (inputs / constraints)

- Roadmap and “what we must not block”: `docs/design/cloud-productization-roadmap.md`
- Deployment identity contract (future knobs live here): `docs/design/deployment-config-contract.md`
- Tenancy model and label invariants: `docs/design/multitenancy.md`
- Label registry (contract): `docs/design/multitenancy-label-registry.md`
- Tenancy networking model + default-deny posture: `docs/design/multitenancy-networking.md`
- Policy engine + tenant baseline constraints (quotas/PSS): `docs/design/policy-engine-and-baseline-constraints.md`
- Standard profile NFS backend: `docs/design/out-of-cluster-nfs.md`
- Storage contracts and single-node profile: `docs/design/storage-single-node.md`
- Multi-node storage placeholder: `docs/design/storage-multi-node-ha.md`
- DR/backup contract: `docs/design/disaster-recovery-and-backups.md`
- Stack reality (versions + shipped components): `target-stack.md`

## Scope / ground truth

This design is **repo-grounded**. It describes:
- how storage is represented in GitOps (`platform/gitops/**`),
- how it is constrained by the multitenancy contracts (labels, RBAC, policy),
- and how it evolves from today’s single-site storage to future HA storage.

It does **not** claim live cluster state.

MVP scope reminder:
- Queue #11 implements **Tier S (shared-cluster)** multitenancy storage guardrails and tenant-facing primitives only.
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for the MVP, but Tier S work must not block them:
  - keep `shared-rwo` and the S3 env var contract stable across backends (NFS/Garage today; Ceph/RGW later),
  - avoid assumptions that the NFS server / backup target / Garage are the “forever” backend.

---

## 1) Problem statement

DeployKube’s multitenancy model (Org/Project/VPC) is label-driven and GitOps-first (`docs/design/multitenancy.md`), but storage is still largely “single-tenant platform” shaped:

- PVC persistence uses `shared-rwo` with environment-specific backends (NFS in standard profiles; node-local in the single-node profile). (`target-stack.md`, `docs/design/storage-single-node.md`)
- Object storage is a single Garage S3 endpoint with a platform-owned key and platform buckets. (`platform/gitops/components/storage/garage/**`)
- DR backups exist for the platform footprint, but not yet as a “per-tenant product surface”. (`docs/design/disaster-recovery-and-backups.md`, `platform/gitops/components/storage/backup-system/**`)

To productize tenancy (roadmap Phase 1+), we need an explicit, implementable storage model that:
- preserves stable workload contracts (`shared-rwo` + S3 env var contract),
- prevents cross-tenant data access and “backend reachability” bypasses,
- provides noisy-neighbor controls (quotas, budgets),
- and cleanly evolves into the future HA storage strategy (Ceph) without rewriting apps.

---

## 2) Repo reality today (what exists)

### 2.1 PVC contract and backends (implemented)

Workloads rely on stable StorageClass names:
- `shared-rwo` (default)
- `shared-rwx` (multi-node only; **not shipped by default today**)

Backends by profile:
- **Standard profiles** (`mac-orbstack`, `proxmox-talos`): `shared-rwo` is NFS-backed via `nfs-subdir-external-provisioner`. (`platform/gitops/apps/base/storage-nfs-provisioner.yaml`, `platform/gitops/components/storage/shared-rwo-storageclass/**`, `docs/design/out-of-cluster-nfs.md`)
- **Single-node profile v1** (`mac-orbstack-single`): `shared-rwo` is node-local via `local-path-provisioner`, and the NFS provisioner app is removed. (`platform/gitops/components/storage/local-path-provisioner/**`, `platform/gitops/apps/environments/mac-orbstack-single/patches/patch-storage-shared-rwo-local.yaml`, `docs/design/storage-single-node.md`)

### 2.2 Object storage contract (implemented)

- Garage provides an in-cluster S3 endpoint (single-node, 1 replica) and an S3 env var contract intended to mirror the future Ceph RGW contract. (`platform/gitops/components/storage/garage/README.md`)
- Garage ingress is restricted by `NetworkPolicy/garage-ingress` (`platform/gitops/components/storage/garage/base/networkpolicy.yaml`):
  - S3 (`:3900`) is allowlisted for platform consumers and explicit tenant identities (label-keyed; no broad “all tenants” allow).
  - RPC (`:3901`) + admin (`:3903`) are garage-internal only.
- Optional tenant-facing S3 primitive exists (M6):
  - `CronJob/garage-tenant-s3-provisioner` provisions per-tenant buckets and writes credentials to Vault under `tenants/<orgId>/s3/<bucketName>` (KV mount `secret/`).
  - Tenant workloads consume a platform-owned `Secret` projected by ESO (tenants do not author ESO CRDs).

### 2.3 Backup plane baseline (implemented for prod)

- `backup-system` mounts an off-cluster NFS export as `backup-system/PVC backup-target` and runs continuous smokes plus a platform S3 mirror tier. (`platform/gitops/components/storage/backup-system/**`, `docs/design/disaster-recovery-and-backups.md`, `docs/guides/backups-and-dr.md`)
- Tier-0 producers (Vault, Postgres) write artifacts and `LATEST.json` markers under `/backup/<deploymentId>/tier0/**` (NFS-backed in prod). (`docs/guides/backups-and-dr.md`)

### 2.4 Tenant baseline constraints (implemented)

When a namespace is labeled `darksite.cloud/rbac-profile=tenant`, the baseline includes:
- default-deny ingress/egress + DNS allow (`NetworkPolicy` generated by Kyverno),
- PodSecurity “restricted” enforced by Kyverno,
- baseline `ResourceQuota` including `requests.storage` and `persistentvolumeclaims`. (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`, `docs/design/policy-engine-and-baseline-constraints.md`)

---

## 3) Goals

1) **Stable workload interfaces across storage backends**
- PVCs keep using `shared-rwo` (and later `shared-rwx` when we explicitly ship it).
- Object storage keeps using the S3 env var contract (`S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, bucket names). (`docs/design/storage-single-node.md`)

2) **Tenant isolation that does not rely on “people doing the right thing”**
- Tenants must not be able to access other tenants’ PVC or object-store data.
- Tenants must not be able to “bypass” Kubernetes by talking to backend storage endpoints directly (NFS, backup target, future Ceph control plane).

3) **Noisy-neighbor controls**
- Baseline quotas exist; multi-tenant storage needs explicit budgets and an upgrade path to per-tenant sizing profiles (without hand-editing Kyverno templates for every tenant). (`docs/design/multitenancy.md#dk-mt-k8s-mapping`, `docs/design/policy-engine-and-baseline-constraints.md`)

4) **DR and backups are tenant-aware**
- The backup plane must be able to scope backups, freshness checks, and encryption boundaries per tenant (org). (`docs/design/disaster-recovery-and-backups.md`)

5) **Roadmap-compatible evolution**
- Phase 1: shared-cluster tenancy with clear limits and guardrails.
- Phase 2/3: dedicated clusters/nodes for hard isolation.
- Phase 5: multi-zone storage for tier-0 state (separate design, but this doc must not block it). (`docs/design/cloud-productization-roadmap.md`)

---

## 4) Non-goals (for this design)

- Claiming that shared-cluster tenancy is side-channel resistant (that requires dedicated clusters/hardware pools; see multitenancy tiers in `docs/design/multitenancy.md`).
- Multi-zone/site HA storage (Phase 5).
- In-place PVC backend migration; supported migration remains “rebuild + restore”. (`docs/design/storage-single-node.md`, `docs/design/disaster-recovery-and-backups.md`)
- Introducing a bespoke “storage controller” in v1; prefer Jobs/CronJobs + clear folder contracts, and only add CRDs once the contract is stable and budgets justify it.

---

## 5) Threat model (storage-specific)

We explicitly model:

- **S1: Cross-tenant data read/write**
  - mounting another tenant’s PV data (PVC/PV backend),
  - reading another tenant’s S3 objects,
  - reading another tenant’s backup artifacts on the backup target.

- **S2: Backend reachability bypass**
  - tenant workloads directly connect to NFS/backup endpoints (e.g., user-space NFS client),
  - tenant workloads connect to Garage admin APIs,
  - tenant workloads connect to future Ceph MON/RGW admin endpoints.

- **S3: Storage noisy neighbor / exhaustion**
  - runaway PVC requests,
  - unbounded object-store usage,
  - backup plane thrash (too many repos/jobs).

- **S4: Secret exfiltration via “secret tooling”**
  - letting tenants create `ExternalSecret` resources would allow them to materialize arbitrary Vault secrets because ESO is a platform-wide reader.
  - therefore, “secrets projection objects” are treated as access-plane resources for tenants (GitOps-only and RBAC-restricted).

This design focuses on eliminating S1/S2/S4 by contract + guardrails, and bounding S3 via quotas and budgets.

---

## 6) The storage planes (what we separate)

### 6.1 Workload PVC plane

PVC-backed state for platform and tenant workloads.

Contract surface:
- StorageClass names (`shared-rwo`, later `shared-rwx`)
- PVC labels for backup discovery (`darksite.cloud/backup=restic|native|skip`). (`docs/design/disaster-recovery-and-backups.md`)

### 6.2 Object storage plane (S3)

S3-compatible endpoint (Garage today; Ceph RGW later).

Contract surface:
- S3 env vars and bucket names (`S3_*`, `BUCKET_*` / workload-specific buckets). (`docs/design/storage-single-node.md`)

### 6.3 Backup plane (off-cluster)

Out-of-cluster backup target (v1: NFS export) mounted in-cluster in `backup-system` and used by Jobs/CronJobs.

Contract surface:
- DeploymentConfig `spec.backup.*` (target + schedules/retention). (`platform/gitops/deployments/*/config.yaml`, `docs/design/deployment-config-contract.md`)
- Backup target directory layout and marker freshness contracts. (`docs/design/disaster-recovery-and-backups.md`, `docs/guides/backups-and-dr.md`)

---

## 7) Storage backends and tenancy offerings

This section maps *tenancy offering* → *storage posture*. The key point is: **shared-cluster tenancy is not the hard isolation tier**, so we do not over-promise by trying to “fix” hostile co-tenancy with NFS tricks.

### 7.1 Tier S (Shared / Standard) — shared cluster, logical isolation

Allowed backends:
- standard profiles (`shared-rwo` NFS-backed)
- single-node profile (`shared-rwo` local-path) for dev/labs

Storage guarantees:
- Kubernetes namespace scoping + RBAC prevent tenants from binding arbitrary PV backends.
- Tenant baseline (PSS restricted) blocks privileged/host patterns.

Mandatory guardrails for Tier S:
- Tenants must not be able to **directly reach** backend endpoints (NFS server IPs, backup target IPs, Garage admin ports).
- Tenants must not be able to author “secret projection” resources (e.g., `ExternalSecret`) in their namespaces.

### 7.2 Tier D/H (Dedicated) — org-per-cluster (and optionally hardware-separated)

Allowed backends (target):
- Ceph profile for PVCs and S3:
  - **PVCs**: Ceph **RBD** (backs `shared-rwo`).
  - **S3**: Ceph **RGW** (replaces Garage for production / dedicated tiers).
  - **(Optional)** CephFS only when we explicitly ship `shared-rwx` (and have clear workloads that need it).

Rationale:
- Dedicated tenancy simplifies storage isolation and makes “per-tenant blast radius” credible.
- It aligns with the roadmap’s “hosted multi-customer with hard isolation” story. (`docs/design/cloud-productization-roadmap.md`, `docs/design/multitenancy.md`)

**Note:** `docs/design/storage-multi-node-ha.md` is still a placeholder; Ceph is the intended direction but not implemented in-repo yet.

---

## 8) Multi-tenant PVC design (shared cluster)

### 8.1 The baseline isolation story (what already works)

- PVCs are namespaced; tenants can only create PVCs in their namespaces.
- Tenants do not have cluster-scoped RBAC, so they cannot create PVs/StorageClasses/CSI objects to point at arbitrary backends. (RBAC contract; see `docs/design/multitenancy.md` + `docs/design/cluster-access-contract.md`)

This is necessary but not sufficient: if a tenant can reach the backend endpoint directly (S2), they can bypass Kubernetes scoping.

### 8.2 Required guardrail: block tenant access to backend endpoints (implemented; Kyverno validate)

Clarification (GitOps + ownership model):
- Tenant namespaces are GitOps-managed; tenants must not be able to `kubectl apply` NetworkPolicies directly.
- “Tenant exception NetworkPolicies” are PR-authored YAML applied by Argo CD (same workflow as everything else).

For Tier S, the safest low-complexity invariant is: **tenant namespaces do not get direct egress to arbitrary IPs**.
- Enforce via Kyverno validation: deny any tenant `NetworkPolicy` that uses `ipBlock`.
- Consequence: off-cluster storage backends (NFS server IPs, backup target IPs) are unreachable from tenant pods even if someone tries to “open egress”.
  - Examples (proxmox-talos/prod):
    - `shared-rwo` NFS server: `198.51.100.10`
    - Backup target NAS (v1): `198.51.100.11`

Implementation note:
- This must be an explicit Kyverno **validate** policy scoped to tenant namespaces (not just “best effort review”), tracked under:
  - `docs/component-issues/multitenancy-networking.md`
  - `docs/component-issues/multitenancy-storage.md`

Enforcement surfaces (v1):
- Kyverno: `ClusterPolicy/tenant-deny-networkpolicy-ipblock` (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-deny-networkpolicy-ipblock.yaml`)
- Evidence: `tests/scripts/tenant-storage-guardrails-smoke.sh` (server-side dry-run negative tests)

This is aligned with the networking contract: external egress for tenants is via a platform-managed egress gateway/proxy, not per-namespace `ipBlock` allowlists. (`docs/design/multitenancy-networking.md`)

### 8.3 Required guardrail: restrict tenant storage capability surface (implemented; Kyverno validate)

Add tenant-scoped policy (Kyverno) to enforce:
- Allowed StorageClasses for tenant PVCs (default allow-list: `shared-rwo`; later `shared-rwx` only when explicitly enabled).
- Access mode limits per deployment profile (e.g., disallow `ReadWriteMany` on Tier S profiles).

Implementation note:
- This must be a Kyverno **validate** policy (PVC shape guardrails) scoped to `darksite.cloud/rbac-profile=tenant`, and promoted to Tier S only once smoke tests exist.

This prevents accidental “RWX creep” and makes the storage contract product-closed.

Enforcement surfaces (v1):
- Kyverno: `ClusterPolicy/tenant-pvc-storageclass-allowlist` (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-pvc-storageclass-allowlist.yaml`)
- Kyverno: `ClusterPolicy/tenant-pvc-deny-rwx` (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-pvc-deny-rwx.yaml`)
- Evidence: `tests/scripts/tenant-storage-guardrails-smoke.sh` (server-side dry-run negative tests)

### 8.4 Quotas and sizing profiles (planned)

Repo reality: tenant namespaces get a fixed baseline quota today (`requests.storage=10Gi`, `persistentvolumeclaims=20`). (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`)

We need a way to *increase* quotas per tenant/project without editing the global Kyverno template for every exception.

Proposed approach:
- Introduce a namespace label such as `darksite.cloud/quota-profile=<small|medium|large>`.
- Implement multiple Kyverno generate rules keyed by that label that generate `ResourceQuota/tenant-quota` with different values.
  - The rules must be mutually exclusive and have deterministic precedence.
  - A smoke test must prove each profile enforces as expected.

---

## 9) Multi-tenant object storage (S3) design

There are two distinct needs:

1) **Platform-internal S3** (observability buckets, backup scratch, etc.)  
   Tenants do not receive platform S3 keys; they interact with platform services (Loki/Tempo/Mimir, backup plane) rather than S3 directly.

2) **Tenant-facing S3** (optional offering / marketplace primitive)  
   Tenants get their own S3 credentials scoped to their buckets, sourced from Vault and projected into their namespaces.

This design defines (2) without weakening (1).

Key boundary statement:
- Tenant-facing S3 is the only case where tenant workloads receive S3 credentials.
- Platform-managed services remain “managed”: tenants talk to APIs, and never receive platform S3 keys/buckets.

### 9.1 Bucket scoping decision (recommended)

Prefer **per-tenant buckets** over “shared bucket + prefix” for tenant-facing S3.

Why:
- Bucket-level ACL/policy is the lowest common denominator across Garage and future Ceph RGW.
- Prefix-scoped IAM policies are not consistently available (and Garage’s permission model is not a full AWS IAM superset).
- It makes backup mirroring and incident response simpler (per-tenant bucket list is explicit).

Granularity (recommended v1 default):
- Buckets are **org-scoped** (keyed by `darksite.cloud/tenant-id=<orgId>`), not “shared across orgs”.
- If a tenant wants separation within the org (per project/app), it should use multiple buckets (still within the same `orgId`).

### 9.2 Vault path contract for tenant S3 credentials (implemented)

Store tenant S3 credentials under a tenant-scoped prefix, for example:
- logical key path (Vault UI/CLI and ESO `remoteRef.key`): `tenants/<orgId>/s3/<bucketName>`
- policy/API paths (KV v2 mount `secret/`):
  - `secret/data/tenants/<orgId>/s3/<bucketName>`
  - `secret/metadata/tenants/<orgId>/s3/<bucketName>`

This follows the tenant Vault path conventions in `docs/design/multitenancy-secrets-and-vault.md`.

Values (align to the S3 contract):
- `S3_ENDPOINT`, `S3_REGION`
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`
- `S3_BUCKET` (or workload-specific env var keys)

### 9.3 Provisioning model (implemented; GitOps-only)

Tenants must not create buckets/keys directly. Provisioning is platform-owned and Git-triggered.

Recommended v1 pattern:
- A platform-owned Job runs with access to:
  - Garage admin endpoint and token (`GARAGE_ADMIN_TOKEN`) in `garage` namespace (`platform/gitops/components/storage/garage/base/externalsecret-credentials.yaml`),
  - Vault write permissions for the tenant S3 path (via Kubernetes auth role scoped to that job’s ServiceAccount),
  - and a Git-sourced “desired buckets” list for the tenant.
- The Job is idempotent:
  - create bucket if missing,
  - create/import key if missing,
  - write/update Vault secret for that tenant bucket.
- An `ExternalSecret` (owned by platform GitOps) in the tenant namespace projects the Vault secret into a Kubernetes Secret consumed by tenant workloads.

Repo reality (v1):
- Desired buckets are expressed as Kubernetes `ConfigMap` intents in the `garage` namespace (Git-managed) with label `darksite.cloud/tenant-s3-intent=true` and `data.intent.json` containing `{orgId,bucketName}`.
- Provisioner: `platform/gitops/components/storage/garage/base/cronjob-tenant-s3-provisioner.yaml`.
- Vault auth role/policy is reconciled by: `platform/gitops/components/secrets/vault/config/tenant-s3-provisioner-role.yaml`.
- Projection into tenant namespaces is platform-owned via ESO `ExternalSecret` resources (examples under `platform/gitops/tenants/<orgId>/projects/<projectId>/namespaces/<env>/externalsecret-tenant-s3-*.yaml`).

**Critical guardrail**: tenants must not be able to create/update `ExternalSecret` (or any ESO CRD) in tenant namespaces.
- Enforce in at least two layers (Tier S requirement): Argo `AppProject` deny + Kubernetes RBAC deny (defense-in-depth: Kyverno/VAP deny).
- Rationale and phased ESO model: `docs/design/multitenancy-secrets-and-vault.md`.

Enforcement surfaces (v1):
- Kyverno: `ClusterPolicy/tenant-deny-external-secrets` (`platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-deny-external-secrets.yaml`)
- Evidence: `tests/scripts/tenant-storage-guardrails-smoke.sh` (server-side dry-run negative tests)

### 9.4 Network exposure guardrails (implemented)

Garage already has an ingress allowlist (`NetworkPolicy/garage-ingress`). For multitenancy, extend/tighten this posture:
- Keep S3 (`:3900`) allowlisted and add **explicit per-tenant allow rules** keyed by tenant identity (prefer `namespaceSelector` on a stable tenant label; avoid a global “all tenants” allow).
- Keep RPC/admin ports garage-internal only; do not allow tenant namespaces to reach admin surfaces (bootstrap/provisioning remains platform-owned).

Additionally, because tenant baseline egress is deny-by-default, tenant-facing S3 requires an explicit tenant egress allow `NetworkPolicy`:
- allow egress only to the Garage S3 port (`3900`) in the `garage` namespace
- keep all other egress denied (DNS aside), and keep `ipBlock` disallowed in tenant namespaces (see 8.2)

This is required to prevent “tenant probes the admin API” and to keep S2 closed.

---

## 10) Multi-tenant backups / DR design

### 10.1 Baseline principle

Treat the backup target as hostile: **encryption boundaries are per tenant**.

At minimum:
- separate restic repositories per tenant (or per tenant/project) with distinct passwords,
- separate bucket lists per tenant for S3 mirroring,
- per-tenant freshness markers and alerting surfaces.

### 10.2 Backup target layout (v1)

Align with current repo layout (`docs/guides/backups-and-dr.md`) and extend it with an explicit tenant subtree (v1 ships the tenant S3 mirror + per-tenant markers; additional “recovery bundle” material remains future):

```
/backup/<deploymentId>/
  tier0/                 # platform tier-0 (existing)
  s3-mirror/             # platform S3 mirror (existing)
  tenants/
    <orgId>/
      s3-mirror/
        LATEST.json
        buckets/tenant-<orgId>-backups/...   # includes restic repo(s) under pvc-restic/projects/<projectId>/...
      recovery/                       # tenant-scoped recovery bundle material (future)
```

**Design choice:** keep platform tier-0 at the current paths to avoid a migration blocker; later we may unify “platform is a tenant” once tenant backups ship.

### 10.3 Backup scoping (implemented, v1)

Use explicit, label-driven scoping:
- Namespaces must opt into the backup plane (recommendation already in `docs/design/disaster-recovery-and-backups.md`).
- PVCs must carry the backup label contract (`darksite.cloud/backup=...`), which is already linted for platform workloads (`tests/scripts/validate-pvc-backup-labels.sh`).

For tenants, we extend this with a “tenant backup contract”:
- tenant namespaces intended to be backed up carry `darksite.cloud/backup-scope=enabled`
- backup plane enumerates namespaces with that label and groups by `darksite.cloud/tenant-id`
- backup plane produces per-tenant markers and enforces per-tenant freshness SLAs.

Repo reality (v1):
- Backup scope discovery is label-driven: `Namespace` objects with `darksite.cloud/backup-scope=enabled`.
- Provisioning is platform-owned:
  - Vault reconciler: `platform/gitops/components/secrets/vault/config/tenant-backup-provisioner-role.yaml` (per-project Vault policies and Kubernetes auth roles for the Garage provisioner).
  - Garage provisioner: `platform/gitops/components/storage/garage/base/cronjob-tenant-backup-provisioner.yaml` (per-tenant bucket + per-project restic credential material under Vault `secret/tenants/<orgId>/projects/<projectId>/sys/backup`).
  - Mirror to backup target: `platform/gitops/components/storage/backup-system/base/cronjob-s3-mirror.yaml` (per-tenant `LATEST.json` markers under `/backup/<deploymentId>/tenants/<orgId>/s3-mirror/`).
- Evidence (prod):.

### 10.4 Backup plane scale budgets (required before productizing shared-cluster tenants)

Before enabling shared-cluster onboarding for “real tenants”, record budgets:
- max tenant namespaces backed up per cluster
- max PVCs backed up per tenant and total
- max restic repos (and why)
- max per-hour backup IO on the NAS

If budgets are exceeded, the design must include a “switch threshold” to:
- dedicated clusters per tenant, and/or
- a Ceph-backed profile with snapshot-based backups (future).

---

## 11) GitOps expression (folder contract) — proposed

This design assumes the folder contract direction in `docs/design/multitenancy.md` (planned), and adds a storage subtree.

Repo reality (v1):
- Tenant-facing S3 bucket intent is expressed as Kubernetes `ConfigMap` objects in the `garage` namespace (Git-managed) and lives under the per-project namespace intent bundles (see §9.3).
- The `storage/s3/buckets/` subtree below remains a future refactor once we introduce a stable “tenant root kustomization” that can safely aggregate storage and namespace intent without fighting Kustomize load restrictions.

```
platform/gitops/tenants/<orgId>/
  projects/
    <projectId>/
      namespaces/
        <env>/
          <namespaceName>.yaml     # Namespace + labels (tenant-id/project-id/vpc-id)
  storage/
    README.md
    s3/
      buckets/
        <bucketName>.yaml          # intent-level (no CRD required in v1)
    backup/
      scope.yaml                   # namespaces included, retention overrides (future)
```

In v1 (no new CRDs), the “intent” files are consumed by platform-owned Jobs/automation that render the concrete Kubernetes resources:
- ExternalSecrets for tenant bucket credentials (platform-owned)
- NetworkPolicies for tenant S3 ingress/egress (platform-owned; tenant-requested via PR)
- Backup plane config for which tenants/namespaces are included

---

## 12) DeploymentConfig extensions (planned)

To keep “profile selection” declarative and prevent per-env patch sprawl, extend the DeploymentConfig contract (`docs/design/deployment-config-contract.md`) with:

- `spec.storage.profile: standard-nfs | local-single-node | ceph`

---

## 13) Implementation plan (staged)

1) **Close the S2/S4 gaps (shared-cluster safety)**
   - Add Garage NetworkPolicies (restrict admin + scope S3 access).
   - Ensure tenant RBAC forbids creating/updating `ExternalSecret` (and similar “secret projection” objects).
   - Add tenant policies to restrict PVC StorageClasses and RWX usage.
   - Add tenant guardrail for backend endpoint reachability (NFS + backup target).

2) **Ship tenant-facing S3 as an optional primitive**
   - Add tenant bucket provisioning Job pattern (Garage now; RGW later).
   - Vault path + ESO projection contract.
   - Evidence: smoke Job can read/write only its bucket; cannot list platform buckets.

3) **Make the backup plane tenant-aware**
   - Add config-driven tenant allow-list (do not “scan all buckets/dirs”).
   - Implement per-tenant restic repos + markers + freshness checks.
   - Evidence: per-tenant restore drill on dev/staging.

4) **Fill in the Ceph multi-node design and implement it**
   - Expand `docs/design/storage-multi-node-ha.md` into an implementable plan (start with Ceph RBD + RGW; add CephFS only when `shared-rwx` is explicitly shipped).
   - Keep workload contracts unchanged (`shared-rwo/shared-rwx`, S3 env vars).

---

## 14) Decisions (recommended defaults)

These are the recommended defaults this design assumes. Remaining implementation TODOs live in the canonical tracker.

- **NetworkPolicy authoring (tenant namespaces)**: tenants do not get Kubernetes RBAC to create/update `NetworkPolicy`. Exceptions are PR-authored and applied by Argo CD. Tenant `NetworkPolicy` objects must not use `ipBlock` (external egress is via a platform-managed egress gateway/proxy, not per-namespace `ipBlock` allowlists).
- **Tenant-facing S3 vs managed services**: tenant-facing S3 is an explicit opt-in primitive for tenant apps that truly need object storage (per-tenant buckets + per-tenant credentials from Vault). Platform-managed services remain “managed” (tenants never receive platform S3 keys/buckets).
- **Ceph minimal viable footprint (Phase 2/3)**: start with **Ceph RBD + RGW** (covers `shared-rwo` + S3). Add **CephFS** only when we explicitly ship `shared-rwx` and have concrete workloads that need it.
- **Per-tenant object-store quotas and switch thresholds**:
  - v1 (Garage): treat quotas as **soft** (budgets + metering + alerting + key disable/escalation), because Garage may not provide a strong, portable per-tenant quota surface.
  - Phase 2/3 (RGW): use **native RGW quotas** (per user/bucket) as the hard enforcement layer.
  - Before productizing shared-cluster tenants, record budgets (bucket count per tenant, total GiB per tenant, cluster-level total object-store GiB, and an explicit “too big ⇒ dedicated/Ceph” switch threshold).
