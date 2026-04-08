# DeployKube on Proxmox with Talos Linux

Deploy a production-grade Kubernetes cluster on Proxmox VMs using Talos Linux.

## Public Mirror Notice

This document is part of a sanitized public mirror.

- It is kept to show the bootstrap shape, contracts, and tooling choices.
- It is not a complete public operator handoff.
- Environment-specific values, credentials, and some recovery details were intentionally removed or replaced.

Operator playbook (includes the deployment config contract + DSB/SOPS key handling):
- `docs/guides/bootstrap-new-cluster.md`

## Prerequisites

### On your Mac (control workstation)

```bash
# Install required tools
brew install opentofu talosctl kubectl helm yq jq age

# Optional but recommended
brew install argocd
```

`nc` (netcat) is used by the bootstrap scripts for basic TCP readiness checks (usually preinstalled on macOS).
`dig` is used for DNS preflight (preinstalled on macOS; on Linux install `dnsutils`/`bind-utils`).

### On Proxmox

1. **API Token**: Create an API token with VM management permissions
   - Datacenter → Permissions → API Tokens → Add
   - User: `root@pam` (or dedicated user)
   - Token ID: e.g., `deploykube`
   - Privilege Separation: unchecked (for simplicity)

2. **NFS Export**: Ensure your ZFS dataset is exported
   ```bash
   # On Proxmox host
   zfs get sharenfs nvme01/kube
   # Should show: rw=@10.0.0.0/8,no_root_squash
   ```

3. **SSH access**: Stage 0 uses `ssh`/`scp` to upload the Talos ISO and query VM state.
   - If you use password auth, the script will prompt once and then reuse the authenticated session via SSH multiplexing (no password is stored on disk).
   - Recommended: configure SSH key auth for `root@<proxmox-host>` to avoid password prompts entirely.

## Quick Start

### 1. Configure

```bash
# Copy and customize the config file
cp bootstrap/proxmox-talos/config.example.yaml bootstrap/proxmox-talos/config.yaml

# Edit with your values (especially proxmox.node if different from 'pve')
vim bootstrap/proxmox-talos/config.yaml
```

### 2. Set Environment Variables

```bash
# Proxmox API credentials (bpg/proxmox provider format)
# Option 1: API Token (recommended)
export PROXMOX_VE_API_TOKEN="root@pam!deploykube=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Option 2: Username/Password
# export PROXMOX_VE_USERNAME="root@pam"
# export PROXMOX_VE_PASSWORD="your-password"
```

> **Note**: The token format is `user@realm!tokenid=secret` (all in one string)

### 3. Run Bootstrap

```bash./scripts/bootstrap-proxmox-talos.sh
```

### 3a. Public mirror note

The private working repo contains additional environment-specific recovery and custody steps for production bootstrap. Those details are intentionally omitted from this public mirror.

If `tofu plan/apply` hangs when re-running (common with Proxmox task locks), run with low parallelism:

```bash
TOFU_PARALLELISM=1./scripts/bootstrap-proxmox-talos.sh
```

If you need to re-run Stage 0 after a partial failure and the VMs already exist, Stage 0 will, by default, reuse the existing VMs and generated Talos configs to avoid OpenTofu provider hangs:

```bash
PROXMOX_TALOS_REUSE_EXISTING_VMS=true./scripts/bootstrap-proxmox-talos.sh
```

In reuse mode, Stage 0 will not wait for DHCP/maintenance IPs; it will reconcile the nodes via their configured static IPs (and re-apply Talos config if a node is stuck in maintenance mode).
If Stage 0 seems stuck at `Bootstrapping etcd...`, it usually means `talosctl bootstrap` is hanging; the script enforces per-command timeouts and will retry up to `TALOS_BOOTSTRAP_TIMEOUT_SECONDS`. You can also skip re-running bootstrap by ensuring kubeconfig can be fetched (reuse mode attempts this precheck automatically).

Force a full reprovision (run OpenTofu even if VMs exist):

```bash
PROXMOX_TALOS_FORCE_TOFU=true./scripts/bootstrap-proxmox-talos.sh
```

### `bootstrap-tools` image pre-pull (Talos)

Stage 0 ensures `bootstrap-tools` is pullable by all Talos nodes early (many later GitOps hook Jobs rely on it). If Stage 0 appears stuck at:

`Pre-pulling bootstrap tools image on all nodes:...`

run the equivalent command manually to see the underlying error:

```bash
export TALOSCONFIG=bootstrap/proxmox-talos/talos/talosconfig
talosctl image pull --namespace cri --nodes <node-ip> <image-ref>
```

Tune timeouts if your registry/network is slow:

```bash
TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS=600 \
TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS=180 \./scripts/bootstrap-proxmox-talos.sh
```

### MetalLB Helm conflicts (Argo CD / GitOps)

