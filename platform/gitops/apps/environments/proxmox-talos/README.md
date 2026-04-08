# Proxmox Talos Environment Overlay (prod)

This overlay targets a Proxmox-hosted Talos Linux cluster and uses the `prod.internal.example.com` domain so it can run alongside the macOS/OrbStack dev clusters (`dev.internal.example.com` and `dev-single.internal.example.com`).

## Usage

This overlay is automatically applied when deploying with:
```bash./scripts/bootstrap-proxmox-talos.sh --config bootstrap/proxmox-talos/config.yaml
```

## Configuration

Inherits directly from **environment-neutral base** (`../../base`) with prod-specific patches:
- **PlatformApps controller**: environment patch selects the `platform-apps-controller` proxmox overlay.
- **Tenant registry + intent**: includes `../../tenants/overlays/prod` (tenant registry ConfigMaps + tenant intent `Application`s)
- **MetalLB IP range**: `198.51.100.61-198.51.100.100` (via `patch-app-networking-metallb-config.yaml`)
- **NFS provisioner**: `198.51.100.10:/nvme01/kube` (used for `shared-rwo`; via `patch-app-storage-nfs-provisioner.yaml`)
- **Bootstrap tools**: Uses registry image for Talos (via `patch-all-apps-bootstrap-tools-image.yaml`)
- **Public hostnames**: `*.prod.internal.example.com` via prod component overlays

## Environment Model

```
apps/environments/proxmox-talos/
├── kustomization.yaml      # resources:../../base +../../tenants/overlays/prod + prod patches
├── patches/
│   ├── patch-app-networking-metallb-config.yaml
│   ├── patch-app-storage-nfs-provisioner.yaml
│   └── patch-all-apps-bootstrap-tools-image.yaml
```

## DNS & Access (macOS + Pi-hole)

### Recommended (macOS -> Pi-hole, Pi-hole -> PowerDNS)
Keep macOS pointed at Pi-hole (`198.51.100.3`) and let Pi-hole forward `prod.internal.example.com` into the cluster PowerDNS.

Add a dnsmasq snippet (e.g. mount into `/etc/dnsmasq.d/05-deploykube.conf`):
```ini
server=/prod.internal.example.com/198.51.100.65
```

### macOS resolver (optional override)
Override only the zone on macOS if you cannot change Pi-hole:
```bash
sudo mkdir -p /etc/resolver
cat <<'RESOLVER' | sudo tee /etc/resolver/prod.internal.example.com >/dev/null
nameserver 198.51.100.65
port 53
RESOLVER
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

## Environment Comparison

| Aspect | mac-orbstack (dev) | mac-orbstack-single (dev) | proxmox-talos (prod) |
|--------|---------------------|---------------------------|----------------------|
| Cluster type | Kind on OrbStack | Kind on OrbStack | Talos on Proxmox VMs |
| Domain | dev.internal.example.com | dev-single.internal.example.com | prod.internal.example.com |
| MetalLB range | 203.0.113.240-250 | 203.0.113.240-250 | 198.51.100.61-198.51.100.100 |
| NFS server | OrbStack host container | N/A (local-path profile) | Proxmox ZFS NFS |
| Storage path | /export/nfs | /var/mnt/deploykube/local-path (inside kind node) | /nvme01/kube |
| Base relationship | Inherits `../../base` | Inherits `../../base` | Inherits `../../base` |
| Overlay naming | `overlays/mac-orbstack` | `overlays/mac-orbstack-single` | `overlays/proxmox-talos` |
