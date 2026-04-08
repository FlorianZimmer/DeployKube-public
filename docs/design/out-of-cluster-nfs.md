# Out-of-Cluster NFS for OrbStack-Kubernetes (`shared-rwo`)

This design replaces the in-cluster NFS server with a dedicated container that runs alongside OrbStack’s KIND nodes. It removes the Kubernetes networking constraints that blocked rpcbind and other low-numbered RPC services, while keeping the StorageClass manifests identical between development and production (only the endpoint changes).

## Tracking

- Canonical tracker: `docs/component-issues/shared-rwo-storageclass.md`

## Goals

- Provide a reliable NFS backend for the **standard storage profiles** where `shared-rwo` is NFS-backed (OrbStack dev and Proxmox/Talos prod).
- Keep the workload PVC contract stable: most workloads use `shared-rwo` (default); the single-node profile uses node-local `shared-rwo` instead.
- Run an NFS server (Ganesha or kernel `nfsd`) *outside* the Kubernetes cluster but on the same OrbStack bridge so kubelet can talk to it like a classic host export.
- Ensure kubelet can reach portmap (`111` TCP/UDP), NFS (`2049` TCP/UDP), mountd (`20048`), lockd (`32803`), rquotad (`875`), and statd (`662`) directly—no service proxying.
- Make bootstrap/teardown idempotent: start/stop the host NFS container, reconfigure Helm values, and cleanly unmount on teardown.

## Key Requirements (Do Not Skip)

1. **Privileged container with host-level NFS stack**
   - Run the container with `--privileged` (or specific `SYS_ADMIN`, `NET_ADMIN`, `CAP_SYS_MODULE`) so it can mount `/proc/fs/nfsd`, manage rpcbind, and open low ports.
   - Kernel modules (`nfsd`, `lockd`) must be available in OrbStack’s Linux VM.

2. **Host networking or fixed bridge IP**
   - EITHER use `--network host` so the container inherits the OrbStack VM’s IP, OR attach to the same bridge (e.g., `bridge102`) with a static IP like `203.0.113.30`.
   - Verify the IP is routable from all KIND nodes (ping from inside a node via `kubectl debug node/...`).

3. **RPC ports exposed**
   - If using host network, ports are already open on the VM.
   - If using bridge networking, explicitly publish: `-p 111:111/tcp`, `-p 111:111/udp`, `-p 2049:2049/tcp`, `-p 2049:2049/udp`, `-p 20048:20048/tcp`, `-p 20048:20048/udp`, `-p 32803:32803/tcp`, `-p 32803:32803/udp`, `-p 875:875/tcp`, `-p 875:875/udp`, `-p 662:662/tcp`, `-p 662:662/udp`.
   - Confirm with `rpcinfo -p <NFS_IP>` from inside a Kubernetes node; you must see entries for `portmapper`, `mountd`, `nlockmgr`, `nfs`, `rquotad`, `statd`.

4. **Persistent export directory**
   - Prefer a Docker named volume inside OrbStack (for example `deploykube-nfs-data:/export`) so Linux UID/GID changes initiated from Kubernetes are preserved. The helper script uses this mode by default.
   - If you explicitly opt out (`NFS_USE_DOCKER_VOLUME=0`) and bind-mount a host path, ensure macOS is not the backing filesystem (use an ext4 loop device) or ownership changes will fail.
   - Apply `chmod 0777` or appropriate ACLs before starting the container, or run an init hook to set permissions.

5. **Consistent image configuration**
   - Use a vetted NFS image (e.g., Debian + nfs-ganesha, or kernel `nfsd`) with:
     - `rpcbind` started with `-h 0.0.0.0 -h ::`.
     - Kernel exports mark `/export` as `fsid=0` so the NFSv4 mount target is `/` (while the host bind stays `/export`).
     - Optional log level (INFO) and DBus disabled.