MetalLB is managed by Argo CD in this repo (`networking-metallb` + `networking-metallb-config`). If you re-run Stage 0 after Stage 1 has already synced those apps, Helm may fail with *server-side apply* conflicts against the `argocd-controller` field manager.

Stage 0 detects Argo CD and skips MetalLB installation/config in that case; reconcile MetalLB via Argo CD instead (sync `networking-metallb` then `networking-metallb-config`).

If `networking-metallb-config` fails with an overlap error from `ipaddresspoolvalidationwebhook.metallb.io`, you likely have a legacy `IPAddressPool` (often named `default-pool`) covering the same range as `orbstack-pool`. List and remove/adjust the overlapping pool(s) so only one pool owns a given IP range:

```bash
kubectl -n metallb-system get ipaddresspools.metallb.io -o wide
kubectl -n metallb-system get l2advertisements.metallb.io -o wide
```

### Cilium reruns

On reruns, Stage 0 will skip the Cilium Helm upgrade if Cilium is already healthy. Force a re-upgrade with:

```bash
FORCE_CILIUM_UPGRADE=true./scripts/bootstrap-proxmox-talos.sh
```

### Cilium init container CrashLoopBackOff on Talos

Talos/containerd typically forbids `CAP_SYS_MODULE` for pods. Cilium’s chart requests `SYS_MODULE` by default for `cilium-agent` and the `clean-cilium-state` init container, which can fail with:
`unable to apply caps: operation not permitted`.

Stage 0 strips `SYS_MODULE` from those capability lists during the Cilium install/upgrade.

### MetalLB Pod Security warnings

If your cluster enforces Pod Security Admission in `metallb-system`, MetalLB may be blocked (speaker/controller need privileged settings/capabilities). Stage 0 labels `metallb-system` with `pod-security.kubernetes.io/*=privileged` by default. Disable/override:

```bash
METALLB_CONFIGURE_POD_SECURITY=false./scripts/bootstrap-proxmox-talos.sh
# or
METALLB_POD_SECURITY_LEVEL=privileged./scripts/bootstrap-proxmox-talos.sh
```

### NFS provisioner Pod Security warnings

The NFS subdir external provisioner mounts the NFS export via an `nfs` volume, which Pod Security "restricted" will block (and many setups warn/audit). Stage 0 labels `storage-system` with `pod-security.kubernetes.io/*=privileged` by default.

```bash
NFS_CONFIGURE_POD_SECURITY=false./scripts/bootstrap-proxmox-talos.sh
# or override level
NFS_POD_SECURITY_LEVEL=privileged./scripts/bootstrap-proxmox-talos.sh
```

If Helm fails with `json: cannot unmarshal bool into Go struct field ObjectMeta.metadata.annotations of type string`, it usually means a chart annotation value was rendered as a boolean. Ensure any annotation values are passed as strings (Stage 0 pins this for `storageclass.kubernetes.io/is-default-class`).

## Stage 1 (Forgejo/Argo) note: GitOps repo snapshot uses git `HEAD`

Stage 1 seeds the in-cluster Forgejo repo from your local `platform/gitops` **as a deterministic snapshot of the current git commit (`HEAD`)** (it does not include uncommitted/untracked files).

If Argo CD shows `Sync: Unknown` with a `ComparisonError` like `app path does not exist`, it usually means your selected overlay (default: `apps/environments/proxmox-talos`) exists in your working tree but is not committed. Fix by committing the overlay, then re-run Stage 1 with a forced reseed:

```bash
git add platform/gitops/apps/environments/proxmox-talos
git commit -m "Add proxmox-talos overlay"
FORGEJO_FORCE_SEED=true BOOTSTRAP_SKIP_STAGE0=true./scripts/bootstrap-proxmox-talos.sh
```

If the RWO provisioner fails to start with `mount.nfs... failed, reason given by server: No such file or directory`, the configured RWO subdirectory likely doesn’t exist on the NFS server. Stage 0 now creates `${storage.nfs.path}/rwo` on the Proxmox host automatically (when `storage.nfs.server` matches `proxmox.host`). Override the subdir name:

```bash
NFS_RWO_SUBDIR=rwo./scripts/bootstrap-proxmox-talos.sh
```

This will:
1. Download Talos ISO (with QEMU guest agent) from Talos Image Factory
2. Upload ISO to Proxmox
3. Create VMs via OpenTofu
4. Apply Talos machine configurations
5. Bootstrap the Kubernetes cluster
6. Install Cilium, MetalLB, Gateway API
7. Configure NFS storage provisioner
8. Install Forgejo and Argo CD
9. Apply the GitOps root application

## Configuration Reference

