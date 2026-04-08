# Design: Disaster Recovery and Backups

Last updated: 2026-01-01  
Status: Design complete (implementation staged)

This document defines DeployKube’s **end-to-end backup/restore and disaster recovery (DR)** model.

It is intentionally compatible with:
- the repo’s GitOps operating model (`docs/design/gitops-operating-model.md`),
- the single-node storage direction (`docs/design/storage-single-node.md`), and
- the future multi-node HA storage plan (`docs/design/storage-multi-node-ha.md`).

Multi-tenant compatibility (future-facing but contract-driven):
- Tenant storage/backup expectations and “tenant-aware backups” direction: `docs/design/multitenancy-storage.md`
- Tenant lifecycle and deletion constraints (offboarding semantics): `docs/design/multitenancy-lifecycle-and-data-deletion.md`

It also aligns with the productization expectations in `docs/design/cloud-productization-roadmap.md` (Phase 0 “ops readiness baseline”).

## Tracking

- Canonical tracker: `docs/component-issues/backup-system.md`

---

## Scope / ground truth

- This is a **repo-grounded** design: scripts + `platform/gitops/**` + docs.
- Where implementation is not present yet, this doc defines the **contract** we will implement (and how it will be validated).

---

## Terminology

- **Backup target**: the single out-of-cluster device/service that holds the deployment’s DR backups (v1: NFS export).
- **Backup plane**: the in-cluster GitOps-managed Jobs/CronJobs that produce/copy backup artifacts to the backup target.
- **Backup set**: a timestamped, immutable directory on the backup target containing all artifacts required for a restore.
- **Master key**: the operator-held key that unlocks restore-critical secrets and encrypted backup repositories for a deployment.
- **Tier-0**: state that must be backed up via an **application-consistent** mechanism (Vault raft snapshot, Postgres dumps/WAL, etc.).
- **Ordinary workload**: any workload whose durable state is represented by Kubernetes PVCs and can be backed up as file-level data (crash-consistent by default).

---

## Design principles

1. **DR is the availability strategy for single-node**  
   For single-node (one physical failure domain), we do not pretend to offer HA. We offer **repeatable restore**.

2. **One deployment → one backup target → one restore workflow**  
   Restore must not require “knowing where things are”; it must be deterministic and contract-driven.

3. **Back up at stable interfaces**  
   - S3 objects are backed up at the **S3 API** level (not by copying Garage’s internal layout).
   - Databases are backed up via app-native exports (or later CNPG-native backups).
   - PVCs are backed up via file-level tools (restic in v1).
   This preserves compatibility with future storage backends (Garage → Ceph RGW, NFS → local-path, etc.).

4. **A restore must be safe under GitOps**  
   The “init race” must be systematically avoided by a “restore mode” workflow (Argo bootstrapped but not auto-syncing).

5. **Security does not depend on the backup target being private**  
   Backup artifacts must be encrypted-at-rest (restic repos, encrypted recovery bundles), so “someone can mount the NFS share” is not equal to “they can read secrets”.

6. **Validation is mandatory and continuous**  
   - We validate backups are being produced and are fresh.
   - We validate restores are possible via scheduled **partial restore drills**.
   - We enforce a monthly **full restore drill** workflow (not necessarily in prod; see below).

---

## Goals

1. **Full-deployment DR**: restore a destroyed cluster and its data with **one backup target**.
2. **Single-command backup + restore orchestration** for operators (scripted; no ad-hoc manual sequences).
3. **One master key** per deployment that unlocks a restore:
   - decrypt bootstrap secrets (SOPS / DSB),
   - decrypt DR bundles (breakglass, restore metadata),
   - unlock backup repositories (restic passwords, rclone-crypt config if used).
4. **Ordinary workloads are covered by default** by the backup plane (PVC backups + off-cluster replication), but each workload must still provide a **restore validation hook** so we can continuously prove its backups are usable.
5. **Roadmap compatible**: does not block future multi-node HA storage, tenancy scoping, or fleet ops.

---

## Non-goals (explicit)

- Multi-zone/site “survive a zone loss” (Phase 5 roadmap item; separate design).
- Zero-downtime “live migration” between storage backends. Migration is done via “backup/restore”.
- Building a bespoke backup controller in v1 (we use Jobs/CronJobs + clear contracts).

---

## Responsibility boundaries (platform vs workload)

