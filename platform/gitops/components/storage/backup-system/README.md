# Introduction

`backup-system` is the platform “backup plane”: GitOps-managed CronJobs and storage wiring that produce and validate off-cluster backup artifacts for disaster recovery (DR).

Design doc (contract): `docs/design/disaster-recovery-and-backups.md`  
Issue tracker: `docs/component-issues/backup-system.md`

## Architecture

- The backup target is an **off-cluster NFS export** mounted via a static `PersistentVolume`/`PersistentVolumeClaim` (`backup-target`) in namespace `backup-system`.
- Backup-producing components (tier-0) write artifacts to NFS-backed PVCs (prod only), and each tier writes a `LATEST.json` marker for freshness monitoring.
- The backup plane mirrors **backup-critical S3 buckets** (Garage) using `rclone sync`:
  - Preferred (prod): `mode=s3-replication` replicates objects to a DR S3 endpoint and writes only `LATEST.json` markers to NFS (avoids the “hundreds of thousands of tiny files on btrfs” pattern on the NAS).
  - Legacy: `mode=filesystem` mirrors objects onto the NFS backup target (optionally encrypted at rest via `rclone crypt`).
- The backup plane runs a platform-owned ordinary workload canary in `backup-system`:
  - `storage-canary-write` updates canary PVC payload
  - `storage-canary-restore` restores from the PVC restic repo into scratch and verifies checksum
- The backup plane runs continuous smokes:
  - `storage-smoke-backup-target-write`
  - `storage-smoke-backups-freshness`
  - `storage-smoke-pvc-restic-credentials`
  - `storage-smoke-restore-validation-contract`
  - `storage-smoke-full-restore-staleness`
- The backup plane assembles immutable backup sets from fresh tier markers:
  - `storage-backup-set-assemble`
- The backup plane backs up ordinary PVCs labeled `darksite.cloud/backup=restic` into restic repos on the backup target:
  - `storage-pvc-restic-backup`
- Backup-set assembly also writes an encrypted recovery bundle per set (`recovery/recovery-bundle.json.age`) plus `RECOVERY_BUNDLE.json` metadata.
- Backup-set assembly also materializes a GitOps snapshot per set under `gitops/` by downloading the seeded Forgejo `cluster-config` archive at the exact `platform-apps` sync revision.
- Canonical layout (as seen via `PVC/backup-target` mounted at `/backup`):
  - `/backup/<deploymentId>/LATEST.json` (top-level pointer to the latest complete set)
  - `/backup/<deploymentId>/sets/<timestamp>-<gitsha>/...` (backup sets; immutable tier-0 + recovery bundle + markers)
  - `/backup/<deploymentId>/tier0/<tier>/...`
  - `/backup/<deploymentId>/s3-mirror/LATEST.json` (S3 tier marker; payload lives either in DR S3 or legacy on-target mirror)
  - `/backup/<deploymentId>/pvc-restic/...` (per-namespace/per-PVC restic repos + marker)
  - `/backup/<deploymentId>/sets/<timestamp>-<gitsha>/recovery/` (encrypted recovery bundle + marker)
  - `/backup/<deploymentId>/tenants/<orgId>/s3-mirror/LATEST.json` (tenant S3 tier markers)

Legacy on-target S3 payload paths (mode=filesystem only; deprecated for DR):
- `/backup/<deploymentId>/s3-mirror/crypt/...`
- `/backup/<deploymentId>/tenants/<orgId>/s3-mirror/crypt/...`

Note: backup sets intentionally do **not** duplicate large rolling payload trees (S3 mirror, tenant mirrors, PVC restic repos). Sets carry only `LATEST.json` marker files for those tiers so retention can be aggressive without ballooning filesystem metadata on the backup target.

Note: tier-0 backup CronJobs typically mount their tier-specific PV/PVC at `/backup`, so inside those tier-0 Jobs the marker is usually just `/backup/LATEST.json` (the PV already points at the tier directory on the NAS).

## Subfolders