```yaml
cluster:
  name: deploykube-proxmox     # Cluster name prefix for VMs
  domain: prod.internal.example.com
  kubernetes_version: "1.32.3"
  talos_version: "v1.9.2"

proxmox:
  host: "198.51.100.10"           # Proxmox host IP (for SSH/ISO upload)
  api_url: "https://198.51.100.10:8006/api2/json"
  node: "pve"                  # Proxmox node name
  storage: "local-lvm"         # VM disk storage pool
  iso_storage: "local"         # ISO storage
  bridge: "vmbr0"              # Network bridge

network:
  gateway: "10.0.0.1"
  # Pin etcd peer advertisement to the LAN subnet to avoid etcd drifting to
  # pod-network addresses (which can wedge control-plane recovery after reboot).
  lan_cidr: "10.0.0.0/24"
  # Required: Stage 0 will not guess DNS servers. The first entry should be an internal resolver.
  dns: ["10.0.0.53", "1.1.1.1"]
  preflight:
    enabled: true
    probe_name: example.com
    timeout_seconds: 2
    # Optional: fail fast if internal hostnames don't resolve via the primary DNS server.
    # required_hostnames:
    #   - keycloak.${CLUSTER_DOMAIN}
  control_plane_vip: "10.0.0.100"     # Kubernetes API VIP
  metallb_range: "10.0.0.200-10.0.0.250"

nodes:
  control_plane:
    count: 3
    start_ip: "198.51.100.101"    #.101,.102,.103
    cores: 4
    memory_mb: 8192
    disk_gb: 50
  worker:
    count: 3
    start_ip: "198.51.100.111"    #.111,.112,.113
    cores: 4
    memory_mb: 16384
    disk_gb: 100

storage:
  nfs:
    server: "198.51.100.10"
    path: "/nvme01/kube"
```

## Post-Deployment

### Configure Pi-hole DNS

DeployKube expects your operator/workstation resolver (often Pi-hole) to forward the deployment `baseDomain`
to the in-cluster PowerDNS LoadBalancer IP (defined in the deployment config contract).

```bash
deployment_id=proxmox-talos
domain="$(yq -r '.spec.dns.baseDomain' "platform/gitops/deployments/${deployment_id}/config.yaml")"
powerdns_ip="$(yq -r '.spec.network.vip.powerdnsIP' "platform/gitops/deployments/${deployment_id}/config.yaml")"

echo "server=/${domain}/${powerdns_ip}" | sudo tee "/etc/dnsmasq.d/99-deploykube-${deployment_id}.conf"
pihole restartdns
```

Ensure your Talos node DNS (`bootstrap/proxmox-talos/config.yaml:network.dns`) includes that resolver, so the kube-apiserver
can resolve the OIDC issuer hostname (Keycloak) at runtime.

### Access Services

```bash
# Argo CD (via LoadBalancer IP)
kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# After DNS is configured
open https://argocd.prod.internal.example.com
```

### Talos Management

```bash
# Set talosconfig
export TALOSCONFIG=bootstrap/proxmox-talos/talos/talosconfig

# Check cluster health
talosctl --nodes 198.51.100.100 health

# Upgrade Talos
talosctl --nodes 198.51.100.101 upgrade --image registry.example.internal/siderolabs/installer:v1.9.3
```

## Troubleshooting

### VMs not starting
- Check Proxmox console for boot errors
- Verify ISO was uploaded: `ssh root@198.51.100.10 ls /var/lib/vz/template/iso/`

### Talos config not applying
- Wait for VMs to fully boot (30-60 seconds)
- Check reachability: `talosctl --nodes 198.51.100.101 disks --insecure`

### Stage 0 timeout waiting for bootstrap
- Increase timeouts if your ISO install / disk / network is slow:
  - `TALOS_REBOOT_WAIT_TIMEOUT_SECONDS=1800 TALOS_BOOTSTRAP_TIMEOUT_SECONDS=1800./scripts/bootstrap-proxmox-talos.sh`
- Inspect installer/etcd logs on the first control plane:
  - `export TALOSCONFIG=bootstrap/proxmox-talos/talos/talosconfig`
  - `talosctl --endpoints <cp-ip> --nodes <cp-ip> logs installer --tail 200`
- Verify the Talos nodes can reach `registry.example.internal` (they must pull `registry.example.internal/siderolabs/installer:<talos_version>` during install).

### Kubernetes API not available
- Check VIP ownership: `talosctl --nodes 198.51.100.101 get addresses`
- Ensure the VIP is configured on **all** control plane nodes (not just cp-1). If only one node owns/configures the VIP, the API endpoint becomes a SPOF when that node is down.
- Verify etcd health: `talosctl --nodes 198.51.100.101 etcd members`

### NFS mount failures
- Verify NFS export on Proxmox: `showmount -e 198.51.100.10`
- Check worker node access: `talosctl --nodes 198.51.100.111 read /proc/mounts`

## Cleanup

To remove the cluster:

```bash
cd bootstrap/proxmox-talos/tofu
tofu destroy -auto-approve
```

This removes all VMs from Proxmox but preserves NFS data.
