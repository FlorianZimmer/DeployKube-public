# Introduction

This component provides the **Authoritative DNS** service for the internal zone (`dev.internal.example.com` / `prod.internal.example.com`). It serves as the bridge between the Kubernetes Ingress Gateway (MetalLB IP) and the rest of the network (LAN/VPN/Mac resolver).

It includes:
- **PowerDNS Authoritative Server**: The actual DNS server (TCP/UDP 53).
- **ExternalDNS**: Automated record management for Kubernetes Ingress/Gateway/Service resources.
- **Bootstrap Jobs**: DB schema initialization and base zone creation.

For open/resolved issues, see [docs/component-issues/powerdns.md](../../../../docs/component-issues/powerdns.md).

> [!NOTE]
> Deployment-derived DNS wiring (base domain, Service VIP pinning, ExternalDNS args, config checksums) is controller-owned by `components/platform/tenant-provisioner`.
> Per-deployment overlays under `overlays/<deploymentId>/` remain for **static** deltas (e.g. NetworkPolicies, MetalLB address-pool annotations).

---

## Architecture

```mermaid
flowchart TB
    subgraph dns-system
        PDNS[PowerDNS Auth<br/>(Deployment)]
        EXT[ExternalDNS<br/>(Deployment)]
        INIT[Schema Job]
        ZONE[Zone Bootstrap]
        SVC[Service<br/>LoadBalancer]
        ESO[ExternalSecrets]
    end

    subgraph "External / Data"
        CNPG[CloudNativePG<br/>(Postgres Cluster)]
        VAULT[Vault<br/>(Secrets)]
    end

    EXT -->|Updates via API| PDNS
    PDNS -->|Reads Zones| CNPG
    INIT -->|Creates Schema| CNPG
    ZONE -->|Creates SOA/NS| PDNS
    SVC -->|Routes 53/8081| PDNS
    ESO -->|Syncs Creds| VAULT
```

- **Backend**: Backed by a high-availability Postgres cluster (`data-postgres-powerdns`).
- **Automation**: ExternalDNS pushes changes to PowerDNS via the HTTP API (localhost access or Service access).
- **Connectivity**: Exposed via MetalLB to the LAN. The Mac resolver or Pi-hole forwards the specific internal zone to this IP.

---

## Subfolders

| Path | Purpose |
|------|---------|
| `base/` | Shared manifests (PowerDNS Deployment/Service, bootstrap Jobs, ESO wiring). |
| `overlays/<deploymentId>/` | Per-deployment static deltas (no DeploymentConfig rendering). |

---

## Container Images / Artefacts

| Artefact | Version | Source |
|----------|---------|--------|
| PowerDNS Auth | `4.6.4` | `powerdns/pdns-auth-46` |
| ExternalDNS | `v0.14.1` | `registry.k8s.io/external-dns/external-dns` |
| Bootstrap Tools | `1.4` | `registry.example.internal/deploykube/bootstrap-tools` |

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `data-postgres-powerdns` | Must be healthy (Wave 0.5). Provides the database backend. |
| `secrets-external-secrets` | Must be running to sync Vault credentials. |
| `networking-metallb` | Required for LoadBalancer IP assignment. |

---

## Communications With Other Services

### Kubernetes Service → Service Calls

- **PowerDNS → Postgres**: Connects to `powerdns-postgresql.dns-system.svc.cluster.local:5432` (read/write).
  - TLS: `sslmode=verify-full` with `sslrootcert` mounted from `Secret/postgres-ca` (CNPG-generated CA).
- **ExternalDNS → PowerDNS**: Connects to `http://127.0.0.1:8081` (if sidecar) or service (if separate). Currently separate deployments.
- **Jobs → PowerDNS API**: Connect via `http://powerdns:8081` to manage zones.

### External Dependencies

- **Vault**: Source of `secret/dns/powerdns/postgres` and `secret/dns/powerdns/api`.

### LoadBalancer Source IP Preservation (prod)

For `prod` deployments, the PowerDNS Service is a MetalLB `LoadBalancer` and is protected by pod-level `NetworkPolicy` ipBlocks.
To make those ipBlocks match the real LAN client (Pi-hole / operator machine) IPs, the Service preserves the client source IP:

- `Service/dns-system/powerdns.spec.externalTrafficPolicy=Local`

### Mesh-level Concerns