- `base/`: namespace + PVC + CronJobs (smokes + S3 mirror + backup-set assembly) + ESO wiring for S3 credentials and recovery repo credentials.
- `overlays/proxmox-talos/`: production-only static NFS PVs (backup target + tier-0 backup PVC PVs).
  - Also rewrites digest-pinned `bootstrap-tools` refs to the proxmox-local mirror (`198.51.100.11:5010/...`) because the backup-plane CronJobs must stay pullable even when the canonical registry digest is not directly resolvable from worker nodes.
  - Includes a `tenant-backup-permissions-repair` Sync hook that repairs `/backup/<deploymentId>/tenants/**` directory group/mode state for the non-root tenant S3 mirror path on existing NFS content.
  - `overlays/{mac-orbstack,mac-orbstack-single}/` exist for layout contract completeness but only reference `base/` (the backup plane is not installed in dev by default).

## Container Images / Artefacts

- `registry.example.internal/deploykube/bootstrap-tools@sha256:e7be47a69e3a11bc58c857f2d690a71246ada91ac3a60bdfb0a547f091f6485a` (CronJobs; includes `kubectl`, `jq`, `psql`, `python3`, `yq`, …)
- `docker.io/restic/restic@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76` (restic init/utility containers and generated per-PVC backup pods)
- `rclone` is included in the `bootstrap-tools` image (for S3 mirroring); backup jobs do not perform runtime package installs.

## Dependencies

- ExternalSecrets Operator (ESO) and Vault: required to project Garage S3 credentials into `backup-system`.
- ExternalSecrets Operator (ESO) and Vault: required to project S3 replication target credentials (`backup/s3-replication-target`) into `backup-system` when `mode=s3-replication`.
- ExternalSecrets Operator (ESO) and Vault: required to project S3 mirror crypt credentials (`backup/s3-mirror-crypt`) into `backup-system` when `mode=filesystem` (legacy).
- ExternalSecrets Operator (ESO) and Vault: required to project Forgejo repo credentials (`forgejo/argocd-repo`) for per-set recovery bundles.
- ExternalSecrets Operator (ESO) and Vault: required to project restic repo password (`backup/pvc-restic`) for `storage-pvc-restic-backup`.
- ExternalSecrets Operator (ESO) and Vault: required to project restic lifecycle metadata into `Secret/backup-recovery-material` for per-set recovery bundle alignment.
- Garage S3: required for the S3 mirror tier (platform buckets only).
- Off-cluster NFS server: required for prod-class deployments (static PVs).

## Communications With Other Services

### Kubernetes Service → Service calls

- `backup-system` CronJobs call Garage S3 via the in-cluster S3 endpoint from the projected `Secret/backup-system-garage-s3`.

### External dependencies (Vault, Keycloak, PowerDNS)

- Vault (via ESO): reads `secret/garage/s3` to populate `Secret/backup-system-garage-s3`.
- Vault (via ESO): reads `secret/backup/s3-mirror-crypt` to populate `Secret/backup-system-s3-mirror-crypt`.
- Vault (via ESO): reads `secret/forgejo/argocd-repo` to populate `Secret/backup-recovery-forgejo-repo`.
- Vault (via ESO): reads `secret/backup/pvc-restic` to populate `Secret/backup-system-pvc-restic`.
- Vault (via ESO): reads `secret/backup/pvc-restic` to populate `Secret/backup-recovery-material` (`RESTIC_PASSWORDS_JSON`).
- `shared/rbac` namespace automation: creates `RoleBinding/backup-pvc-restic-runner-target` in backup-scoped tenant namespaces and the static platform allow-list (`backup-system`, `step-system`) so `backup-system/backup-pvc-restic-runner` can create only the temporary child backup Pods and ephemeral password Secrets needed there.

### Mesh-level concerns (DestinationRules, mTLS exceptions)

- `backup-system` runs with Istio injection disabled (`sidecar.istio.io/inject: "false"`). It talks to Garage S3 over the cluster network.

## Initialization / Hydration

- PVs are static and expect the NFS export path(s) to exist on the backup target.
- On first run, CronJobs create their required directory layout under the mounted backup target.

## Argo CD / Sync Order

- Sync wave recommendation: before tier-0 backup PVCs that bind to the static PVs (so PVs exist first).
- Pre/PostSync hooks used: none.
- Sync dependencies: ESO + Vault should be healthy before the S3 mirror CronJob can run.

## Operations (Toils, Runbooks)

