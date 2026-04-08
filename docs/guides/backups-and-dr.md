# Guide: Backups and Disaster Recovery (Backup Plane)

This guide is the operator-facing “how to run and verify backups” companion to:
- Design contract: `docs/design/disaster-recovery-and-backups.md`
- Storage design: `docs/design/storage-single-node.md`
- Component: `platform/gitops/components/storage/backup-system/README.md`
- Alerts runbook: `docs/runbooks/backup-dr-smoke-alerts.md`
- Restore runbook: `docs/guides/restore-from-backup.md`

> Scope (v1): tier-0 + PVC backups to an off-cluster **NFSv4.1** export (Synology NAS), plus S3 disaster-recovery via object-to-object replication to an off-cluster S3 endpoint.

---

## Environments and defaults

- **Prod (`proxmox-talos`)**: enabled.
  - Backup target: Synology NAS `198.51.100.11` (NFSv4.1).
  - Off-cluster target base path: `/volume1/deploykube/backups`.
- **Dev (`mac-orbstack*`)**: disabled by default.

Deployment contract:
- Prod config: `platform/gitops/deployments/proxmox-talos/config.yaml` (`spec.backup.enabled: true`)
- Dev config: `platform/gitops/deployments/mac-orbstack-single/config.yaml` (`spec.backup.enabled: false`)

Synology setup (DSM UI): `docs/guides/synology-dsm-nfs-backup-target.md`

---

## Path mapping (NAS vs in-cluster)

The canonical backup target layout is:
- **On the NAS** (export root): `/volume1/deploykube/backups/<deploymentId>/...`
- **In-cluster (backup plane)**: `PVC/backup-target` is mounted at `/backup`, so the same paths appear as `/backup/<deploymentId>/...`.
- The backup plane maintains:
  - top-level pointer: `/volume1/deploykube/backups/<deploymentId>/LATEST.json`
  - assembled sets: `/volume1/deploykube/backups/<deploymentId>/sets/<timestamp>-<gitsha>/...`
  - per-set recovery bundle: `/volume1/deploykube/backups/<deploymentId>/sets/<timestamp>-<gitsha>/recovery/recovery-bundle.json.age`

Note: tier-0 backup CronJobs typically mount their *tier-specific* PV/PVC at `/backup`, so **inside those tier-0 Jobs** the marker path is usually just `/backup/LATEST.json` (because the PV already points at `/volume1/deploykube/backups/<deploymentId>/tier0/<tier>/` on the NAS).

---

## What gets backed up (current repo reality)

### Tier-0 (must land off-cluster in prod)

- **Vault core**: raft snapshots + `LATEST.json` marker via `vault-raft-backup` CronJob.
  - Artifacts are encrypted-at-rest (`age`): `vault-core-*.snap.age`
  - Output directory on NAS: `/volume1/deploykube/backups/proxmox-talos/tier0/vault-core/`
- **Postgres dumps** (CNPG consumers): `pg_dump` (database-only) dumps + `LATEST.json` marker via per-consumer CronJobs.
  - Artifacts are encrypted-at-rest (`age`): `*-dump.sql.gz.age`
  - Output directories on NAS:
    - `/volume1/deploykube/backups/proxmox-talos/tier0/postgres/keycloak/`
    - `/volume1/deploykube/backups/proxmox-talos/tier0/postgres/powerdns/`
    - `/volume1/deploykube/backups/proxmox-talos/tier0/postgres/forgejo/`

### Object-store DR replication (crash-consistent)

- **Garage S3 replication** (preferred): replicates backup-critical buckets from in-cluster Garage to an off-cluster S3 endpoint + `LATEST.json` marker.
  - DR endpoint (current prod): Synology-hosted Garage (`http://198.51.100.11:3900`)
  - Destination bucket/prefix (current prod): `deploykube-dr` + `proxmox-talos/`
  - Marker (still on NFS): `/volume1/deploykube/backups/proxmox-talos/s3-mirror/LATEST.json`
  - Legacy (deprecated): `mode=filesystem` mirrors payload into `/volume1/deploykube/backups/proxmox-talos/s3-mirror/crypt/`

### Ordinary workloads (PVC restic backup plane)

