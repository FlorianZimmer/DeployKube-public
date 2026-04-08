# Guide: Restore from Backup Set (`scripts/ops/restore-from-backup.sh`)

This guide documents the single-command restore entrypoint:
- Script: `scripts/ops/restore-from-backup.sh`
- Design contract: `docs/design/disaster-recovery-and-backups.md`
- Backup-plane operations: `docs/guides/backups-and-dr.md`
- Postgres restore details: `docs/runbooks/postgres-restore-from-tier0-backup.md`

Scope of current script (v1 baseline):
- Vault raft snapshot restore
- Tier-0 Postgres dump restore (Keycloak/PowerDNS/Forgejo)
- Platform S3 bucket restore:
  - preferred: from DR S3 replica endpoint back into primary S3 (`backup.s3Mirror.mode=s3-replication`)
  - legacy: from NFS mirror payload (encrypted `rclone crypt`, plaintext fallback for older sets)
- GitOps safety flow (pause `platform-apps` auto-sync during restore; re-enable afterwards)
- Writes `signals/FULL_RESTORE_OK.json` on success
- Writes a typed Git evidence note by default (`EvidenceType: full-restore-drill-v1`)
- Backup sets now include a GitOps snapshot under `sets/<setId>/gitops/` plus `gitops/SNAPSHOT.json` for exact-revision recovery when Forgejo is unavailable.

Not yet covered:
- Ordinary PVC restore orchestration from the platform restic repo tree (`/backup/<deploymentId>/pvc-restic/...`) is not implemented in this script yet.
- Automated recovery-bundle consumption/decryption flow (backup sets now include encrypted `recovery/recovery-bundle.json.age`, but this script does not yet parse it).

---

## Preconditions

1. Stage 0 + Stage 1 bootstrap is complete for the target cluster.
2. You can access the backup target PVC in `backup-system` (`PVC/backup-target`).
3. You have the Age private key on the operator machine:
   - `--age-key-file <path>`
4. For GitOps-safe restore mode, run with root app autosync paused first (script does this by default).
5. `Secret/backup-system-s3-mirror-crypt` exists in `backup-system` (projected from Vault `secret/backup/s3-mirror-crypt`) when `--restore-s3=true`.
   - Only required when `DeploymentConfig.spec.backup.s3Mirror.mode=filesystem` (legacy).
6. `Secret/backup-system-s3-replication-target` exists in `backup-system` (projected from Vault `secret/backup/s3-replication-target`) when `--restore-s3=true` and `mode=s3-replication`.
7. For `proxmox-talos`, backup sets are now assembled only when `Secret/backup-breakglass-kubeconfig` existed in `backup-system` at backup time, so the encrypted recovery bundle includes a breakglass kubeconfig copy.

Recommended:
- Start from a DR test environment before running against prod.

---

## Basic usage

```bash
bash./scripts/ops/restore-from-backup.sh \
  --set-id latest \
  --age-key-file ~/.config/deploykube/deployments/proxmox-talos/sops/age.key
```

Restore a specific set:

```bash
bash./scripts/ops/restore-from-backup.sh \
  --set-id 20260215T111500Z-3bc56e270c02 \
  --age-key-file ~/.config/deploykube/deployments/proxmox-talos/sops/age.key
```

Dry run:

```bash
bash./scripts/ops/restore-from-backup.sh \
  --dry-run \
  --restore-vault false \
  --restore-postgres false \
  --restore-s3 false \
  --run-backup-smokes false \
  --write-full-restore-marker false \
  --resume-autosync false
```

---

## Common flags

- `--set-id latest|<timestamp>-<gitsha>`: choose backup set.
- `--restore-vault true|false`: include Vault restore.
- `--restore-postgres true|false`: include Postgres restore.
- `--postgres-targets keycloak,powerdns,forgejo`: choose Postgres targets.
- `--restore-s3 true|false`: restore platform S3 buckets.
- `--restore-tenant-s3 true|false`: also restore tenant mirrored buckets (off by default).
- `--pause-autosync true|false`: patch `argocd/Application platform-apps` to disable auto-sync at start.
- `--resume-autosync true|false`: re-enable auto-sync at end.
- `--wait-platform-apps true|false`: wait for `Synced Healthy` after auto-sync resumes.
- `--run-backup-smokes true|false`: run backup-plane smoke jobs after restore.
- `--write-full-restore-marker true|false`: write `FULL_RESTORE_OK.json`.
- `--write-full-restore-evidence-note true|false`: write typed evidence note under `docs/evidence/`.
- `--full-restore-evidence-output <path>`: optional output path override for the evidence note.

---

## What the script does (order)

1. Creates a temporary backup-access pod in `backup-system` mounting `PVC/backup-target`.
2. Resolves `--set-id` (`latest` reads `/backup/<deploymentId>/LATEST.json`).
3. Pauses `platform-apps` auto-sync (default).
4. Restores Vault from `sets/<setId>/tier0/vault-core`.
5. Restores Postgres targets from `sets/<setId>/tier0/postgres/<target>`.
6. Restores S3 bucket data:
   - `mode=s3-replication`: syncs from the configured DR S3 endpoint back into primary Garage.
   - `mode=filesystem` (legacy): restores from `/backup/<deploymentId>/s3-mirror/crypt/` (or legacy plaintext `.../s3-mirror/buckets/*`) back into Garage.
7. Runs backup-plane smokes (optional, default on).
8. Writes `signals/FULL_RESTORE_OK.json` (optional, default on).
9. Re-enables `platform-apps` auto-sync and waits for `Synced/Healthy` (default).
10. Writes a typed full-restore evidence note under `docs/evidence/` (default).

---

## Post-restore checks

At minimum:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
kubectl -n argocd get application platform-apps -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```

Expected:

```text
Synced Healthy
```

And verify marker:

```bash
ssh root@198.51.100.11 'cat /volume1/deploykube/backups/proxmox-talos/signals/FULL_RESTORE_OK.json'
```