6. **Bootstrap integration**
   - Extend the macOS bootstrap scripts (`shared/scripts/bootstrap-mac-orbstack-orchestrator.sh` and its wrappers) to:
     1. Ensure the host container exists (build/pull image, `orb docker run...` if not running).
     2. Update `bootstrap/mac-orbstack/storage/values.yaml` so `nfs.server` points to the host IP and `nfs.path` to `/` (NFSv4 root).
     3. Deploy / upgrade `nfs-subdir-external-provisioner` Helm chart, apply the `shared-rwo` StorageClass manifest (marking it `is-default`), and run verification.
   - Verification: busybox jobs that mount a PVC using `shared-rwo` and perform read/write checks.

7. **Teardown integration**
   - Pause Argo CD (scale the application controller to 0), delete the PVC-owning namespaces so the provisioner cleans up its directories, then remove the `storage-system` namespace before deleting the Kind cluster.
   - Stop the host NFS container (`orb docker stop deploykube-nfs` / `shared/scripts/orb-nfs-host.sh down`) and optionally remove it (`orb docker rm`) if the export directory is empty or by operator approval.

8. **Networking validation (before first use)**
   - From a KIND node (`kubectl debug node/<node>` + `chroot /host`):
     - `rpcinfo -p <NFS_IP>` returns program list.
     - `mount -t nfs4 <NFS_IP>:/ /tmp/test && touch /tmp/test/probe && umount /tmp/test`.
   - From the provisioner pod (`kubectl exec...`):
     - `showmount -e <NFS_IP>` lists `/export`.
     - `mount -t nfs4 <NFS_IP>:/ /tmp/test && ls /tmp/test` succeeds.

## Implementation Outline

1. **Host Setup Script (`shared/scripts/orb-nfs-host.sh`)**
   - Build or pull the `deploykube/orb-nfs:latest` image.
   - Ensure the Docker volume (`deploykube-nfs-data` by default) exists and has open permissions, or honour a user-supplied `--export-path`.
   - Run `orb docker run` with `--privileged`, `--network bridge102`, static IP, the volume mounted at `/export`, and port publishing.
   - Health check: wait for `rpcinfo -p <NFS_IP>` success before returning.

2. **Kubernetes Bootstrap Changes**
   - Add `ensure_external_nfs` that calls the host script (or exits with instructions if the user must run it manually).
   - Update `ensure_shared_storage` to deploy the Helm provisioner, apply the `shared-rwo` StorageClass manifest, and keep the values pointed at the host IP/path.

3. **Teardown Changes**
   - `teardown` should pause Argo CD (scale the application controller to 0), delete the GitOps namespaces that own PVC-backed workloads so the provisioner can process their finalizers, then remove the `storage-system` namespace once the data paths are gone. Only after that should it delete the Kind cluster and call the host teardown script (`orb docker stop`/`orb-nfs-host.sh down`).
   - Never delete `/export` data automatically unless an empty directory was created during bootstrap.

4. **Documentation**
   - Update README with prerequisites:
     - OrbStack’s bridge IP chosen and reserved.
     - Firewall rules allowing node → NFS_IP for the RPC ports.
     - Steps to inspect `rpcinfo`, `showmount`, and sample mounts.
   - Include troubleshooting section (e.g., “If `rpcinfo` shows nothing, restart the host container; check tcpdump on the bridge”).

## Verification Steps

1. Run bootstrap with `ENABLE_SHARED_STORAGE=1 ENABLE_SHARED_STORAGE_VERIFY=1`.
2. Confirm:
   - `kubectl -n storage-system get pods` → provisioner Deployment `Ready`.
   - `kubectl get sc shared-rwo` reports the shared provisioner and mount options (it also exposes the `rwo/<namespace>-<name>` path pattern parameter and is annotated as the default).