- **Namespace posture**: `dns-system` is `istio-injection=enabled`, but **PowerDNS pods explicitly disable injection** (`sidecar.istio.io/inject: "false"`) to avoid UDP/53 interception complexity.
- **mTLS Exception**: PowerDNS API (8081) does NOT have a sidecar. A `DestinationRule` disables mTLS for `powerdns.dns-system.svc.cluster.local` so mesh-enabled clients (ExternalDNS) can reach it.

---

## Initialization / Hydration

1. **Secrets**: ESO syncs `powerdns-postgres-app` and `powerdns-api`.
2. **Schema Init**: `powerdns-db-init` (Sync Hook) connects to Postgres and runs schema DDL if tables are missing.
   - Runs **sidecarless** (`sidecar.istio.io/inject: "false"`) so the Job completion is not blocked by Envoy lifecycle.
3. **Startup**: PowerDNS pods start.
4. **Zone Bootstrap**: `powerdns-zone-bootstrap` (PostSync) checks if the zone exists via API; creates it if valid.
   - Runs **sidecarless** (`sidecar.istio.io/inject: "false"`).
   - Uses `argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation` to avoid “spec.template is immutable” errors on re-syncs (Jobs cannot be patched in-place).

---

## Argo CD / Sync Order

| Application | Sync Wave | Notes |
|-------------|-----------|-------|
| `data-postgres-powerdns` | `0.5` | DB must be ready first. |
| `networking-dns-powerdns` | `1` | Core DNS infrastructure. |
| `networking-dns-external-sync` | `12` | depends on DNS being ready. |

- **Hooks**:
    - `powerdns-db-init`: **Sync** (runs before Deployment registers as Healthy).
    - `powerdns-zone-bootstrap`: **PostSync** (needs API to be reachable).

Operational note:
- If a hook Job ever needs to change, ensure it has `BeforeHookCreation` in its delete policy so Argo recreates the Job instead of attempting to patch it.

---

## Operations (Toils, Runbooks)

### Credential Rotation
Managed via Vault.
```bash
vault kv put secret/dns/powerdns/api apiKey="$(openssl rand -hex 32)"
```
Restart PowerDNS and ExternalDNS pods to pick up new keys.

### Debugging Resolution
```bash
# Example (mac-orbstack): query the PowerDNS LoadBalancer IP directly
dig @203.0.113.245 forgejo.dev.internal.example.com
```

---

## Customisation Knobs

| Knob | Location | Default |
|------|----------|---------|
| Base domain | `platform/gitops/deployments/<deploymentId>/config.yaml` | `.spec.dns.baseDomain` (controller-owned wiring) |
| PowerDNS VIP | `platform/gitops/deployments/<deploymentId>/config.yaml` | `.spec.network.vip.powerdnsIP` (controller-owned wiring) |
| Postgres Credentials | Vault | Stored in `secret/dns/powerdns/postgres` |

---

## Oddities / Quirks

1. **Sidecarless Pods**: PowerDNS pods do not run Istio sidecars to avoid intercepting UDP/53 traffic, which can be problematic.
2. **Postgres Connection**: Uses `powerdns-postgresql` ExternalName service to map to the CNPG RW service in `dns-system`.
3. **CoreDNS Forwarding**: In `networking/coredns`, a stub-domain server block forwards the zone to the PowerDNS VIP (DeploymentConfig-derived; patched by tenant provisioner) to keep in-cluster resolution stable.
4. **ConfigMap-driven config**: `pdns.conf` is rendered by an initContainer into an `emptyDir`; tenant provisioner patches a checksum annotation so config changes roll pods deterministically.

---

## TLS, Access & Credentials

| Concern | Details |
|---------|---------|
| TLS | **None**. Internal API is plaintext HTTP. DNS is UDP/TCP 53. |
| Access | API guarded by `X-API-Key`. Database guarded by Postgres auth. |
| Credentials | All secrets injected via Environment Variables from ESO secrets. |

### Delegation / Cloud DNS Exposure Contract

- Delegation is not implicit. `spec.dns.delegation.mode` must be set to `manual` or `auto`; when unset, the controller normalizes it to `none`.
- Manual delegation output is published on `DeploymentConfig.status.dns.delegation`; the legacy `argocd/ConfigMap/deploykube-dns-delegation` surface has been retired.
- The current proxmox overlay is intentionally LAN-scoped:
  - `NetworkPolicy/powerdns-allow-lan-dns` only allows UDP/TCP 53 from the configured LAN/VPN CIDRs.
  - `NetworkPolicy/powerdns-allow-api` only allows TCP 8081 from the in-cluster reconcilers and smoke jobs that need it.
