# Platform NTP service

This component publishes an internal NTP endpoint for workloads and LAN clients:

- LAN service: `time-system/platform-ntp` (`LoadBalancer`, UDP/123)
- In-cluster workload service: `time-system/platform-ntp-headless` (headless, UDP/123)
- Protocol/port: `UDP/123`

Implementation details:

- Runtime is a small in-cluster NTP responder (`base/scripts/ntp-server.py`) running in `bootstrap-tools`.
- Node time synchronization remains configured at bootstrap from `DeploymentConfig.spec.time.ntp.upstreamServers`.
- Workloads should use `platform-ntp-headless.time-system.svc.cluster.local` as their NTP source.

## Notes

- This software endpoint is intentionally replaceable with a future hardware NTP source.
- Tenant namespaces receive explicit egress allow rules to this service via Kyverno-generated baseline policies.
- Runtime upstream change runbook: `docs/toils/ntp-upstream-runtime-change.md`.