- Design/runbook direction: `docs/design/disaster-recovery-and-backups.md` and `docs/design/storage-single-node.md`.
- Operator guide (cluster-side): `docs/guides/backups-and-dr.md`.
- Restore guide: `docs/guides/restore-from-backup.md`.
- Full-restore evidence policy gate: `tests/scripts/validate-full-restore-evidence-policy.sh`.
- Restic key-rotation entrypoint: `scripts/ops/rotate-pvc-restic-password.sh`.
- Restic repo permission migration (non-root baseline): `scripts/ops/migrate-pvc-restic-repo-permissions.sh`.
- Alerts/runbook: `docs/runbooks/backup-dr-smoke-alerts.md`.
- Alert routing guardrail: `tests/scripts/validate-backup-alerting-routing-contract.sh`.
- Hostile-NFS confidentiality guardrail: `tests/scripts/validate-backup-target-confidentiality-contract.sh`.
- Tenant backups runbook: `docs/toils/tenant-backups.md`.
- Operator guide (Synology DSM UI): `docs/guides/synology-dsm-nfs-backup-target.md`.
- Synology NFS target (v1):
  - Export path (prod default): `/volume1/deploykube/backups` from `198.51.100.11`.
	  - Required directories (prod default):
	    - `/volume1/deploykube/backups/proxmox-talos/`
	    - `/volume1/deploykube/backups/proxmox-talos/tier0/vault-core/`
	    - `/volume1/deploykube/backups/proxmox-talos/tier0/postgres/{keycloak,powerdns,forgejo}/`
	    - `/volume1/deploykube/backups/proxmox-talos/s3-mirror/`

## Customisation Knobs

- NFS endpoint and export paths: DeploymentConfig controller-owned (`spec.backup.target.nfs.*`) and applied to static PV mount fields (`/spec/nfs/server`, `/spec/nfs/path`, `/spec/mountOptions`) in `overlays/proxmox-talos/pv-*.yaml`.
- `storage-pvc-restic-backup` also treats `spec.backup.target.nfs.server` and `spec.backup.target.nfs.exportPath` as required deployment-config inputs; the Job fails fast if the controller snapshot is missing them instead of falling back to proxmox-only defaults baked into `base/`.
- CronJob schedules and thresholds:
  - schedules are DeploymentConfig controller-owned (`spec.backup.schedules.*`),
  - freshness thresholds derive from DeploymentConfig RPO when set.
  - Schedules are intentionally **not** aligned to `:00` to avoid top-of-hour request bursts and node contention impacting the kube-apiserver.
  - Freshness windows derived from `DeploymentConfig.spec.backup.rpo`:
    - tier-0 freshness = `2x` `rpo.tier0`
    - S3 mirror freshness = `6x` `rpo.s3Mirror`
    - PVC restic freshness = `2x` `rpo.pvc`
    - If `rpo.*` is missing or malformed, fallback defaults from manifest env are used.
  - Full-restore marker staleness knobs:
    - `MAX_AGE_FULL_RESTORE_SECONDS`: maximum accepted age for `signals/FULL_RESTORE_OK.json` (`31d` default).
  - PVC restic credential smoke knobs:
    - `MIN_REPOS`: minimum discovered platform PVC restic repo count required for success (default `1`).
  - Restore validation contract knobs:
    - `HOOK_NAMESPACE_LABEL_KEY` / `HOOK_NAMESPACE_LABEL_VALUE`: namespace opt-in selector for restore-validation scope.
    - `HOOK_LABEL_KEY` / `HOOK_LABEL_VALUE`: hook CronJob selector inside each scoped namespace.
    - `HOOK_PVCS_ANNOTATION`: per-hook annotation listing covered PVCs.
    - `HOOK_MAX_AGE_ANNOTATION`: optional per-hook freshness override in seconds.
    - `DEFAULT_MAX_AGE_SECONDS`: fallback max age for `status.lastSuccessfulTime`.
    - `MIN_SCOPED_NAMESPACES`: optional minimum count gate for scoped namespaces (default `0`).
  - Backup-set assembler knobs:
    - `MAX_AGE_TIER0_SECONDS`: required freshness for tier-0 markers before assembling a set.
    - `MAX_AGE_S3_MIRROR_SECONDS`: required freshness for `s3-mirror/LATEST.json` before assembling a set.
    - `MAX_AGE_PVC_RESTIC_SECONDS`: required freshness for `pvc-restic/LATEST.json` before assembling a set.
    - `SOURCE_REVISION`: optional override for backup set `<gitsha>` suffix (defaults to `platform-apps` Argo revision).
    - `GITOPS_REPO_URL`: optional override for the GitOps repository URL recorded in recovery metadata; defaults to live `Application/argocd/platform-apps.spec.source.repoURL`.
    - `REQUIRE_BREAKGLASS_KUBECONFIG`: require breakglass kubeconfig input for the recovery bundle (prefers `Secret/backup-breakglass-kubeconfig` key `BREAKGLASS_KUBECONFIG`; legacy fallback to `backup-recovery-material`) (default `false`).
    - `REQUIRE_RESTIC_PASSWORDS`: require `Secret/backup-recovery-material` key `RESTIC_PASSWORDS_JSON` (default `true`).
  - S3 mirror tuning knobs:
    - `RCLONE_BUCKET_TIMEOUT`: timeout for required bucket syncs (platform backups + tenant buckets); keep it below the schedule interval so `concurrencyPolicy: Forbid` does not create skipped-run gaps.
    - `RCLONE_OPTIONAL_BUCKET_TIMEOUT`: timeout for best-effort observability bucket syncs (`logs`/`traces`/`metrics`) so they cannot starve required backup mirrors.
    - `RCLONE_CRYPT_PASSWORD` / `RCLONE_CRYPT_PASSWORD2`: Vault-projected passphrases used by `rclone crypt` for on-target encryption.