### Platform DR (backup plane) responsibilities

The platform owns the **plumbing**:
- Backup target configuration + mount (`backup-system`), encryption-at-rest, backup-set layout + markers.
- Selecting “ordinary workloads” to back up based on labels (`darksite.cloud/backup=restic`), running the backup jobs, and enforcing retention/RPO.
- Tier-0 backup orchestration (run native exports and ensure artifacts land off-cluster).
- One-command backup/restore orchestration (GitOps-safe; avoids the init race).
- Continuous validation that the backup plane works (writeability + freshness smokes) and that restore drills are executed on schedule.

### Workload responsibilities

Workloads own **correctness proofs**:
- Label their durable state surfaces correctly (`darksite.cloud/backup=restic|native|skip`) and document any quiesce requirements.
- Provide a restore validation hook (typically a Job/CronJob) that asserts more than “pod is running”: minimally validate expected state files, and where feasible validate that the workload can start against the restored data, without touching the live PVC.
  - For “ordinary” PVC-backed apps, this is usually a non-destructive restore into scratch + minimal integrity checks.
  - For tier-0 services, this is an app-native verification (e.g., can the service start against restored data).

`backup-system` must provide at least one platform-owned restore canary so ordinary workload restore validation does not depend on opt-in/demo app repos.
Minecraft and Factorio remain reference canaries for workload-specific restore semantics.

### Restore validation hook contract (v1)

For ordinary PVC-backed workload drill enforcement, a workload opts in and declares coverage via metadata contract:
- Namespace label: `darksite.cloud/restore-validation-scope=enabled`
- Hook CronJob label: `darksite.cloud/restore-validation-hook=enabled`
- Hook CronJob annotation: `darksite.cloud/restore-validation-pvcs=<comma-or-space-separated pvc names>`
- Optional per-hook staleness override: `darksite.cloud/restore-validation-max-age-seconds=<seconds>`

Platform enforcement behavior (`backup-system/cronjob/storage-smoke-restore-validation-contract`):
- finds all scoped namespaces by namespace label,
- requires at least one labeled hook CronJob in each scoped namespace,
- requires hook CronJobs to be scheduled (not suspended),
- requires each declared PVC to exist and be `Bound` with `darksite.cloud/backup=restic`,
- requires each scoped namespace’s eligible `Bound` `backup=restic` PVC set to be fully covered by at least one hook declaration,
- requires each hook’s `status.lastSuccessfulTime` to be within the default/per-hook max age.

---

## Master key and recovery bundle

### Master key (v1 decision)

The **deployment’s SOPS Age identity** is the master key for that deployment.

Rationale:
- It already gates the entire bootstrap trust chain (DSB).
- It is already custody-gated for prod (`docs/toils/sops-age-key-custody.md`).
- Using the same master key for DR avoids key sprawl and “restore fails because you’re missing one more secret”.

Operational contract:
- One Age keypair per deployment (v1).
- Private key is stored out-of-band (password manager / envelope / HSM/Yubikey plugin is future).

### Recovery bundle (encrypted, stored on backup target)

We define a **recovery bundle** stored on the backup target, encrypted to the deployment’s Age recipient(s).

Purpose: make restores possible even if the operator laptop is not the “source of truth” machine.

Contents (v1 minimum):
- A “what to restore” manifest (deploymentId, backup-set id, checksums, timestamps).
- A **copy** (or pointer) of the GitOps snapshot used for restore (see next section).
- Restore-critical secrets that are intentionally not in-cluster:
  - breakglass kubeconfig copy (encrypted; **required for prod**; optional for dev or if an operator explicitly opts out with a documented reason),
  - restic repository password(s) (for PVC backup repos; see below),
  - optional: backup-target credentials for future non-NFS targets (S3 keys, SSH keys) if the target itself requires auth.

Important: the recovery bundle does **not** store the Age private key (no circular dependency).

Implementation note:
- The out-of-band stored breakglass kubeconfig remains the source-of-truth credential.
- If the platform needs that kubeconfig inside the encrypted recovery bundle, operators may stage a copy in-cluster specifically for bundle assembly; treat that as a derived copy with tighter lifetime and auditing than the offline custody copy.

#### Restic repository password custody and rotation (v1)

