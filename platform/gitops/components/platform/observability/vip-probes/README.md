# VIP Probes (DNS + HTTPS)

Synthetic probes for **VIP reachability + latency** (PowerDNS VIP on `:53`, Istio public gateway VIP on `:443`), implemented via **Grafana Alloy’s embedded blackbox exporter** (`prometheus.exporter.blackbox`) and remote-written into Mimir.

## Why this exists

We’ve observed intermittent timeouts hitting the PowerDNS VIP from within the cluster (MetalLB L2 + LAN VIP path). Before diagnosing root cause, we need time series for:
- **Probe success rate**
- **Probe duration / latency**

This component provides those metrics without introducing another exporter Deployment.

## How it works

1. `vip-probes` (this component) creates a ConfigMap `vip-probes-config` containing:
   - `blackbox_modules.yml` (probe definitions)
   - `targets.yml` (probe targets + labels)
   - `ca.crt` (DeployLab CA root for TLS verification)
2. `alloy-metrics` mounts the ConfigMap and runs:
   - `discovery.file` → reads `targets.yml`
   - `prometheus.exporter.blackbox` → executes probes
   - `prometheus.scrape` → scrapes probe results and remote-writes to Mimir
3. Grafana dashboards query Mimir for `probe_success`, `probe_duration_seconds`, etc.

## Overlays

- `overlays/<deploymentId>/`: deployment-specific probe targets and module settings.
  - `proxmox-talos`: probes the pinned Proxmox/Talos VIPs (PowerDNS + public gateway).
  - `mac-orbstack*`: probes the dev PowerDNS VIP; HTTPS probe targets the in-cluster gateway service (no pinned gateway VIP).

### Overlay layout note (explicit exception)

This component is intentionally **overlay-heavy**: the ConfigMap payload (`targets.yml`, `blackbox_modules.yml`) and parts of the NetworkPolicy are deployment-specific (VIP IPs, hostnames, gateway target shape). Keeping those files in `overlays/<deploymentId>/` avoids awkward templating and keeps the probe inputs explicit.

## Key metrics

Typical series (labels come from `targets.yml`):
- `probe_success{job="vip-probes", name="..."}`
- `probe_duration_seconds{job="vip-probes", name="..."}`
- `probe_http_status_code{job="vip-probes", name="..."}`
