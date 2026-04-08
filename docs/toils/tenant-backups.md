# Tenant backups (Garage + backup-system) — ordering + troubleshooting

This toil documents the v1 flow for tenant backups (multitenancy Milestone 7):

- **Backup scoping** is label-driven: tenant namespaces opt in with `darksite.cloud/backup-scope=enabled`.
- **Platform-owned provisioners**:
  - Vault reconciler creates per-project Vault policies + Kubernetes auth roles for the Garage backup provisioner.
  - Garage provisioner creates/ACLs the per-tenant backup bucket and writes per-project restic credentials to Vault.
- **Platform-owned projection** via ESO into tenant namespaces (tenants consume a `Secret`, not ESO CRDs).
- **Off-cluster mirroring**: `backup-system` mirrors tenant backup buckets into a per-tenant subtree with `LATEST.json` markers.

Design: `docs/design/multitenancy-storage.md` (tenant backups contract + backup target layout)

---

## Contracts

### Backup scope label

Tenant namespaces intended to be backed up must have:
- `darksite.cloud/rbac-profile=tenant`
- `darksite.cloud/tenant-id=<orgId>`
- `darksite.cloud/project-id=<projectId>`
- `darksite.cloud/backup-scope=enabled`

### Vault secret path + keys

Per-project tenant backup credentials live under:
- Vault logical key: `tenants/<orgId>/projects/<projectId>/sys/backup`
- KV v2 API paths:
  - `secret/data/tenants/<orgId>/projects/<projectId>/sys/backup`
  - `secret/metadata/tenants/<orgId>/projects/<projectId>/sys/backup`

Values (v1):
- `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`
- `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`
- `PROVISIONED_AT`, `PROVISIONED_BY` (metadata)

### Tenant Kubernetes Secret contract

The platform projects the Vault secret into a tenant namespace `Secret` (name is app-specific; example: `Secret/factorio-backup`).

Keys (current convention):
- `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`
- `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`

---

## Ordering a tenant backup (GitOps flow)

1) Ensure the tenant namespace exists and has the required labels (including `darksite.cloud/backup-scope=enabled`).

2) Ensure the tenant namespace can reach Garage S3 (`garage.garage.svc:3900`) **and only that**:
- Tenant baseline egress is deny-by-default → tenant namespaces need an explicit egress allow `NetworkPolicy`.
- Garage ingress is allowlisted per tenant identity → add a specific allow stanza in `platform/gitops/components/storage/garage/base/networkpolicy.yaml`.

Important: `darksite.cloud/backup-scope=enabled` is **not** a bucket access allow; reachability is enforced separately.

3) Ensure a platform-owned `ExternalSecret` exists in the tenant namespace to project `tenants/<orgId>/projects/<projectId>/sys/backup`.
- Example (Factorio tenant): `platform/gitops/tenants/factorio/projects/factorio/namespaces/prod/externalsecret-factorio-backup.yaml`

4) Commit + seed Forgejo, then let Argo reconcile.

Evidence (prod canary): private runtime evidence is intentionally omitted from the public mirror.

---

## Force provisioning now (don’t wait for CronJobs)

### 1) Reconcile Vault roles/policies for the Garage backup provisioner

```bash
KUBECONFIG=tmp/kubeconfig-prod \
  kubectl -n vault-system create job --from=cronjob/vault-tenant-backup-provisioner-role \
  vault-tenant-backup-provisioner-role-manual-$(date -u +%Y%m%d%H%M%S)
```

Follow logs:

```bash
job=vault-tenant-backup-provisioner-role-manual-<timestamp>
KUBECONFIG=tmp/kubeconfig-prod kubectl -n vault-system logs "job/${job}" --tail=200
```

### 2) Reconcile per-tenant buckets + per-project backup secrets

```bash
KUBECONFIG=tmp/kubeconfig-prod \
  kubectl -n garage create job --from=cronjob/garage-tenant-backup-provisioner \
  garage-tenant-backup-provisioner-manual-$(date -u +%Y%m%d%H%M%S)
```

Follow logs:

```bash
job=garage-tenant-backup-provisioner-manual-<timestamp>
KUBECONFIG=tmp/kubeconfig-prod kubectl -n garage logs "job/${job}" --all-containers --tail=200
```