## Oddities / Quirks

- NFS mounts are configured to fail fast (soft/timeouts) to avoid unkillable `D`-state hangs when the NAS is down; jobs also use `activeDeadlineSeconds` + `timeout` around IO.
- Proxmox does not rely on Argo app-level image rewrites alone for digest-pinned backup-plane jobs. The `backup-system` proxmox overlay rewrites every `bootstrap-tools@sha256:...` ref to `198.51.100.11:5010/deploykube/bootstrap-tools@sha256:...`, and `tests/scripts/validate-backup-system-proxmox-bootstrap-tools-mirror.sh` guards that render contract.
- Historical tenant mirror directories on the backup NFS target may still be `root:root 0755` from the pre-hardening era. The proxmox overlay therefore runs `tenant-backup-permissions-repair` as a constrained root Sync hook to enforce group `65532` plus mode `2775` on `/backup/<deploymentId>/tenants/**` directories before the non-root `storage-s3-mirror-to-backup-target` job runs.
- Historical backup-set and tier-0 marker files on the backup NFS target may also predate the non-root maintenance baseline. The proxmox overlay therefore runs `backup-set-permissions-repair` as a constrained root Sync hook to enforce group `65532` plus mode `2775` on `/backup/<deploymentId>/sets/**` and group-readable `LATEST.json` markers under `/backup/<deploymentId>/tier0/**`, and `storage-backup-set-assemble` now runs as UID/GID `65532` so future sets remain deletable by `storage-prune-sets`.
- Production static NFS PVCs are annotated with `argocd.argoproj.io/sync-options: Prune=false` to avoid accidental PVC re-creation during refactors (the PV reclaim policy is `Retain`; deleting/recreating a bound PVC can leave the PV in `Released` with a stale `claimRef.uid` and prevent rebinding).
- `rclone` reads `RCLONE_*` environment variables at process startup; `RCLONE_BWLIMIT` must be either unset or a valid value (use `0` to disable), not an empty string.
- Backup-system image bumps must update every pinned component-owned image reference together: bootstrap-tools digest from the canonical published image, plus the pinned restic digest used by `storage-canary-restore`, `storage-smoke-pvc-restic-credentials`, and generated per-PVC backup pods.
- The S3 mirror treats `garage-backups` as required and observability buckets (`logs`/`traces`/`metrics`) as best-effort with a shorter timeout. It also keeps required-bucket timeout plus Job deadline below the default hourly cadence and uses small bounded `rclone` retries, so slow runs fail fast and retry on the next slot instead of blocking later runs under `concurrencyPolicy: Forbid`.
- S3 mirror payload lives under encrypted `crypt/` subtrees; restore tooling decrypts transparently with `Secret/backup-system-s3-mirror-crypt` and keeps plaintext fallback for pre-encryption historical sets.
- `backup-system` currently mirrors platform S3 buckets as an “off-cluster copy”. Full “backup set” grouping is tracked in `docs/component-issues/backup-system.md`.
- PVC restic writer/smoke paths run as UID/GID `65532`; existing repos created before this hardening must be migrated once with `scripts/ops/migrate-pvc-restic-repo-permissions.sh`.
- Backup-plane maintenance jobs use the same non-root hardening pattern where feasible: pod-level `RuntimeDefault` seccomp + UID/GID `65532`, container `allowPrivilegeEscalation=false`, dropped capabilities, read-only root filesystem, and writable `emptyDir` scratch at `/tmp` when tools need cache/temp space.
- Longer-running backup-plane CronJobs (`storage-s3-mirror-to-backup-target`, `storage-pvc-restic-backup`, `storage-backup-set-assemble`, `storage-prune-sets`) also publish a shared `darksite.cloud/backup-plane-spread=long-running` pod label and soft hostname spread/anti-affinity hints so overlapping runs prefer different nodes without making single-node/dev installs unschedulable.
- DeploymentConfig consumption uses a controller-published snapshot ConfigMap:
  - `backup-system` mounts `ConfigMap/backup-system/deploykube-deployment-config` (key `deployment-config.yaml`).
  - The snapshot is published by the deployment-config-controller from the singleton `DeploymentConfig` CR.
  - Guardrail: `./tests/scripts/validate-backup-system-deployment-config-snapshot.sh` forbids repo-authored “copy” snapshots.