- **Source of truth:** store restic password(s) in Vault (deployment-scoped) and project them into the backup plane via ESO.
- **Recovery:** every backup set must include an encrypted copy of the active password(s) in its recovery bundle so restores can proceed even if Vault is destroyed.
- **Refresh cadence:** generate/refresh the recovery bundle as part of backup set creation (per set), so it always matches the backup-set contents and current restore-critical secrets.
- **Initial creation:** generated once per deployment (random) by an operator or an initialization Job and then written to Vault; never derived from the Age key.
- **Rotation:** use restic repository key rotation (`restic key add` + `restic key remove`) so old passwords can be kept until a successful restore drill proves the new key works.

---

## Backup target contract (deployment-config driven)

### v1 target type: NFS export

V1 standardizes on an external **NFS export** as the backup target. This is the lowest common denominator for “bring your own NAS”.

Definition of “off-cluster”:
- The NFS server must not share the failure domain with the Kubernetes node(s).
- “NFS on the Proxmox host” is **not** off-cluster.

### How the backup target is configured

The backup target endpoint is defined by the deployment config contract:
- `platform/gitops/deployments/<deploymentId>/config.yaml` (`spec.backup.*`)
- Design extension: `docs/design/deployment-config-contract.md`

Secrets (if any) are **not** stored in DeploymentConfig; they are stored in Vault and/or the encrypted recovery bundle.

### How the backup plane consumes DeploymentConfig (repo reality v1)

The backup plane (`backup-system`) needs DeploymentConfig values (e.g., retention knobs) in-cluster.

Repo reality today:
- The singleton `DeploymentConfig` is applied as a real CRD/CR.
- The deployment-config-controller publishes a snapshot `ConfigMap/backup-system/deploykube-deployment-config` for `backup-system` CronJobs.
- Guardrail: `./tests/scripts/validate-backup-system-deployment-config-snapshot.sh` forbids repo-authored “copy” snapshots and enforces controller publication wiring.

Why we do not read the CR directly from Jobs:
- Jobs/CronJobs should avoid direct Kubernetes API reads when a stable snapshot injection mechanism is sufficient (simpler RBAC, simpler scripts).

### How the backup target is mounted in-cluster

We mount the backup target via a **static PV/PVC** in a dedicated namespace:
- Namespace: `backup-system`
- PVC: `backup-target` (RWX but scoped to backup plane only)

This is the only allowed “RWX-like” mount in the single-node profile (see `docs/design/storage-single-node.md`).

#### NFS mount options and fail-fast behavior (v1)

The backup target mount is used only by the backup plane; it must prefer **fail-fast** over “hang forever”.

Recommendation:
- Configure NFS `mountOptions` to avoid unkillable `D`-state hangs when the server disappears (example: `nfsvers=4.1,tcp,soft,timeo=50,retrans=2,noatime`).
- Jobs that touch the mount must also set `activeDeadlineSeconds` and wrap IO in `timeout` so a stalled mount fails visibly.
- Trade-off: `soft` mounts can return IO errors / partial writes. This is acceptable because backup sets are finalized only after checksums/markers are written, and failed jobs must never advance `LATEST.json`.

---

## RPO / RTO targets (v1 defaults)

These are initial targets for “single-node prod” and should be tuned with evidence.

RPO/RTO are also part of the operator contract: CronJob schedules and freshness thresholds must be consistent with these targets.

Defaults:

| Tier | What | Target RPO | Freshness threshold (default) | Notes |
|------|------|------------|-------------------------------|-------|
| Tier-0 | Vault raft snapshot | 1h | 2h | App-consistent snapshot; must land off-cluster |
| Tier-0 | Postgres logical dumps (database-only `pg_dump`) | 1h | 2h | RPO depends on dump duration; v2 uses WAL/object store |
| Tier-0 | S3 DR replication (primary S3 → DR S3 endpoint) | 1–6h | 6h | Start at 1h for backup-critical buckets; tune with cost/volume |
| Ordinary | PVC restic backups | 6h | 12h | Crash-consistent by default |

Expected RTO (full restore from scratch):
- **RTO target (v1):** 2–8 hours (bandwidth + data volume dependent).
- This is the time to: rebuild cluster (Stage 0/1), restore tier-0, restore S3 + PVCs, re-enable Argo sync, and pass smoke suites.

These defaults intentionally match the single-node storage design targets in `docs/design/storage-single-node.md`.

