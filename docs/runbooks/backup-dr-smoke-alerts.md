# Runbook: Backup/DR smoke and monthly full-restore staleness alerts

These alerts keep the backup plane and DR drill discipline visible:
- backup target writeability + freshness smokes must run and succeed continuously
- monthly full-restore evidence must stay fresh (`FULL_RESTORE_OK.json`)

Related:
- Design: `docs/design/disaster-recovery-and-backups.md`
- Component: `platform/gitops/components/storage/backup-system/README.md`
- Operator guide: `docs/guides/backups-and-dr.md`

## Routing / ownership contract

- Backup/DR alerts are owned by platform ops (`team=platform`, `service=backup-system`).
- Alertmanager fallback routing in prod sends:
  - general platform alerts to receiver `platform-ops`,
  - backup-plane alerts (`service=backup-system`) to receiver `backup-system-platform-ops`.
- Backup receiver cadence target: first notification within 30s + repeats every 15m while firing.
- Receiver endpoints are sourced from Vault path `secret/observability/alertmanager` via
  `ExternalSecret/mimir-alertmanager-notifications` in namespace `mimir`.

Quick config check:

```bash
kubectl -n mimir get externalsecret mimir-alertmanager-notifications -o wide
kubectl -n mimir get secret mimir-alertmanager-notifications -o jsonpath='{.data.ALERTMANAGER_BACKUP_WEBHOOK_URL}' | base64 -d; echo

kubectl -n mimir port-forward svc/mimir-alertmanager 19093:8080
curl -sS -H 'X-Scope-OrgID: platform' http://127.0.0.1:19093/alertmanager/api/v2/status | jq '.config.original'
```

## Alerts

### `BackupPlaneSmokeJobFailed` (critical)

Meaning: a `backup-system` smoke Job failed:
- `storage-smoke-backup-target-write-*`
- `storage-smoke-backups-freshness-*`

### `BackupPlaneSmokeStale` (warning)

Meaning: a smoke CronJob has no successful run in the expected interval:
- `storage-smoke-backup-target-write`
- `storage-smoke-backups-freshness`

### `BackupFullRestoreStalenessJobFailed` (critical)

Meaning: the periodic full-restore marker check failed (`storage-smoke-full-restore-staleness-*`).

Common causes:
- `/backup/<deploymentId>/signals/FULL_RESTORE_OK.json` missing
- marker JSON malformed or `result != ok`
- `restoredAt` older than the configured max age (31 days default)

### `BackupFullRestoreStalenessCronJobStale` (warning)

Meaning: `storage-smoke-full-restore-staleness` has no successful run in the expected daily window.

### `BackupSetAssemblerJobFailed` (critical)

Meaning: a `storage-backup-set-assemble-*` Job failed.

Common causes:
- required tier markers missing/stale
- malformed `LATEST.json` marker documents
- missing/invalid recovery material secret (`Secret/backup-recovery-material` / `RESTIC_PASSWORDS_JSON`)
- permission or filesystem errors while assembling `sets/<timestamp>-<gitsha>/...`

### `BackupSetAssemblerCronJobStale` (warning)

Meaning: `storage-backup-set-assemble` has no successful run in the expected hourly window.

### `BackupPVCResticJobFailed` (critical)

Meaning: a `storage-pvc-restic-backup-*` Job failed.

Common causes:
- missing/invalid restic password secret (`Secret/backup-system-pvc-restic`)
- out-of-scope restic-labeled PVCs (`darksite.cloud/backup=restic` on non-eligible namespaces)
- backup pod image pull or runtime failures (`restic/restic`)

### `BackupPVCResticCronJobStale` (warning)

Meaning: `storage-pvc-restic-backup` has no successful run in the expected window (18h alert window for 6h schedule).

### `BackupPVCResticCredentialSmokeJobFailed` (critical)

Meaning: a `storage-smoke-pvc-restic-credentials-*` Job failed.

Common causes:
- `Secret/backup-system-pvc-restic` missing/empty `RESTIC_PASSWORD`
- `Secret/backup-recovery-material` missing/invalid `RESTIC_PASSWORDS_JSON`
- active password mismatch between `backup-system-pvc-restic` and `backup-recovery-material`
- active/candidate password no longer unlocks one or more discovered platform PVC restic repos

### `BackupPVCResticCredentialSmokeCronJobStale` (warning)

Meaning: `storage-smoke-pvc-restic-credentials` has no successful run in the expected window (18h alert window for 6h schedule).

## Triage (kubectl-only)

1) Inspect backup-system CronJobs:

```bash
kubectl -n backup-system get cronjob \
  storage-smoke-backup-target-write \
  storage-smoke-backups-freshness \
  storage-smoke-pvc-restic-credentials \
  storage-pvc-restic-backup \
  storage-backup-set-assemble \
  storage-smoke-full-restore-staleness \
  -o wide
```

2) Inspect recent Jobs and logs:

```bash
kubectl -n backup-system get job --sort-by=.metadata.creationTimestamp | tail -n 30

# Replace <job-name> with the failed Job from the alert.
kubectl -n backup-system logs job/<job-name> --tail=300
```

3) Verify marker content from the backup target mount:

```bash
pod="backup-full-restore-marker-check-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
spec:
  restartPolicy: Never
  containers:
    - name: check
      image: registry.example.internal/deploykube/bootstrap-tools:1.4
      command: ["sh","-lc"]
      args:
        - |
          set -euo pipefail
          cat /backup/proxmox-talos/signals/FULL_RESTORE_OK.json
          echo
          cat /backup/proxmox-talos/pvc-restic/LATEST.json
      volumeMounts:
        - name: backup
          mountPath: /backup
          readOnly: true
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: backup-target
YAML
kubectl -n backup-system wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${pod}" --timeout=300s
kubectl -n backup-system logs pod/"${pod}"
kubectl -n backup-system delete pod "${pod}" --ignore-not-found
```

4) If marker is stale/missing:
- perform a full restore drill in the DR test environment
- write/update `FULL_RESTORE_OK.json` per the design contract
- capture evidence in `docs/evidence/YYYY-MM-DD-*.md`
