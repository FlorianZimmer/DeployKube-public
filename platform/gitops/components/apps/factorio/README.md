# Factorio Hosting

Deploys a headless Factorio game server with "Space Age" support, persistent storage, and public reachability.

> Multitenancy note (2026-01-21): Factorio is operated as the tenant backup canary (`tenant=factorio`, `project=factorio`) and is deployed from the tenant repo seed at `platform/gitops/tenant-repos/tenant-factorio/apps-factorio/`. This component (`components/apps/factorio`) remains a legacy, platform-owned example app (namespace `factorio`) and is not part of the default platform bundle.

## Architecture

- **Deployment:** Single-replica `Deployment` managing the `factoriotools/factorio` container.
- **Network:** Exposed via `Service` type `LoadBalancer` (UDP 34197).
- **Storage:** `PersistentVolumeClaim` (`factorio-data`) using `shared-rwo`.
- **Secrets:** Credentials (`username`/`token`) are stored in Vault (`secret/apps/factorio`) and synced into the namespace via External Secrets Operator (ESO).
- **Backups:** Restic sidecar (`itzg/mc-backup`) snapshots:
  - newest save `.zip` under `/factorio/saves`,
  - `/factorio/config`,
  - `/factorio/player-data.json`,
  to S3/Garage (Vault-managed).

## Subfolders

| Path | Purpose |
| ---- | ------- |
| `base/` | Core Deployment, Service, PVC, ExternalSecrets, and backup sidecar. |
| `overlays/` | Environment-specifics (e.g., pinning LoadBalancer IPs). |

## Container Images / Artefacts

- **Connector:** `factoriotools/factorio:stable` (Game Server).
- **Backup:** `itzg/mc-backup:latest` (Restic backup loop).

## Dependencies

- **Namespace:**
  - Legacy example app: `factorio`
  - Tenant app: `t-factorio-p-factorio-{dev,prod}-app`
- **Secrets:** Vault + External Secrets Operator must be functional (`vault-core` `ClusterSecretStore`).
- **Storage:** `shared-rwo` class must be available.
- **Object storage:** Garage S3 and Vault Garage credentials (`secret/garage/s3`) to back up to S3 via restic.

## Communications With Other Services

### Kubernetes Service → Service calls
- **Probes:** TCP 27015 (RCON port) used for Liveness/Readiness probes.

### External dependencies (Vault, Keycloak, PowerDNS)
- **Factorio.com:** Server authenticates outbound to listing/mod APIs.
- **S3 (Garage):** Backup sidecar pushes restic snapshots to the Garage backups bucket.

### Mesh-level concerns (DestinationRules, mTLS exceptions)
- **UDP:** Game traffic is UDP. Istio sidecars (if injected) technically support UDP but often add latency.
- **Workload:** Sidecar injection is enabled to allow the backup container to reach in-mesh services like Garage (`sidecar.istio.io/inject: "true"`). UDP game traffic remains out-of-band.

## Initialization / Hydration

- **Secrets hydration:** ESO periodically syncs:
  - `Secret/factorio/factorio-secret` from Vault `secret/apps/factorio`
  - Legacy example app: `Secret/factorio/factorio-backup` from Vault `secret/apps/factorio/backup`
  - Tenant app: `Secret/*/factorio-backup` from Vault `secret/tenants/factorio/projects/factorio/sys/backup` (platform-owned projection)
- **Backups:** A restic sidecar runs a periodic backup loop and prunes snapshots using retention policy.

## Argo CD / Sync Order

- **Standard:** Syncs with other apps.
- **Dependencies:** Vault + ESO must be healthy; otherwise ExternalSecrets will not populate the required Secrets.

## Operations (Toils, Runbooks)

- **Update Credentials:**
  - Write the Factorio account values to Vault:
    ```bash
    export VAULT_ADDR=https://vault.<env>.internal.example.com
    export VAULT_CACERT=shared/certs/deploykube-root-ca.crt
    vault kv patch secret/apps/factorio username="YOUR_USERNAME" token="YOUR_TOKEN"
    ```
- **Save Management:** Saves live in `/factorio` on the PVC.
- **Logs:** `kubectl -n <namespace> logs deploy/factorio -f`.
- **Backup status:** `kubectl -n <namespace> logs deploy/factorio -c backup --tail=200`
- **Manual backup (full, slow):** `kubectl -n <namespace> exec deploy/factorio -c backup -- restic backup /factorio/saves /factorio/config`
- **List snapshots:** `kubectl -n <namespace> exec deploy/factorio -c backup -- restic snapshots`
- **Restore (safe dry-run into scratch):**
  - The backup container mounts an `emptyDir` at `/restore`. Restore into it without touching the live PVC:
    ```bash
    kubectl -n <namespace> exec deploy/factorio -c backup -- sh -c 'rm -rf /restore/* && restic restore latest --target /restore && ls -la /restore/factorio || true'
    ```