## TLS, Access & Credentials

- S3 credentials are sourced from Vault (`secret/garage/s3`) via ESO into `Secret/backup-system-garage-s3`.
- S3 replication target credentials are sourced from Vault (`secret/backup/s3-replication-target`) via ESO into `Secret/backup-system-s3-replication-target` (when `mode=s3-replication`).
- S3 mirror crypt credentials are sourced from Vault (`secret/backup/s3-mirror-crypt`) via ESO into `Secret/backup-system-s3-mirror-crypt` (when `mode=filesystem`, legacy).
- Recovery bundle repo credentials are sourced from Vault (`secret/forgejo/argocd-repo`) via ESO into `Secret/backup-recovery-forgejo-repo`.
- Backup-set assembly also reads the Forgejo HTTPS trust cert from `Secret/forgejo/forgejo-repo-tls` (via scoped RBAC to `tls.crt`) so it can fetch the exact GitOps archive securely in-cluster.
- Recovery material is sourced via `Secret/backup-recovery-material`:
  - restic material is projected automatically from Vault `secret/backup/pvc-restic`,
  - legacy fallback for a manually managed `BREAKGLASS_KUBECONFIG` key remains supported.
- Breakglass kubeconfig is sourced from a dedicated operator-managed Secret:
  - `Secret/backup-breakglass-kubeconfig` key `BREAKGLASS_KUBECONFIG`
  - sync/update via `scripts/ops/sync-breakglass-kubeconfig-to-backup.sh`
  - `proxmox-talos` requires this Secret for `storage-backup-set-assemble`; base/dev profiles keep it optional.
- PVC restic password is sourced from Vault (`secret/backup/pvc-restic`) via ESO into `Secret/backup-system-pvc-restic`.
- NFS access is network-level (no in-band auth); treat the backup target as hostile and keep backup artifacts encrypted-at-rest where possible (tracked in `docs/component-issues/backup-system.md`).
  - Tier-0 artifacts (Vault raft snapshots, Postgres dumps) are encrypted-at-rest on the backup target using `age` (`*.age`), with the private key stored out-of-band.
  - restic repositories under `/backup/<deploymentId>/pvc-restic/` are encrypted at rest by restic; the repository password remains in Vault plus each recovery bundle.
- `mode=s3-replication` keeps S3 backup payload out of the NFS target (only markers land on `/backup`). Payload lives in the configured DR S3 endpoint.
- `mode=filesystem` (legacy) can encrypt payload-at-rest on the backup target using `rclone crypt` (`s3-mirror/crypt/**`, tenant mirrors included).
  - Recovery bundles are encrypted-at-rest on the backup target using `age` (`recovery-bundle.json.age`), with public recipient material in `ConfigMap/backup-recovery-encryption`.
  - Synology/NAS share encryption is defense-in-depth only; the primary confidentiality contract is the artifact-level protection above, not NAS trust.

## Dev → Prod

- Dev: do not install `backup-system` (no off-cluster backup target by default).
- Prod: install `backup-system` and configure the Synology NFS export + static PVs; verify smokes and the S3 mirror.

## Smoke Jobs / Test Coverage