3. Create a manual PVC/Pod test (mirrors the bootstrap verification manifests):
   ```bash
   kubectl apply -f platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-pvc.yaml
   kubectl apply -f platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-writer.yaml
   kubectl -n default wait --for=condition=complete job/shared-rwo-writer --timeout=240s
   kubectl logs job/shared-rwo-writer

   kubectl apply -f platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-reader.yaml
   kubectl -n default wait --for=condition=complete job/shared-rwo-reader --timeout=240s
   kubectl logs job/shared-rwo-reader

   kubectl delete -f platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-reader.yaml --ignore-not-found
   kubectl delete -f platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-writer.yaml --ignore-not-found
   kubectl delete -f platform/gitops/components/storage/shared-rwo-storageclass/tests/shared-rwo-pvc.yaml --ignore-not-found
   ```
   Ensure both jobs succeed and the reader prints the writer timestamp/hostname.
4. Capture the bootstrap and smoke-test commands plus a short success summary in your task notes before editing any documentation.
5. Run teardown (`ENABLE_SHARED_STORAGE=1`) and verify host container is stopped (or manual instructions executed).

## Troubleshooting Checklist

- `rpcinfo -p <NFS_IP>` fails:
  - Container not privileged or rpcbind not bound to bridge IP.
  - Firewall/ports blocked on host.
- `mount.nfs4` returns “No such file or directory”:
  - Export path mismatch; confirm `/etc/ganesha/ganesha.conf` `Path` and `Pseudo`.
- `Resource temporarily unavailable`:
  - kubelet still hitting old Service IP—double-check Helm values, restart pods, flush caches, ensure host container is reachable from all nodes.
- Provisioner stuck `ContainerCreating` with `FailedMount`:
  - Verify all RPC ports exposed; run `tcpdump` on bridge to see resets; confirm `showmount -e` works from a node.
- Postgres-backed workloads (`powerdns-postgres`, `keycloak-postgres`, `forgejo-postgres`) now run via CloudNativePG on `shared-rwo`; the earlier UID/GID mismatch is resolved by the OrbStack-backed export.
  - Confirm the host container is running with the Docker volume (`docker --context orbstack inspect deploykube-nfs --format '{{range.Mounts}}{{.Name}}{{end}}'`).
  - Run the host and pod `chown` probes (`touch` + `chown` under `/export` and inside a `shared-rwo` PVC). If either fails, recreate the container with `--force-recreate` or temporarily fall back to `NFS_USE_DOCKER_VOLUME=0` while investigating.
- Vault core (OpenBao) or Step CA pods throw `permission denied` on their raft/badger directories:
  - The bootstrap script automatically normalises `rwo/${namespace}-data-*` directories to the expected UID/GID whenever it runs. If you migrate data manually outside the script, rerun it or issue `docker --context orbstack run --rm -v deploykube-nfs-data:/export alpine:3.20 chown -R <uid>:<gid> /export/rwo/<path>` before restarting the StatefulSet.
- Vault core (OpenBao) pods loop on auto-unseal after a fresh bootstrap:
  - The scripts now purge stale raft data when the corresponding init secret is absent, but if you bootstrap manually ensure the directories under `deploykube-nfs-data:/export/rwo/vault-system-data-vault-*` do not carry data from a previous run.
- Helm uninstall leaves PVC/PV in `Terminating`:
  - The bootstrap cleanup path now strips finalizers and force-deletes the stale `pv/pvc` pair before reinstalling, but if it still lingers run `kubectl patch pvc/pv … -p '{"metadata":{"finalizers":[]}}'` manually and delete again.

## Deliverables

- Host lifecycle script(s) in `shared/scripts/`.
- Updated bootstrap/teardown that call these scripts, manage the external provisioner Helm release, and ensure the `shared-rwo` StorageClass stays in sync.
- Static `shared-rwo` StorageClass manifest in the env overlay so workloads can request RWO volumes from the shared backend.
- Guidance in `docs/guides/mac-orbstack.md` explaining how to start/stop the host NFS container manually if automation fails.
- Regression tests: `shared-rwo` smoke test job, manual `kubectl debug` mount validation instructions.