- **Automated restore drill (non-destructive):**
  - CronJob `factorio-restore-drill` restores `latest` into scratch and asserts expected files exist.
  - Run on-demand:
    ```bash
    kubectl -n <namespace> create job --from=cronjob/factorio-restore-drill factorio-restore-drill-manual
    kubectl -n <namespace> logs -f job/factorio-restore-drill-manual
    ```
- **Restore (real):**
  1. Scale the Deployment to 0.
  2. Run a one-off Pod mounting the PVC and run `restic restore... --target /factorio` (or restore only `/factorio/saves`).
  3. Scale back to 1 and verify the world loads.

## Customisation Knobs

- **Env Vars:** In `base/deployment.yaml` (`UPDATE_MODS_ON_START`, `VERSION`).
- **Resources:** CPU/RAM limits in `base/deployment.yaml`.
- **Backup policy:** `BACKUP_INTERVAL` and `PRUNE_RESTIC_RETENTION` in `base/deployment.yaml`.
- **Service IP:** pinned MetalLB IP via `overlays/proxmox-talos/service.yaml`.

## Oddities / Quirks

- **UDP LoadBalancer:** Requires MetalLB or equivalent support in the environment.
- **Credentials optional:** `USERNAME`/`TOKEN` env vars are optional; the server can run without them, but public listing and mod downloads may require valid Factorio credentials.
- **Pod Security:** The namespace is labeled `pod-security.kubernetes.io/enforce=privileged` to allow Istio injection (the `istio-init` container needs `NET_ADMIN`/`NET_RAW`). If we want this namespace to be `restricted`, migrate to Istio CNI (no init container) or keep the workload out-of-mesh and move backups elsewhere.

## TLS, Access & Credentials

- **Game Auth:** Uses `username`/`token` from `factorio-secret`.
- **Ingress:** None (UDP protocol).
- **Access:** Public Internet access on port 34197 if LoadBalancer is exposed.

## Dev → Prod

- **Dev:** `overlays/mac-orbstack` or `overlays/mac-orbstack-single` (no pinned IP).
- **Prod:** `overlays/proxmox-talos` pins the MetalLB IP for stable reachability.

## Smoke Jobs / Test Coverage

- **Automated:** No automated connectivity test in git (see `docs/component-issues/factorio.md`).
- **Manual:** `nc -u -z -w 1 <LOADBALANCER_IP> 34197` (verifies UDP port is open).
- **In-Pod:** `kubectl -n factorio logs deploy/factorio` should show the server initialized and world loaded.

## HA Posture

- **Single Replica:** Stateful game server. No HA possible without complex shared-state logic (not supported by game engine).
- **Recovery:** Kubernetes will restart the pod. Downtime = startup time (seconds).
- **Node Failure:** `shared-rwo` PVC must detach/attach to new node (minutes).

## Security

- **Secrets:** Credentials live in Vault and are synced into the namespace via ESO.
- **Network:** UDP 34197 exposed to the world (if LoadBalancer IP is public).
- **Container:** Runs as `uid=845` (game user), not root.

## Backup and Restore

- **State:** World save lives in `/factorio` (PVC).
- **Strategy:**
  - *Legacy example app:* Restic sidecar snapshots the newest save zip + config + player state to S3/Garage (`secret/apps/factorio/backup`).
  - *Tenant app (`factorio/factorio`):* Restic sidecar snapshots to the tenant-scoped repo (`secret/tenants/factorio/projects/factorio/sys/backup`).
  - *Operational note:* The first restic init/backup can take a while depending on world size. If backups stall/time out, check Garage S3 tail latency via `CronJob/storage-smoke-s3-latency` (and `docs/component-issues/garage.md`).
  - *Future:* Evaluate volume snapshots / Velero for cluster-wide disaster recovery.
- **Restore:** Restic restore (documented above). Automated `factorio-restore-drill` regularly proves restores are possible without touching the live PVC.
- **Platform DR (direction):** Long-term, the platform DR/backup plane (`backup-system`) should own off-cluster backups + scheduling/enforcement, while this component continues to provide an app-specific restore drill that proves the world is restorable (tracking: `docs/component-issues/backup-system.md`).
