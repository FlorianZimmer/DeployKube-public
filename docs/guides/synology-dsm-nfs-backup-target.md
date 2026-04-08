# Guide: Synology DSM 7.2.1 — Configure NFS Backup Target for DeployKube

Goal: expose a dedicated **off-cluster** NFSv4.1 export from a Synology NAS that DeployKube (prod) mounts as its DR backup target.

Default DeployKube prod target (today’s manifests):
- NAS IP: `198.51.100.11`
- NFS export root: `/volume1/deploykube/backups`
- DeploymentId subpath: `/volume1/deploykube/backups/proxmox-talos/`

This guide describes the DSM 7.2.1 UI steps to match that contract.

---

## 0) Preconditions

- NFSv4.1 is enabled on DSM.
- The NAS is reachable from the Kubernetes nodes (Proxmox/Talos cluster) on TCP/2049.
- You know the Kubernetes node subnet (current prod: `198.51.100.0/24`).

---

## 1) Create the Shared Folder

We need the on-disk path to be `/volume1/deploykube/backups`.

In DSM:
1. **Control Panel → Shared Folder → Create**
2. Name: `deploykube`
3. (Volume): `volume1`
4. (Encryption): recommended defense-in-depth only; if enabled, ensure it auto-mounts on boot (otherwise your backups will silently break when the NAS restarts).
5. (Permissions): keep this tight (the NFS export is the real access surface, but the share ACL still matters).
   - Recommended baseline: give `administrators` **Read/Write**, remove/deny broad groups like `users` / `everyone` unless you explicitly want them.
5. Finish.

Then create the `backups` subfolder inside that share:
- **File Station → deploykube → Create → Folder** → name: `backups`

Resulting path:
- `/volume1/deploykube/backups`

---

## 2) Enable NFS permissions for the share

In DSM:
1. **Control Panel → Shared Folder**
2. Select the `deploykube` share → **Edit**
3. Go to the **NFS Permissions** tab → **Create**

> [!IMPORTANT]
> The v1 DeployKube backup target uses **AUTH_SYS** (host-based auth) and is typically **unencrypted** in transit. Treat the NAS export as hostile and rely on **in-cluster encryption-at-rest of backup artifacts** (tier-0 uses `age`; see `docs/guides/backups-and-dr.md`).
>
> Synology share encryption is defense-in-depth only. The primary confidentiality contract is repo-enforced artifact protection: tier-0 dumps/snapshots and recovery bundles are `age`-encrypted, PVC repos are encrypted by restic, and prod S3 payload stays off NFS via `mode=s3-replication`.

### Easy mode (v1 baseline; simplest)

- **Hostname or IP**: `198.51.100.0/24`
- **Privilege**: `Read/Write`
- **Squash**: `No mapping` (equivalent to “no root squash”; simplest for Kubernetes)
- **Security**: `sys`
- **Enable asynchronous**: enabled (performance); integrity is guarded by marker semantics (jobs must not advance markers on partial/failed writes).
- **Allow connections from non-privileged ports (insecure)**: enabled (Kubernetes clients commonly use high source ports).

Save.

### Secure mode (recommended if feasible)

If you can make it work with your UID/GID and directory ownership model, prefer:
- **Squash**: `Map root to admin` (root-squash)
- **Enable asynchronous**: disabled (sync writes)
- **Allow connections from non-privileged ports (insecure)**: disabled *if* your Kubernetes nodes can mount from privileged ports; otherwise keep enabled and rely on network segmentation + encryption-at-rest.

Note: if you change squash/mapping mode, you may need to align:
- NAS directory ownership/permissions under `/volume1/deploykube/backups`
- Kubernetes Job `securityContext` (`runAsUser`, `runAsGroup`, `fsGroup`)

### What the DSM NFS fields mean (quick glossary)

- **Hostname or IP**: which clients may mount the export (use a subnet or explicit node IPs).
- **Privilege**: read/write vs read-only from those clients.
- **Squash**:
  - `No mapping`: root on the client stays root on the NAS (no root-squash).
  - Other modes map root/all users to an unprivileged NAS identity; this is safer but requires UID/GID alignment.
- **Security**: auth flavor (v1 baseline uses `sys`, i.e. AUTH_SYS; stronger Kerberos modes are possible but not implemented here).
- **Enable asynchronous**: allows the NAS to acknowledge writes before they hit stable storage (faster; acceptable when the backup plane uses “marker semantics” and treats partial writes as failures).
- **Allow connections from non-privileged ports (insecure)**: allows clients whose source port is >1024 (common in Kubernetes).

---

## 3) (Optional) DSM Firewall

If DSM firewall is enabled:
- Allow inbound **TCP 2049** from `198.51.100.0/24`.

For NFSv4.1-only setups, TCP/2049 is the main requirement (unlike NFSv3, which needs rpcbind/mountd ports).

---

## 4) Create the directory layout expected by DeployKube (prod)

Create these folders under `/volume1/deploykube/backups/proxmox-talos/`:

- `tier0/vault-core/`
- `tier0/postgres/keycloak/`
- `tier0/postgres/powerdns/`
- `tier0/postgres/forgejo/`
- `s3-mirror/`

You can do this in File Station or via SSH on the NAS.

---

## 5) Quick end-to-end verification

From a machine with the prod kubeconfig:
```bash
export KUBECONFIG=tmp/kubeconfig-prod
job="storage-smoke-backup-target-write-manual-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n backup-system create job --from=cronjob/storage-smoke-backup-target-write "${job}"
kubectl -n backup-system wait --for=condition=complete job/"${job}" --timeout=600s
```

On the NAS, you should see the smoke write under:
- `/volume1/deploykube/backups/proxmox-talos/smoke/backup-target-write/`

---

## 6) When things fail (common DSM-side symptoms)

### `mount.nfs: access denied by server`
- The NFS Permissions entry is missing, too narrow, or points at the wrong share.
- Re-check: Shared Folder `deploykube` → Edit → **NFS Permissions** includes `198.51.100.0/24` with RW.

### Write permission errors (`permission denied`)
- If you selected any squash/mapping mode other than `No mapping`, the effective UID/GID may not match directory permissions.
- Fix by either:
  - switching to `No mapping`, or
  - aligning the directory ownership + Kubernetes securityContext/fsGroup (recommended only if you want stricter NAS policy).