- **PVC restic backups**: `backup-system/cronjob/storage-pvc-restic-backup` discovers `darksite.cloud/backup=restic` PVCs in backup-scoped namespaces and in an explicit platform allow-list, then creates a short-lived target-namespace Secret and runs a per-PVC restic backup Pod that consumes `RESTIC_PASSWORD` via `valueFrom.secretKeyRef`:
  - `/volume1/deploykube/backups/<deploymentId>/pvc-restic/namespaces/<namespace>/persistentvolumeclaims/<pvc>/repo/`
- Aggregate marker:
  - `/volume1/deploykube/backups/<deploymentId>/pvc-restic/LATEST.json`
- Restic repositories under `/volume1/deploykube/backups/<deploymentId>/pvc-restic/` are encrypted at rest by restic; the repository password remains in Vault and is also copied into each encrypted recovery bundle.
- Current default platform allow-list: `step-system,backup-system`:
  - `step-system` covers the Step CA database PVC.
  - `backup-system` covers the platform restore-canary PVC (`backup-restore-canary-data`).

### Backup sets (assembled from fresh tier markers)

- `backup-system/cronjob/storage-backup-set-assemble` builds:
  - `/volume1/deploykube/backups/<deploymentId>/sets/<timestamp>-<gitsha>/`
  - top-level `/volume1/deploykube/backups/<deploymentId>/LATEST.json` pointer
  - encrypted recovery bundle:
    - `sets/<timestamp>-<gitsha>/recovery/recovery-bundle.json.age`
    - `sets/<timestamp>-<gitsha>/recovery/RECOVERY_BUNDLE.json`
- Set assembly is marker-gated: it fails if required tier markers are stale or unhealthy.

### Tenant backups (Tier S, v1)

- Tenants opt into the backup plane with a namespace label: `darksite.cloud/backup-scope=enabled` (tenant namespaces only).
- The platform provisions per-tenant backup buckets and per-project restic credentials:
  - Vault KV: `secret/tenants/<orgId>/projects/<projectId>/sys/backup`
  - Garage bucket: `tenant-<orgId>-backups`
- The backup plane replicates tenant backup buckets into the DR S3 endpoint (and writes per-tenant markers to NFS):
  - Marker: `/volume1/deploykube/backups/<deploymentId>/tenants/<orgId>/s3-mirror/LATEST.json`
  - Legacy (deprecated): on-target encrypted payload under `/volume1/deploykube/backups/<deploymentId>/tenants/<orgId>/s3-mirror/crypt/`

### Backup-plane smokes (continuous validation)

- `storage-smoke-backup-target-write`: proves the NFS mount is writable from inside the cluster.
- `storage-smoke-backups-freshness`: proves tier-0 markers + S3 replication marker exist and are fresh.
- `storage-smoke-restore-validation-contract`: enforces the ordinary workload restore-hook contract (scoped namespaces, hook labels, PVC coverage declaration, and hook freshness).
- `storage-smoke-full-restore-staleness`: proves `signals/FULL_RESTORE_OK.json` exists and is not older than 31 days.

### Ordinary workload restore-hook contract (v1)

For workloads that participate in ordinary PVC restore validation:
- Namespace label: `darksite.cloud/restore-validation-scope=enabled`
- Hook CronJob label: `darksite.cloud/restore-validation-hook=enabled`
- Hook annotation: `darksite.cloud/restore-validation-pvcs=<comma-or-space-separated pvc names>`
- Optional hook freshness override: `darksite.cloud/restore-validation-max-age-seconds=<seconds>`
- Coverage enforcement applies to Bound `darksite.cloud/backup=restic` PVCs in each scoped namespace.

Current canary hooks:
- `backup-system/cronjob/storage-canary-restore` (PVC: `backup-restore-canary-data`) - platform-owned baseline canary
- `factorio/cronjob/factorio-restore-drill` (PVC: `factorio-data`)
- `minecraft-monifactory/cronjob/minecraft-restore-drill` (PVC: `minecraft-data`)

### Encryption at rest (tier-0 artifacts) — required

DeployKube treats the backup target as hostile. Tier-0 artifacts landing on the NAS are **encrypted at rest** using `age`:
- Vault raft snapshots: `vault-*-YYYYMMDD-HHMMSS.snap.age`
- Postgres dumps: `YYYYMMDDTHHMMSSZ-dump.sql.gz.age`