---

## What gets backed up (full-deployment)

### 1) Git source of truth (GitOps snapshot)

We back up the GitOps state required to recreate the cluster declaratively:
- Snapshot of `platform/gitops/**` at a known revision (tarball or bare git repo) stored inside the backup set.

This enables restores that do not depend on GitHub availability, and makes “restore uses exactly what was backed up” auditable.

### 2) Tier-0 state (application-consistent)

Tier-0 is restored before allowing general GitOps sync:

- **Vault (core)**: raft snapshots copied off-cluster into the backup set.
  - Existing mechanism (in-cluster snapshot): `platform/gitops/components/secrets/vault/config/backup.yaml`
  - Component doc: `platform/gitops/components/secrets/vault/README.md`
- **Postgres**:
  - v1 (NFS-only): logical dumps (database-only `pg_dump`) into the backup set.
  - future (object-store target): CNPG-native backups + WAL for tighter RPO.
- **S3 backup buckets (object storage)**:
  - Preferred (prod): object-to-object replication from primary S3 (in-cluster Garage) to a DR S3 endpoint (off-cluster), configured via `DeploymentConfig.spec.backup.s3Mirror.mode=s3-replication`.
  - Backup sets store only S3 replication **markers** (e.g., `s3-mirror/LATEST.json`) so we avoid ballooning filesystem metadata on the NFS backup target.
  - Restore syncs from the DR S3 endpoint back into primary S3.
  - Legacy: `mode=filesystem` mirrors objects onto the NFS backup target (deprecated for DR).

#### Postgres dump details (v1)

Repo reality today:
- Postgres “base” ships an interim `pg_dump` (database-only) CronJob (`platform/gitops/components/data/postgres/base/backup-cronjob.yaml`) that currently writes to an in-cluster PVC.
- It authenticates using superuser credentials from a Kubernetes Secret (per-consumer; usually projected via ESO from Vault).

Backup-plane intent:
- The dump job should write into the `backup-system` backup target mount (not an in-cluster PVC).
- Logical dumps are transaction-consistent by design (no “crash-consistent filesystem copy”), but still bounded by dump duration.

Restore semantics (v1):
- Dumps are **database-only** (no role/password DDL). Restores are performed per-consumer by restoring into the target database.
- Credentials are sourced from Vault/ESO and must exist before restore; the dump is intended to restore schema/data, not identity objects.

#### S3 mirror details (v1)

Bucket selection (v1):
- Mirror an explicit allow-list of **backup-critical buckets** defined by the platform S3 contract (at minimum `BUCKET_BACKUPS`) using the platform S3 key.
- The mirror job must **not** “list all buckets and sync everything” by default; bucket selection is config-driven to avoid crawling unintended/tenant buckets.
- If an allow-listed bucket does not exist yet, the mirror job should create it idempotently or fail with a clear error (v1 default: fail-fast for platform buckets).
- In multi-tenant future work, bucket scoping must be explicit (per-tenant keys/buckets); v1 must not “accidentally” crawl tenant buckets.

Credentials (v1):
- Source (primary) credentials: platform S3 credentials projected into the cluster, sourced from Vault (`secret/garage/s3`).
- Destination (DR replica) credentials (when `mode=s3-replication`): Vault `secret/backup/s3-replication-target` projected into `backup-system`.
- Legacy payload-at-rest encryption (when `mode=filesystem`): `rclone crypt` credentials from Vault (`secret/backup/s3-mirror-crypt`).

Consistency model (v1):
- Mirroring is **crash-consistent** at the object store level: there is no atomic snapshot point across buckets.
- `rclone sync`/`aws s3 sync` is acceptable for v1; repeated runs converge and the backup set is considered complete only after sync finishes and markers are written.

Restore implications (v1):
- Preferred (mode=s3-replication): restore tooling syncs DR replica objects back into primary S3 (no NFS-stored payload).
- Legacy (mode=filesystem): restore tooling decrypts `rclone crypt` payload from the NFS mirror before syncing back to primary S3.
- Historical pre-encryption sets may still use plaintext `s3-mirror/buckets/*`; restore tooling keeps compatibility during migration.

### 3) Ordinary workloads (PVC backups)

All PVCs labeled `darksite.cloud/backup=restic` are backed up automatically:
- Mechanism: restic repositories stored on the backup target.
- Default semantics: crash-consistent backups.

