# NTP / PTP feature requests

## Implemented baseline (NTP)
- Cloud-wide upstream NTP sources via `DeploymentConfig.spec.time.ntp.upstreamServers`.
- Proxmox Stage 0 Talos node time config wired from DeploymentConfig upstream list.
- In-cluster/LAN-published software NTP endpoint (`time-system/platform-ntp`, `LoadBalancer` UDP/123) for workloads and LAN clients.

## Requested next (deferred)
- PTP support (intentionally not implemented yet):
  - DeploymentConfig contract for PTP mode/source selection.
  - Platform PTP service/profile wiring for workloads that require sub-millisecond sync.
  - Future hardware time-source integration path (replace software endpoint while keeping stable workload-facing source contract).