The public key (`AGE_RECIPIENT`) is stored in a namespaced `ConfigMap/backup-encryption` alongside the CronJobs (public material only). The private key (age identity) must be stored out-of-band; do **not** store it in-cluster by default.

Legacy note: `mode=filesystem` can encrypt S3 payload-at-rest on the NFS target using `rclone crypt` passphrases from Vault path `secret/backup/s3-mirror-crypt`.

Recovery bundles use the same Age recipient model (`ConfigMap/backup-recovery-encryption`) and are emitted by `storage-backup-set-assemble`.

Storage-level NAS/share encryption is still worth enabling as defense-in-depth, but it is not the primary confidentiality contract and is not repo-attested; the enforced contract is that NFS-held payload classes are encrypted or marker-only.

Recovery-material projection:
- `Secret/backup-recovery-material` (namespace `backup-system`) is projected by ESO from Vault.
  - `RESTIC_PASSWORDS_JSON` is generated from `secret/backup/pvc-restic` lifecycle fields (`RESTIC_PASSWORD`, `RESTIC_PASSWORD_CANDIDATE`, `PASSWORD_VERSION`, `PASSWORD_ROTATED_AT`).
- Breakglass kubeconfig is carried separately as an operator-managed copy:
  - `Secret/backup-breakglass-kubeconfig` key `BREAKGLASS_KUBECONFIG`
  - sync it with `./scripts/ops/sync-breakglass-kubeconfig-to-backup.sh --deployment-id proxmox-talos --source-kubeconfig <path> --confirm-in-cluster-copy yes`
- `proxmox-talos` enforces breakglass inclusion for `storage-backup-set-assemble` (`REQUIRE_BREAKGLASS_KUBECONFIG=true`); dev profiles keep it optional.
- `storage-backup-set-assemble` requires `RESTIC_PASSWORDS_JSON` by default (`REQUIRE_RESTIC_PASSWORDS=true`), so set assembly fails fast if restic recovery material is missing.

Decrypt examples (operator machine):

```bash
# Vault core raft snapshot (decrypt to a plaintext.snap file)
age -d -i "$AGE_KEY_FILE" -o vault-core.snap vault-core-YYYYMMDD-HHMMSS.snap.age

# Postgres dump (decrypt + gunzip; then pipe into psql as needed)
age -d -i "$AGE_KEY_FILE" YYYYMMDDTHHMMSSZ-dump.sql.gz.age | gunzip > dump.sql
```

Postgres restore procedure (tier-0 dump → CNPG cluster):
- `docs/runbooks/postgres-restore-from-tier0-backup.md`

---

## Cadence (automatic backups)

Current prod schedules (CronJobs):
- **Vault core raft snapshots**: hourly (`vault-system/cronjob/vault-raft-backup`, `23 * * * *`).
- **Vault transit raft snapshots**: only when using the transit root-of-trust provider (legacy clusters).
- **Postgres dumps**:
  - Keycloak: hourly (`keycloak/cronjob/postgres-backup`, `10 * * * *`)
  - PowerDNS: hourly (`dns-system/cronjob/postgres-backup`, `20 * * * *`)
  - Forgejo: hourly (`forgejo/cronjob/postgres-backup`, `30 * * * *`)
- **S3 DR replication (Garage → off-cluster S3 endpoint)**: hourly (`backup-system/cronjob/storage-s3-mirror-to-backup-target`, `7 * * * *`).
- **Backup-plane writeability smoke**: hourly (`backup-system/cronjob/storage-smoke-backup-target-write`, `11 * * * *`).
- **Backup-plane freshness smoke**: twice per hour (`backup-system/cronjob/storage-smoke-backups-freshness`, `29,59 * * * *`).
- **Ordinary workload restore-hook contract smoke**: daily (`backup-system/cronjob/storage-smoke-restore-validation-contract`, `19 4 * * *`).
- **Platform restore canary write**: every 6 hours (`backup-system/cronjob/storage-canary-write`, `13 */6 * * *`).
- **Platform restore canary drill**: every 6 hours (`backup-system/cronjob/storage-canary-restore`, `49 */6 * * *`).
- **PVC restic backup plane**: every 6 hours (`backup-system/cronjob/storage-pvc-restic-backup`, `17 */6 * * *`).
- **Backup-set assembler**: hourly (`backup-system/cronjob/storage-backup-set-assemble`, `47 * * * *`).
- **Monthly full-restore marker staleness check**: daily (`backup-system/cronjob/storage-smoke-full-restore-staleness`, `43 4 * * *`) with a 31-day max marker age.
  - Monthly Git evidence policy is validated repo-side via `./tests/scripts/validate-full-restore-evidence-policy.sh` (bootstrap mode by default; strict mode via `REQUIRE_FULL_RESTORE_EVIDENCE_NOTES=true`).
