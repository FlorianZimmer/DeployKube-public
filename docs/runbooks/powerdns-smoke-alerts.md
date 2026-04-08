# Runbook: PowerDNS smoke alerts (LAN DNS + HTTPS reachability)

This runbook covers the `PowerDNSLanSmokeCronJobStale` / `PowerDNSLanSmokeJobFailed` alerts and the underlying CronJob:

- `CronJob/dns-system/powerdns-dns-http-smoke`

## What this smoke validates

Every 15 minutes, the CronJob:
- resolves key `*.prod.internal.example.com` hostnames via:
  - the authoritative in-cluster PowerDNS LoadBalancer (from DeploymentConfig `spec.network.vip.powerdnsIP`), and
  - the operator/LAN resolver(s) from DeploymentConfig `spec.dns.operatorDnsServers` (e.g. Pi-hole)
- probes HTTPS reachability for key control-plane UIs (Argo CD, Forgejo, Grafana, Vault, Keycloak, Kiali, Hubble, Garage) using the resolved IP (SNI preserved with `curl --resolve`).

This is intended to catch “everything is healthy in-cluster, but operators can’t reach it from the LAN” issues early.

## Quick triage

1. Inspect the most recent Jobs:
   ```bash
   KUBECONFIG=tmp/kubeconfig-prod kubectl -n dns-system get cronjob powerdns-dns-http-smoke
   KUBECONFIG=tmp/kubeconfig-prod kubectl -n dns-system get jobs -l app=powerdns-smoke -o wide
   ```

2. Check logs for the newest failed Job:
   ```bash
   job="$(KUBECONFIG=tmp/kubeconfig-prod kubectl -n dns-system get jobs -l app=powerdns-smoke -o name | tail -n 1 | sed 's#job.batch/##')"
   KUBECONFIG=tmp/kubeconfig-prod kubectl -n dns-system logs "job/${job}" -c smoke
   ```

## Common root causes

### Pi-hole forwarders broken (most common)

Symptoms:
- `PowerDNS` resolves internal hosts, but one of the operator/LAN resolvers (e.g. Pi-hole) times out for `*.prod.internal.example.com`.

Fix:
- Restore the Pi-hole domain forwarders so `prod.internal.example.com` is forwarded to the authoritative PowerDNS LB.
  - Recommended: use `scripts/toils/pihole-configure-zone-forwarder.sh` to apply the forwarder line via the Pi-hole v6 API (uses DeploymentConfig as source of truth).

### PowerDNS LoadBalancer SNAT vs NetworkPolicy (timeouts)

Symptoms:
- Pi-hole (or other operator resolver) times out forwarding to the PowerDNS VIP.
- In-cluster PowerDNS health looks OK, but LAN clients cannot query the authoritative VIP.

Fix:
- Ensure `Service/dns-system/powerdns.spec.externalTrafficPolicy=Local` so pod-level `NetworkPolicy` ipBlocks match real client source IPs (no kube-proxy SNAT to node IPs).

### MetalLB / LoadBalancer reachability

Symptoms:
- PowerDNS and/or Gateway LB IPs change or become unreachable from the LAN.

Fix:
- Check MetalLB speaker health and Service LB allocations.
- Confirm PowerDNS Service is `EXTERNAL-IP=198.51.100.65` and Gateway is `EXTERNAL-IP=198.51.100.62`.

### DNS drift for ingress endpoints

Symptoms:
- DNS answers exist but point at the wrong ingress IP.

Fix:
- Check the DNS sync jobs and their status ConfigMaps.