Workloads that require app-consistent backups must declare `darksite.cloud/backup=native` and provide the native artifact into the backup set.

#### Workload discovery and scoping (v1)

Discovery should be label-driven and explicit:
- PVCs (and templates) must set `darksite.cloud/backup=restic|native|skip` (enforced by `tests/scripts/validate-pvc-backup-labels.sh`).
- Namespace-level scoping is required to avoid “back up everything forever” by accident:
  - v1 recommendation: only back up namespaces explicitly opted into the backup plane (e.g., via a namespace label such as `darksite.cloud/backup-scope=enabled`), plus a small allow-list of platform namespaces.
  - Tenant namespace support should be opt-in and contract-driven (future tenant onboarding work).
  - Tenant lifecycle claims (delete/restore) require tenant-scoped backup boundaries (per-tenant repo/key + separable on-target layout). Until that exists, do **not** promise “delete tenant data from backups” for Tier S shared clusters.
    - Tenant boundary contract: `docs/design/multitenancy-storage.md` (10) and `docs/design/multitenancy-lifecycle-and-data-deletion.md`.

Restore drill scoping (v1):
- Drills should run in the workload’s own namespace and restore into `emptyDir` scratch by default (non-destructive), or a dedicated scratch PVC labeled `darksite.cloud/backup=skip`.
- Do not create ad-hoc tenant namespaces for drills. If drills run in tenant namespaces (`darksite.cloud/rbac-profile=tenant`), they must comply with the Kyverno tenant baseline (PSS restricted + default-deny egress) and ship any required NetworkPolicies (e.g., allow egress to the platform S3 endpoint if the drill needs it).

Platform-owned canary baseline:
- `backup-system` runs a PVC-backed restore canary with scheduled write + non-destructive restore drill.
- This baseline is mandatory for prod and must stay in a platform-owned repo path.

Minecraft and Factorio remain reference ordinary workload canaries:
- Their worlds are PVC-backed.
- They should be covered by PVC backups (not only in-app sidecars).
- Partial restore drills should validate their world data restores regularly where those apps are installed.

---

## Backup set layout and freshness contracts

### Layout

Each run produces a directory, and the deployment has a small set of top-level pointers/signals:

```
<basePath>/<deploymentId>/
  LATEST.json
  sets/<timestamp>-<gitsha>/
    manifest.json
    gitops/
    tier0/
    s3-mirror/LATEST.json
    pvc-restic/LATEST.json
    recovery/
    tenants/<orgId>/s3-mirror/LATEST.json
  signals/
    FULL_RESTORE_OK.json
```

Note: legacy `mode=filesystem` stores S3 mirror payload once at the top level (`<basePath>/<deploymentId>/s3-mirror/crypt/...` and `.../tenants/<orgId>/s3-mirror/crypt/...`). Backup sets intentionally carry only marker files, not a full payload snapshot, to avoid ballooning filesystem metadata on the backup target.

### Pointers / markers

To make monitoring deterministic and cheap:
- `LATEST.json` is an atomic pointer to the newest complete backup set.
- Each tier writes a “done” marker with timestamp and checksums (per-tier markers).

Smoke checks validate presence and freshness without enumerating full repos.

### Freshness contract (v1)

“Fresh” means “a successful backup artifact exists with a timestamp newer than the freshness threshold”.

Default thresholds (see RPO table above):
- Tier-0: 2h
- S3 replication / mirror: 6h
- PVC backups: 12h

The `storage-smoke-backups-freshness` CronJob must:
- fail if any required tier exceeds its freshness threshold, and
- emit enough diagnostics to pinpoint which tier(s) are stale and what the newest observed marker timestamp is.

### Retention / pruning (v1)

Retention has two distinct surfaces:

1) **Restic repository retention** (PVC backups)
- Implemented via `restic forget --prune` with a deployment-scoped default (recommended config location: `spec.backup.retention.restic`).

2) **Backup set directory retention** (tier-0 dumps + markers + recovery bundles)
- Implemented by a platform-owned prune job that deletes old `sets/<...>/` directories according to a policy (e.g., keep daily/weekly/monthly sets).
- Backup-set “immutability” in v1 is **convention**, not a hard security property:
  - backup jobs must never overwrite an existing set directory,
  - `LATEST.json` must only advance after a set is fully complete,
  - optional hardening: mark completed set directories read-only (`chmod -R a-w`), acknowledging that this is not WORM.