- **Tier-0 pruning**: daily (`backup-system/cronjob/storage-prune-tier0`, `15 3 * * *`).

Alert routing ownership (prod):
- Backup/DR alerts (`service=backup-system`) route to dedicated receiver `backup-system-platform-ops`.
- Receiver endpoints are Vault-backed via `secret/observability/alertmanager` projected to `Secret/mimir-alertmanager-notifications`.
- Routing contract is repo-guarded by `./tests/scripts/validate-backup-alerting-routing-contract.sh`.
- Hostile-NFS confidentiality contract is repo-guarded by `./tests/scripts/validate-backup-target-confidentiality-contract.sh`.

---

## PVC restic password lifecycle (prepare/promote)

Before enforcing non-root execution for PVC restic writer/smoke paths, migrate existing repo ownership/mode once:

```bash
export KUBECONFIG=tmp/kubeconfig-prod
bash./scripts/ops/migrate-pvc-restic-repo-permissions.sh
```

This migration:
- suspends `storage-pvc-restic-backup` and `storage-smoke-pvc-restic-credentials`,
- rewrites `/backup/<deploymentId>/pvc-restic` ownership to `65532:65532`,
- enforces owner-only read/write mode for repo files/directories,
- resumes both CronJobs after completion.

Use the two-phase rotation entrypoint:
- `scripts/ops/rotate-pvc-restic-password.sh prepare`
- `scripts/ops/rotate-pvc-restic-password.sh promote`

Phase contract:
1. `prepare`:
   - suspends `storage-pvc-restic-backup`,
   - runs `restic key add` on every discovered repo under `/backup/<deploymentId>/pvc-restic/namespaces/*/persistentvolumeclaims/*/repo`,
   - stores candidate password in Vault (`RESTIC_PASSWORD_CANDIDATE`) without changing active `RESTIC_PASSWORD`,
   - waits for ESO sync so recovery bundles include both active/candidate values.
2. Validate restore with the candidate password (workload/operator drill).
3. `promote`:
   - suspends `storage-pvc-restic-backup`,
   - runs `restic key remove` for the old key on every repo,
   - promotes candidate to active `RESTIC_PASSWORD`, clears `RESTIC_PASSWORD_CANDIDATE`, increments `PASSWORD_VERSION`, and updates `PASSWORD_ROTATED_AT`,
   - waits for ESO sync and then resumes the backup CronJob.

Example:

```bash
export KUBECONFIG=tmp/kubeconfig-prod
bash./scripts/ops/rotate-pvc-restic-password.sh prepare
# run restore validation drill(s) using the candidate credential
bash./scripts/ops/rotate-pvc-restic-password.sh promote
```

---

## Retention (tier-0 pruning)

Tier-0 artifacts (Vault snapshots + Postgres dumps) are pruned by:
- `backup-system/cronjob/storage-prune-tier0` (daily at `03:15` UTC by default).

Retention is configured in the DeploymentConfig contract:
- `platform/gitops/deployments/proxmox-talos/config.yaml` (`.spec.backup.retention.tier0`)

Default prod policy (GFS-style):
- keep **all** artifacts within `24h`
- keep newest **per day** between `24h..7d`
- keep newest **per ISO week** between `7d..30d`
- delete anything older than `30d`

> Implementation note: `backup-system` mounts `ConfigMap/backup-system/deploykube-deployment-config`, which is published by the deployment-config-controller from the singleton `DeploymentConfig` CR. Repo-authored “copy” snapshots are intentionally forbidden (guardrailed by `./tests/scripts/validate-backup-system-deployment-config-snapshot.sh`).

---

## How to verify backups on prod

### 1) Verify Argo apps are `Synced/Healthy`