---

## Verify (end-to-end)

### 1) ExternalSecret is Ready and the tenant Secret exists

```bash
ns=t-<orgId>-p-<projectId>-prod-app
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" get externalsecret -o wide
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" get secret -o name | rg -n 'backup'
```

### 2) App produces a restic snapshot

Check the backup sidecar logs in the tenant namespace.

Factorio example:

```bash
ns=t-factorio-p-factorio-prod-app
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" logs deploy/factorio -c backup --tail=200
```

### 3) Restore drill succeeds (non-destructive)

Run a restore drill job from the tenant CronJob (example: Factorio):

```bash
ns=t-factorio-p-factorio-prod-app
job=factorio-restore-drill-manual-$(date -u +%Y%m%d%H%M%S)
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" create job --from=cronjob/factorio-restore-drill "${job}"
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" wait --for=condition=complete "job/${job}" --timeout=1800s
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" logs "job/${job}" --tail=200
```

### 4) Backup-system mirrors the tenant bucket to the backup target

Check the most recent S3 mirror logs:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n backup-system logs cronjob/storage-s3-mirror-to-backup-target -c mirror --tail=400 | rg -n 'syncing tenant'
```

Inspect the on-target marker and mirrored bucket subtree (read-only):

```bash
ns=backup-system
pod=backup-target-inspect-$(date -u +%Y%m%d%H%M%S)
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: inspect
      image: busybox:1.36
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 1000
        capabilities:
          drop: ["ALL"]
      command: ["sh","-lc"]
      args:
        - |
          set -e
          echo "== tenant markers (factorio example) =="
          ls -la /backup/proxmox-talos/tenants/factorio/s3-mirror/LATEST.json
          head -n 50 /backup/proxmox-talos/tenants/factorio/s3-mirror/LATEST.json
          echo "== tenant bucket subtree =="
          ls -la /backup/proxmox-talos/tenants/factorio/s3-mirror/buckets/tenant-factorio-backups | head -n 50
      volumeMounts:
        - name: backup
          mountPath: /backup
          readOnly: true
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: backup-target
YAML
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" wait --for=jsonpath="{.status.phase}"=Succeeded --timeout=300s "pod/${pod}"
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" logs "pod/${pod}"
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" delete pod "${pod}"
```

---

## Troubleshooting

### Tenant can’t reach Garage S3 (backups time out)

Symptoms:
- backup sidecar logs show S3 timeouts or connection refused.

Checks:
1) Tenant egress allow exists (tenant namespace → `garage` namespace port `3900`).
2) Garage ingress allowlist contains the tenant’s identity labels:
   - `darksite.cloud/rbac-profile=tenant`
   - `darksite.cloud/tenant-id=<orgId>`
   - `darksite.cloud/project-id=<projectId>`

### ExternalSecret is not Ready / Secret missing

Common causes:
- Vault key does not exist yet → run the provisioners manually (above).
- Incorrect `remoteRef.key` / `property` mappings.
- ESO cannot reach Vault (check ESO/Vault baseline health first).

### Garage provisioner says “tenant bucket not accessible; skipping” in backup-system mirror

This usually means the platform mirror key (`secret/garage/s3.S3_ACCESS_KEY`) does not have read access to the tenant bucket.

Checks:
- Re-run `garage-tenant-backup-provisioner` and confirm it grants the platform mirror key read-only access.
- Ensure `Secret/backup-system/backup-system-garage-s3` has the expected access key and endpoint.

---

## Rotation / crypto-delete (v1)

Provisioner behavior:
- If `secret/tenants/<orgId>/projects/<projectId>/sys/backup` exists, the provisioner reuses stored key material.
- If it does not exist, it generates new credentials and writes them.

Warning:
- Deleting the Vault key and re-provisioning effectively performs a **cryptographic delete** for the old repo (existing restic data becomes unreadable without the old password).
- Platform PVC restic rotation now has a productized two-phase workflow (`scripts/ops/rotate-pvc-restic-password.sh`); tenant-scoped restic repos still use crypto-delete semantics unless an explicit tenant rotation workflow is introduced.