- If this service is used as a delegated authoritative endpoint beyond the LAN, that is an explicit exposure change. The deployment must add matching firewall and abuse-control policy with evidence; do not treat the current overlay as internet-ready by default.

---

## Dev → Prod

| Aspect | mac-orbstack (`overlays/mac-orbstack`) | proxmox-talos (`overlays/proxmox-talos`) |
|--------|-----------------------------------------|-------------------------------------------|
| PowerDNS VIP | `203.0.113.245` | `198.51.100.65` |
| Domain | `dev.internal...` | `prod.internal...` |
| Network Policies | None | Explicit allow for LAN `198.51.100.0/24`. |

---

## Smoke Jobs / Test Coverage

### Current State

| Job | Status |
|-----|--------|
| **Zone Bootstrap** | ✅ PostSync Job ensures base zone/records exist. |
| **DNS+HTTP Smoke** | ✅ `powerdns-dns-http-smoke` (Overlay) |

### Smoke Job Details
The overlay (`proxmox-talos`) deploys a CronJob `powerdns-dns-http-smoke` running every 15 minutes. It:
1. Queries PowerDNS for `forgejo.prod.internal...`, `argocd.prod.internal...`, etc.
2. Verifies the returned IP matches the Ingress Gateway VIP.
3. Performs `curl` checks against those hostnames (using `--resolve` to force the path through PowerDNS) to prove end-to-end connectivity.

To run manually:
```bash
kubectl -n dns-system create job --from=cronjob/powerdns-dns-http-smoke manual-smoke-test
```

---

## HA Posture

### Analysis

| Aspect | Status | Details |
|--------|--------|---------|
| **Frontend** | ✅ High | Deployment with 2 replicas + `podAntiAffinity` (hostname). |
| **Backend** | ✅ High | CloudNativePG Cluster (3 replicas, auto-failover) in `data-postgres-powerdns`. |
| **Network** | ✅ High | MetalLB LoadBalancer (VIP); CoreDNS forwarding fallback for internal clients. |

**Conclusion**: High availability is well-architected for both compute and data layers.

---

## Security

### Current Controls

| Layer | Control | Status |
|-------|---------|--------|
| **Network** | NetworkPolicy | ✅ Default Deny + Allow LAN (53/udp+tcp) + Allow Monitoring. |
| **RBAC** | ServiceAccount | ✅ Standard (no cluster admin). |
| **User** | RunAsUser | ❌ **Running as Root (0)**. |
| **Secrets** | Projection | ✅ Env vars from ESO (no storage on disk). |

### Security Analysis
1. **Root Execution**: The container runs as root (`runAsUser: 0`). This is often required for binding port 53, but could be mitigated with `NET_BIND_SERVICE` cap and non-root user.
2. **Plaintext API**: The API is HTTP. Access is restricted by NetworkPolicy (only from Ingress/Prometheus/ExternalDNS) and `X-API-Key`, but traffic is visible to sidecars.
3. **Open Resolver**: The service allows 0.0.0.0/0 (via LoadBalancer) to query. `webserver-allow-from=0.0.0.0/0` is also set (though protected by API key).

**Recommendation**: Investigate running as non-root with capabilities.

---

## Backup and Restore

### Current State

| Aspect | Status |
|--------|--------|
| **Data** | Stored in Postgres (`data-postgres-powerdns` in `dns-system`). |
| **Mechanism** | PVC-based database-only `pg_dump` CronJob (`postgres-backup`) writing to `PVC/postgres-backup-v2` (see `components/data/postgres/powerdns`). |
| **PITR** | **Not implemented** (CNPG barman object-store backups are owned by `backup-system`). |

**Restoration**:
1. PowerDNS is stateless code; it connects to the DB.
2. Stop writes (scale down `Deployment/powerdns` and `Deployment/externaldns`).
3. Restore the database from the most recent dump in `postgres-backup-v2` (manual process today; see `components/data/postgres/powerdns/README.md`).
4. Scale PowerDNS back up and restart pods to flush caches.