```bash
export KUBECONFIG=tmp/kubeconfig-prod
kubectl -n argocd get applications | rg '^(platform-apps|storage-backup-system|secrets-kms-shim|secrets-vault-config|data-postgres-|platform-forgejo-postgres)\s'
```

### 2) Run a manual “backup now” for each tier

Vault core:
```bash
export KUBECONFIG=tmp/kubeconfig-prod
job="vault-raft-backup-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n vault-system create job --from=cronjob/vault-raft-backup "${job}"
kubectl -n vault-system wait --for=condition=complete job/"${job}" --timeout=900s
```

Postgres dumps:
```bash
export KUBECONFIG=tmp/kubeconfig-prod
for ns in keycloak dns-system forgejo; do
  job="postgres-backup-manual-${ns}-$(date -u +%Y%m%d-%H%M%S)"
  kubectl -n "${ns}" create job --from=cronjob/postgres-backup "${job}"
  kubectl -n "${ns}" wait --for=condition=complete job/"${job}" --timeout=1800s
done
```

S3 DR replication / mirror:
```bash
export KUBECONFIG=tmp/kubeconfig-prod
job="storage-s3-mirror-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-s3-mirror-to-backup-target "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=3600s
```

Tenant backups (optional; Tier S):
- Runbook: `docs/toils/tenant-backups.md`

### 3) Run the smokes manually

```bash
export KUBECONFIG=tmp/kubeconfig-prod

job="storage-smoke-backup-target-write-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-smoke-backup-target-write "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s

job="storage-smoke-backups-freshness-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-smoke-backups-freshness "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=200

job="storage-smoke-restore-validation-contract-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-smoke-restore-validation-contract "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=200

job="storage-canary-write-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-canary-write "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=100

job="storage-pvc-restic-backup-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-pvc-restic-backup "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=7200s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=400

job="storage-canary-restore-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-canary-restore "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=200

job="storage-backup-set-assemble-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-backup-set-assemble "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=3600s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=200

job="storage-smoke-full-restore-staleness-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-smoke-full-restore-staleness "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s
kubectl -n backup-system logs job/"${job}" --timestamps --tail=200
```

### 4) Validate monthly full-restore Git evidence policy

```bash
# bootstrap mode (default): validates metadata shape and freshness when notes exist../tests/scripts/validate-full-restore-evidence-policy.sh

# strict mode: require fresh evidence notes for required deployments.
REQUIRE_FULL_RESTORE_EVIDENCE_NOTES=true \
REQUIRED_FULL_RESTORE_EVIDENCE_DEPLOYMENTS=proxmox-talos \./tests/scripts/validate-full-restore-evidence-policy.sh
```

`scripts/ops/restore-from-backup.sh` now writes a typed evidence note by default after marker write:
- `EvidenceType: full-restore-drill-v1`
- `FullRestoreDeploymentId`
- `FullRestoreBackupSetId`
- `FullRestoreRestoredAt`
- `FullRestoreBackupSetManifestSha256`

---

## How to verify artifacts on the Synology (SSH)

This uses the NAS shell (breakglass for verification/troubleshooting).

```bash
ssh root@198.51.100.11 'for p in \
  /volume1/deploykube/backups/proxmox-talos/tier0/vault-core/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/tier0/postgres/keycloak/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/tier0/postgres/powerdns/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/tier0/postgres/forgejo/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/s3-mirror/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/pvc-restic/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/sets/*/recovery/RECOVERY_BUNDLE.json \
  /volume1/deploykube/backups/proxmox-talos/signals/FULL_RESTORE_OK.json \
  /volume1/deploykube/backups/proxmox-talos/tenants/smoke/s3-mirror/LATEST.json \
  /volume1/deploykube/backups/proxmox-talos/tenants/factorio/s3-mirror/LATEST.json \
; do echo "--- $p"; [ -f "$p" ] && cat "$p" || echo "<missing>"; echo; done'
```

---

## Dev deactivation (required)

Backups/DR are disabled by default in dev:
- `platform/gitops/deployments/mac-orbstack-single/config.yaml` has `spec.backup.enabled: false`.
- `storage-backup-system` Argo app is not included in dev environment bundles.

If you intentionally want to test against a non-prod NAS, create a dedicated dev deploymentId and follow the same contract, but keep prod and dev backup targets isolated.