---

## Restore model (single-command, GitOps-safe)

### Restore safety: avoid the init race

Restore must run with Argo auto-sync disabled until tier-0 restore is complete:
- Stage 1 supports “restore mode” via:
  - `PLATFORM_APPS_AUTOSYNC=false`
  - `WAIT_FOR_PLATFORM_APPS=false`
- If Argo was already applied with auto-sync, restore tooling must disable auto-sync on `platform-apps` immediately.

### Restore order (v1)

1. Rebuild cluster (Stage 0) and bootstrap Forgejo/Argo (Stage 1) **in restore mode**.
2. Restore Vault (core) from raft snapshot.
3. Restore Postgres from dumps (v1) / from CNPG backups (future).
4. Restore S3 objects into primary S3.
5. Restore ordinary PVCs from restic repos.
6. Re-enable Argo auto-sync; trigger reconciliation.
7. Run smoke suites and capture evidence.

```mermaid
flowchart TD
  A[Stage 0: rebuild cluster] --> B[Stage 1: bootstrap Argo/Forgejo<br/>(restore mode: autosync off)]
  B --> C[Restore Vault (raft snapshot)]
  C --> D[Restore Postgres (pg_dump v1 / CNPG v2)]
  D --> E[Restore S3 (DR replica → primary S3)]
  E --> F[Restore PVCs (restic)]
  F --> G[Enable Argo auto-sync + reconcile]
  G --> H[Run smoke suites + capture evidence]
```

### Single-command orchestration

We introduce a “one command” operator entrypoint (scripted, not a controller) that:
- selects a backup set (`latest` by default),
- runs the restore steps in the correct order, and
- produces a machine-readable result summary.

This is expected to land as a dedicated script under `scripts/ops/` (e.g. `scripts/ops/restore-from-backup.sh`) and it will be referenced by the future operator guide.

---

## Validation, smoke, and mandatory drills

All validation jobs must follow `docs/design/validation-jobs-doctrine.md`.

### Continuous smoke (in-cluster, prod at minimum)

Required CronJobs:
- `storage-smoke-backup-target-write` (prove backup PVC is writable)
- `storage-smoke-backups-freshness` (prove tier artifacts are present + fresh)
- `storage-smoke-s3-latency` (prove primary S3 responsiveness; early wedge detection)

NFS failure handling (v1 expectation):
- If the backup target is unreachable, backup jobs must fail fast and clearly.
- The writeability smoke must run frequently enough to surface “backup target down” before freshness thresholds are breached.
- Alerting must treat repeated failures of `storage-smoke-backup-target-write` as urgent (backup plane is impaired).
  - v1 cadence recommendation: every 15 minutes (or faster) for prod.
  - Alerting contract (v1): backup-plane smoke/freshness failures must produce an operator-visible alert within 15 minutes once observability wiring exists.

### Partial restore drills (in-cluster, scheduled)

At least one scheduled restore drill must:
- restore a representative ordinary workload’s data into scratch space (not touching live PVCs),
- validate expected files exist, and
- fail loudly if restore is broken.

Scratch space guidance (v1):
- Preferred: `emptyDir` scratch (node-local, auto-cleaned) to keep drills non-invasive.
- If the workload requires PVC-like filesystem behavior, use a dedicated scratch PVC and label it `darksite.cloud/backup=skip` so it does not pollute backups.
- Drills must remain compatible with Kyverno tenant baseline constraints when run in tenant namespaces (no surprise egress assumptions).

Minecraft + Factorio are the reference canaries for this class.

### Monthly full restore drill (workflow, enforced)

A full restore drill is destructive by nature and should run in a dedicated “DR test” environment (not on prod):
- Recreate a fresh cluster from the backed-up GitOps snapshot.
- Restore tier-0 and ordinary workloads from the backup target.
- Run smoke suites.
- Write a signed/hashed “FULL_RESTORE_OK” marker to the backup target and capture evidence in Git.
  - **Trust note:** avoid granting the DR test environment broad write access to the backup target. Prefer scoping writes to the `signals/` path only (e.g. separate NFS export or otherwise restricted permissions). If that is not feasible, treat the DR test environment as production-equivalent in trust.