- `storage-smoke-backup-target-write`: backup target mount writeability smoke.
- `storage-smoke-backups-freshness`: tier-0 + S3 mirror + PVC restic + top-level backup-set pointer freshness smoke.
- `storage-smoke-full-restore-staleness`: validates `<deploymentId>/signals/FULL_RESTORE_OK.json` exists, is well-formed, and is not older than the configured max age.
  - Argo CD ignores this CronJob for aggregate app health because it reflects monthly DR evidence freshness rather than GitOps convergence; the authoritative signal remains the dedicated Mimir alert/rule path.
  - Repo-side monthly evidence policy is enforced by `tests/scripts/validate-full-restore-evidence-policy.sh` against typed v1 drill notes (`EvidenceType: full-restore-drill-v1`), with optional strict mode.
- `storage-smoke-pvc-restic-credentials`: validates discovered platform PVC restic repos can be opened with `Secret/backup-system-pvc-restic` and, when staged, candidate password in `Secret/backup-recovery-material`.
- `storage-smoke-restore-validation-contract`: enforces ordinary workload restore-hook contract:
  - namespace label: `darksite.cloud/restore-validation-scope=enabled`
  - hook CronJob label: `darksite.cloud/restore-validation-hook=enabled`
  - hook annotation `darksite.cloud/restore-validation-pvcs` must reference existing Bound `darksite.cloud/backup=restic` PVCs
  - hook freshness from `status.lastSuccessfulTime` must be within default/per-hook max age
  - runs as `ServiceAccount/backup-restore-validation-reader`, which is cluster-read-only (`namespaces`, `persistentvolumeclaims`, `cronjobs`) and intentionally cannot create/delete Pods
- `storage-canary-write`: updates `PVC/backup-restore-canary-data` payload used for platform-owned restore drills.
- `storage-canary-restore`: non-destructive restore drill for the platform-owned canary (`backup-system`), restoring from `/backup/<deploymentId>/pvc-restic/...` into `emptyDir` scratch and verifying checksum.
- `storage-pvc-restic-backup`: discovers in-scope `darksite.cloud/backup=restic` PVCs, creates a short-lived Secret per target PVC/namespace, runs a per-PVC restic backup Pod that consumes `RESTIC_PASSWORD` via `valueFrom.secretKeyRef`, then deletes the Pod and Secret before writing `/backup/<deploymentId>/pvc-restic/LATEST.json`.
  - Operational gotcha: if Vault-backed credentials change but the backing `ExternalSecret` has a long `refreshInterval` (for example `ExternalSecret/backup-system-s3-replication-target` at `1h`), the materialized Secret may remain stale until the next refresh. Deleting the materialized Secret forces ESO to recreate it quickly; confirm the `ExternalSecret` returns `Ready=True` and the recreated Secret has the expected keys.
- `storage-backup-set-assemble`: builds `sets/<timestamp>-<gitsha>/` from current tier data and advances top-level `/backup/<deploymentId>/LATEST.json` atomically.
  - materializes `gitops/` from Forgejo archive API at the exact `platform-apps` sync revision and writes `gitops/SNAPSHOT.json`.
  - also emits `recovery/RECOVERY_BUNDLE.json` and `recovery/recovery-bundle.json.age` in each set.

## HA Posture

Not assessed in Pass 1.

## Security

Not assessed in Pass 1.

## Backup and Restore

Not assessed in Pass 1.
  - PVC restic backup knobs:
    - `PLATFORM_NAMESPACE_ALLOWLIST`: comma-separated namespaces eligible for platform PVC backups (default `step-system,backup-system`).
    - `FAIL_ON_OUT_OF_SCOPE`: fail run when `backup=restic` PVCs are found outside allowed/scope-enabled namespaces.
    - `BACKUP_POD_IMAGE`: image used for per-PVC restic backup pods.
    - `BACKUP_POD_TIMEOUT_SECONDS`: timeout per PVC backup pod.
    - generated per-PVC backup pods now ship a baseline resource envelope: requests `100m` CPU / `256Mi` memory, limits `1` CPU / `1Gi` memory.
    - target-namespace access is scoped by `RoleBinding/backup-pvc-restic-runner-target` to the platform allow-list and namespaces labeled `darksite.cloud/backup-scope=enabled`; the runner no longer has cluster-wide Pod/log access.
    - `RESTIC_RETENTION`: retention flags passed to `restic forget --prune` (defaults from DeploymentConfig `.spec.backup.retention.restic` when present).