DR test environment shape (v1 expectation):
- Preferred: a separate deploymentId (e.g., `<prodDeploymentId>-dr-test`) with its own DNS identity, that can mount the backup target read-only for `sets/` and narrowly write to `signals/`.
- Acceptable for early practice: an ephemeral dev/kind cluster mounting the backup target (still provides procedure rehearsal, but is not equivalent to “restore on the real substrate”).

Execution model (v1 expectation):
- The monthly full restore drill is executed **out-of-cluster** by an operator (or later a CI runner) using the one-command restore script against the DR test environment.
- To avoid granting broad write access from the DR test cluster, prefer having the orchestrator write `signals/FULL_RESTORE_OK.json` directly to the backup target after verifying success; otherwise restrict the DR test cluster to `signals/` only.

`FULL_RESTORE_OK.json` marker contract (v1):
- Location: `<basePath>/<deploymentId>/signals/FULL_RESTORE_OK.json`
- Must include at minimum:
  - `deploymentId`
  - `backupSetId` (the `<timestamp>-<gitsha>` directory name)
  - `restoredAt` (RFC3339 UTC)
  - `backupSetManifestSha256` (hash of the set’s `manifest.json`)
  - `result: ok|fail`
- “Signed/hashed” meaning in v1:
  - v1 requires the **hash binding** (`backupSetManifestSha256`) and evidence capture in Git.
    - Rationale: v1 assumes the backup target is a “trusted network” device; the hash binding primarily prevents “restored the wrong set” and provides tamper-evident linkage to the exact set used.
  - A cryptographic signature scheme (cosign/minisign/GPG) is future work and must align with the “one master key” intent (tracked in `docs/component-issues/backup-system.md`).

Enforcement:
- A prod CronJob checks the age of the last full restore marker and fails if older than 31 days.
- Backup-plane alert routing/ownership is wired through Mimir Alertmanager fallback routes in prod:
  - `service=backup-system` alerts route to a dedicated platform-ops receiver (`backup-system-platform-ops`),
  - receiver endpoints are Vault-backed (`secret/observability/alertmanager`),
  - contract target remains operator-visible within 15 minutes.
- The restore entrypoint writes a typed Git evidence note by default (`EvidenceType: full-restore-drill-v1`) after successful marker write.
- Repo validation gate `tests/scripts/validate-full-restore-evidence-policy.sh` enforces full-restore evidence metadata + freshness policy:
  - default bootstrap mode permits “no typed note yet” during rollout to avoid retroactive false claims,
  - strict mode (`REQUIRE_FULL_RESTORE_EVIDENCE_NOTES=true`) requires fresh monthly evidence for required deployment IDs.

---

## Operator docs expectations (not written in this change)

This design requires operator-facing guides:
- Manual backup runbook (incl. “take backup now”, “change RPO”, “verify backups”).
- Manual restore runbook (step-by-step, with safety checks).
- “Monthly restore drill” SOP (including evidence requirements).

These will live under `docs/guides/` and/or `docs/toils/` and are tracked in `docs/component-issues/backup-system.md`.

Current repo (v1) operator guides:
- Backup-plane operations + verification: `docs/guides/backups-and-dr.md`
- Synology DSM NFS target setup: `docs/guides/synology-dsm-nfs-backup-target.md`

---

## Roadmap alignment

This is Phase 0 “ops readiness baseline” work in `docs/design/cloud-productization-roadmap.md`:
- it is a hard prerequisite to treating the platform as “productizable”,
- it reduces future toil when we introduce multi-node storage or fleet lifecycle, and
- it provides a repeatable upgrade/rollback safety net.

---

## Implementation milestones (high level)

1. Implement `backup-system` component (static PV/PVC + baseline RBAC).
2. Implement backup-set writer (creates set dir, writes markers, advances `LATEST.json`).
3. Implement tier-0 artifact export into the backup set (Vault + Postgres).
4. Implement S3 backup bucket lifecycle + replication hardening (producer-side retention, DR endpoint policy, multi-zone targets).
5. Implement PVC restic backups keyed off `darksite.cloud/backup=restic` (plus retention).
6. Implement restore tooling (single command) + evidence.
7. Implement partial restore drills (platform-owned baseline canary + optional app canaries such as Minecraft/Factorio) and wire enforcement.
8. Implement monthly full restore drill enforcement (marker + staleness check).
