# Minecraft (Monifactory)

Deploys a single persistent Minecraft Java server running the **Monifactory** modpack.

## Architecture

- **Workload:** Single-replica `Deployment` (`itzg/minecraft-server:java17`).
- **Storage:** `PersistentVolumeClaim` (`minecraft-data`) mounted at `/data`.
- **Network:** `Service` type `LoadBalancer` (TCP 25565) for game traffic.
- **Sidecars:**
  - `backup`: `itzg/mc-backup` (restic to S3/Garage).
  - `restic-unlock`: InitContainer to clear stale locks.
  - `access-seed`: One-time seed script (Vault → RCON) for initial whitelist + ops.

## Subfolders

| Path | Purpose |
| ---- | ------- |
| `base/` | Core Deployment, Service, ExternalSecrets, and ConfigMap logic. |
| `overlays/` | Environment-specifics (e.g., pinning LoadBalancer IPs in `proxmox-talos`). |

## Container Images / Artefacts

- **Server:** `itzg/minecraft-server:java17` (Game Server).
- **Backup:** `itzg/mc-backup:latest` (Restic sidecar).

## Dependencies

- **Secrets:** Vault (`secret/apps/minecraft-monifactory`) via ESO.
- **Storage:** `shared-rwo` class must be available.
- **Network:** LoadBalancer support (MetalLB).

## Communications With Other Services

### Kubernetes Service → Service calls
- **RCON:** TCP 25575 (internal-only `minecraft-rcon` Service) used by sidecars to manage the server.

### External dependencies (Vault, Keycloak, PowerDNS)
- **CurseForge:** Outbound HTTPS to download modpack updates on boot.
- **S3 (Garage):** Restic sidecar pushes snapshots to Garage S3 using the Vault-managed restic repo config (by default: bucket `garage-backups` with prefix `minecraft-monifactory/`).

### Mesh-level concerns (DestinationRules, mTLS exceptions)
- **Game Traffic:** TCP 25565 (Ingress). Istio sidecar is injected but game traffic is non-HTTP.

## Initialization / Hydration

- **Modpack:** Downloads automatically via `AUTO_CURSEFORGE` on first boot.
- **Additional Mods:** Downloaded automatically on boot via itzg’s `MODS` env var (direct, pinned URLs in `base/kustomization.yaml`, e.g. `ChippedExtras` 1.4 / CurseForge file `6999371`).
- **Pack Config Sync:** Because `/data` is a persistent PVC, mod configs under `/data/config/**` and `/data/defaultconfigs/**` can “stick” with generated defaults that differ from the modpack’s authored settings. An initContainer (`monifactory-pack-config-sync`) extracts an allowlist of configs (plus `defaultconfigs/**`) from the pinned Monifactory server pack zip (`CF_FILE_ID`) and copies them into `/data`, archiving replaced files under `/data/.deploykube/archive/`. Re-run by bumping `DEPLOYKUBE_PACK_CONFIG_SYNC_REV`.
- **GTCEu Config:** `config/gtceu.yaml` is enforced from the selected packmode (`/data/config-overrides/<mode>/gtceu.yaml`) on every boot by the `monifactory-packmode` initContainer, then DeployKube intentionally overrides `enableFEConverters: false` via `gtceu-disable-fe-to-eu` to disable RF→EU conversion.
- **World Reset (one-time):** An initContainer archives `/data/world` to `/data/world-archive/<resetId>` once per `DEPLOYKUBE_WORLD_RESET_ID`, then the server generates a fresh world on next start. This only runs when explicitly armed via `DEPLOYKUBE_WORLD_RESET_ARMED=true`.
  - Note: the archive stays on the PVC until you delete it. Remote backups exclude `world-archive/**` by default.
- **Secrets:**
  - `curseforgeApiKey`: Seeded via SOPS → Vault → ESO.
  - `rconPassword`: Injected via ESO.

## Argo CD / Sync Order

- **Standard:** Syncs with other apps.
- **Health:** Deployment becomes healthy once the server is accepting TCP connections on port 25565 (startupProbe/readiness), and the Deployment has an available replica.

## Operations (Toils, Runbooks)

- **Whitelist / Ops (recommended operating model):**
  - **Day 0 seed only:** optionally set `secret/apps/minecraft-monifactory/access` in Vault (keys: `whitelist`, `ops`).
  - On first successful boot, the `access-seed` sidecar applies `whitelist add` + `op` via RCON once, then writes a marker to `/data/.deploykube/access-seeded-v1` and stays idle.
  - **After seeding, in-game commands are the source of truth** (`/whitelist add|remove`, `/op`, `/deop`). Vault updates are not applied automatically anymore.
  - To re-run the seed (rare / breakglass): delete `/data/.deploykube/access-seeded-v1` from the PVC, then restart the pod.
- **Manual Backup:** `kubectl -n minecraft-monifactory exec deploy/minecraft -c backup -- restic backup /data`
- **Local unencrypted world export (belt-and-suspenders):**
  ```bash
  backup_dir="${HOME}/tmp/minecraft-world-$(date +%F-%H%M%S)"
  mkdir -p "${backup_dir}"
  kubectl -n minecraft-monifactory exec deploy/minecraft -c minecraft -- tar -C /data -cf - world \
    | tar -C "${backup_dir}" -xf -
  echo "exported world to: ${backup_dir}/world"
  ```
- **Automated restore drill (non-destructive):**
  - CronJob `minecraft-restore-drill` restores `latest` into scratch and asserts expected world files exist.
  - Run on-demand:
    ```bash
    kubectl -n minecraft-monifactory create job --from=cronjob/minecraft-restore-drill minecraft-restore-drill-manual
    kubectl -n minecraft-monifactory logs -f job/minecraft-restore-drill-manual
    ```
- **Restore:**
  1. Scale down.
  2. Restore data to PVC (via `restic restore` or volume snapshot).
  3. Scale up.
- **CurseForge API Key Rotation (manual Job):**
  1. Update `platform/gitops/deployments/<deploymentId>/secrets/minecraft-monifactory-seed.secret.sops.yaml` and commit.
  2. Force-seed Forgejo and sync (so the seed secret is applied).
  3. Run the rotation Job from your local repo checkout:
     ```bash
     kubectl -n vault-system create configmap minecraft-monifactory-rotate-script \
       --from-file=rotate-minecraft-curseforge.sh=platform/gitops/components/secrets/vault/overlays/proxmox-talos/config/scripts/rotate-minecraft-curseforge.sh \
       --dry-run=client -o yaml | kubectl apply -f -
     kubectl -n vault-system apply -f platform/gitops/components/secrets/vault/overlays/proxmox-talos/config/rotate-minecraft-curseforge.yaml
     kubectl -n vault-system logs -f job/minecraft-monifactory-curseforge-rotate
     ```
     - If the Job already ran before, delete `configmap/minecraft-monifactory-curseforge-rotate-complete` and `job/minecraft-monifactory-curseforge-rotate` in `vault-system`, then rerun.
  4. Delete `secret/minecraft-monifactory-secrets` and restart `deploy/minecraft` to pick up the new key.

## Customisation Knobs

- **Memory:** `MEMORY` env var in `base/deployment.yaml`.
- **Server Properties:** `base/kustomization.yaml` (`configMapGenerator`).
- **Modpack Version:** `CF_FILE_ID` in `base/kustomization.yaml` (pinned to Server Pack ID).
- **Additional Mods:** `MODS` in `base/kustomization.yaml` (pinned URLs; includes `More Slabs, Stairs and Wall`).
- **EMI Override (advanced):** `DEPLOYKUBE_EMI_OVERRIDE_URL` + `DEPLOYKUBE_EMI_OVERRIDE_SHA256` in `base/kustomization.yaml` (downloads a custom EMI jar and replaces `mods/emi-*.jar` via the `emi-override` initContainer; note this only updates the dedicated server—players still need the same EMI jar in their client modpack to see UI changes).
- **Pack Config Sync:** `DEPLOYKUBE_PACK_CONFIG_SYNC_REV` in `base/kustomization.yaml` (bump to re-apply the pack-authored config allowlist + `defaultconfigs/**` onto the PVC).
- **Patcher Flags:** feature-flags for initContainers that mutate on-PVC files to work around pack/server mismatches. Defaults are `true`; disable only for controlled experiments with evidence.
  - `ENABLE_DEPLOYKUBE_QUARK_DISABLE_COLOR_RUNES` (work around Quark Color Runes startup deadlock).
  - `ENABLE_DEPLOYKUBE_LASERIO_ENABLE_ENERGY_OVERCLOCKER_TIERS` (ensure LaserIO FE tier list exists to avoid registry/client issues).
  - `ENABLE_DEPLOYKUBE_THERMAL_DISABLE_ORE_WORLDGEN` (disable Thermal ore worldgen to avoid mining “nuked” ores).
  - `ENABLE_DEPLOYKUBE_NUCLEARCRAFT_DISABLE_ORE_WORLDGEN` (disable NuclearCraft ore worldgen to avoid mining “nuked” ores).
- **Gameplay Divergences (KubeJS patches):**
  - `ENABLE_DEPLOYKUBE_MV_MACERATION_TOWER` + `DEPLOYKUBE_MV_MACERATION_TOWER_REV` (MV-era Maceration Tower divergence; currently disabled in prod).
- **View Distance:** `VIEW_DISTANCE` in `base/kustomization.yaml`.
- **World Reset:** `DEPLOYKUBE_WORLD_RESET_ARMED` + `DEPLOYKUBE_WORLD_RESET_ID` in `base/kustomization.yaml` (bump ID to force a new world; set ARMED back to `false` after you see the new world is live).

## Oddities / Quirks

- **Access Seed Sidecar:** One-time seeding in `deployment.yaml` reads `/access` (projected from Vault) and issues RCON commands, then becomes inert.
- **World Reset Guard:** The initContainer will refuse to overwrite an existing archive path; if you bump `DEPLOYKUBE_WORLD_RESET_ID` repeatedly, ensure the PVC has enough free space (or clean up archived worlds intentionally).
- **Startup Time:** Monifactory cold-start is slow (downloading mods + long JVM startup). `deployment.yaml` uses a `startupProbe` to prevent liveness restarts during long startup.

## TLS, Access & Credentials

- **Game Auth:** Online Mode (Mojang auth).
- **Whitelist:** Enforced by the server (`ENABLE_WHITELIST` + `ENFORCE_WHITELIST`); day-0 entries can be seeded from Vault.
- **Secrets:** All credentials in Vault; projected to Env vars.

## Dev → Prod

- **Dev:** `overlays/mac-orbstack` or `overlays/mac-orbstack-single` (no pinned IP).
- **Prod:** `overlays/proxmox-talos` pins the Service IP for stable reachability.

## Smoke Jobs / Test Coverage

- **Automated connectivity smoke:** `CronJob/minecraft-tcp-smoke` (every 15m) verifies TCP `25565` reachability via in-cluster Service DNS (`minecraft.minecraft-monifactory.svc.cluster.local`).
- **Alerting:** `MinecraftMonifactorySmokeJobFailed` / `MinecraftMonifactorySmokeCronJobStale` (runbook: `docs/runbooks/minecraft-monifactory-smoke-alerts.md`).
- **Manual:** `spark healthreport` (via RCON) or connect via Game Client.
- **Backup Verification:** `kubectl -n minecraft-monifactory logs deploy/minecraft -c backup` should show successful snapshots.

## HA Posture

- **Single Replica:** Stateful game. No HA.
- **Recovery:** Pod restart (auto). PVC attaches to new node.

## Security

- **Container:** Runs as `runAsUser: 1000`.
- **RCON:** Limited to localhost (sidecars) and internal ClusterIP.
- **Ingress:** Public TCP 25565.

## Backup and Restore

- **Strategy:** Restic sidecar (every 10m).
- **Destination:** S3 (Garage). By default the restic repo is stored under bucket `garage-backups` with prefix `minecraft-monifactory/` (configured in Vault at `secret/apps/minecraft-monifactory/backup`).
- **Restore:** Manual process (Scale down -> Restore -> Scale up). Automated `minecraft-restore-drill` regularly proves restores are possible without touching the live PVC.
- **Platform DR (direction):** Long-term, the platform DR/backup plane (`backup-system`) should own off-cluster backups + scheduling/enforcement, while this component continues to provide an app-specific restore drill that proves the world is restorable (tracking: `docs/component-issues/backup-system.md`).

### Manual rollback to the last backup before a given time

Use this when you want to roll back the Minecraft *world* to the most recent restic snapshot strictly before some time (e.g. “before 23:27 CET”).

Notes:
- The `restic snapshots` timestamps shown by the `backup` container are **UTC** (unless you explicitly changed the container timezone).
- This procedure restores only `/data/world/**` (not the full `/data`) to avoid clobbering server config / pack files unless you intend that.

#### 1) Pick the target snapshot ID

Example: cutoff **2026-01-23 23:27 CET** (UTC+1) → cutoff **2026-01-23 22:27 UTC**.

List recent snapshots:

```bash
export KUBECONFIG=tmp/kubeconfig-prod
kubectl -n minecraft-monifactory exec deploy/minecraft -c backup -- restic snapshots --latest 25
```

Pick the newest snapshot whose `Time` is **< cutoff**. Save the snapshot ID (e.g. `0c8fc01b`).

#### 2) Pause Argo auto-sync (temporary)

This avoids Argo fighting your manual scale/restore actions while you work.

```bash
export KUBECONFIG=tmp/kubeconfig-prod
kubectl -n argocd patch application platform-apps --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application examples-apps --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application apps-minecraft-monifactory --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

#### 3) Stop the server (scale to 0)

```bash
export KUBECONFIG=tmp/kubeconfig-prod
kubectl -n minecraft-monifactory scale deploy/minecraft --replicas=0
kubectl -n minecraft-monifactory get pods -l app=minecraft-monifactory
```

Wait until there are no `app=minecraft-monifactory` pods.

Troubleshooting: if a pod is stuck `Terminating` for a long time, you can force-delete it:

```bash
kubectl -n minecraft-monifactory delete pod -l app=minecraft-monifactory --grace-period=0 --force
```

#### 4) Restore `/data/world/**` from the snapshot onto the live PVC

This mounts the live `minecraft-data` PVC and:
- archives the current `/data/world` into `/data/world-archive/<rollbackTag>`
- restores `/data/world/**` from the chosen snapshot

```bash
export KUBECONFIG=tmp/kubeconfig-prod

snapshot_id="REPLACE_ME"            # e.g. 0c8fc01b
rollback_tag="rollback-$(date -u +%F-%H%MZ)"
job="minecraft-restore-manual-$(date -u +%s)"

kubectl -n minecraft-monifactory apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: minecraft-monifactory
  labels:
    app.kubernetes.io/name: minecraft-monifactory
    app.kubernetes.io/component: backup
    darksite.cloud/operation: restore
spec:
  ttlSecondsAfterFinished: 86400
  backoffLimit: 0
  activeDeadlineSeconds: 14400
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: restore
          image: itzg/mc-backup:latest
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ "ALL" ]
          env:
            - name: RESTIC_REPOSITORY
              valueFrom: { secretKeyRef: { name: minecraft-monifactory-backup, key: RESTIC_REPOSITORY } }
            - name: RESTIC_PASSWORD
              valueFrom: { secretKeyRef: { name: minecraft-monifactory-backup, key: RESTIC_PASSWORD } }
            - name: AWS_ACCESS_KEY_ID
              valueFrom: { secretKeyRef: { name: minecraft-monifactory-backup, key: S3_ACCESS_KEY } }
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom: { secretKeyRef: { name: minecraft-monifactory-backup, key: S3_SECRET_KEY } }
            - name: AWS_DEFAULT_REGION
              valueFrom: { secretKeyRef: { name: minecraft-monifactory-backup, key: S3_REGION } }
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              (set -o pipefail 2>/dev/null) || true

              echo "[restore] snapshot=${snapshot_id} rollback_tag=${rollback_tag}"

              timeout 120m restic snapshots --latest 1 >/dev/null

              if [ -d /restore/data/world ]; then
                mkdir -p /restore/data/world-archive
                archive_path="/restore/data/world-archive/${rollback_tag}"
                echo "[restore] archiving current /data/world -> ${archive_path}"
                rm -rf "${archive_path}" || true
                mv /restore/data/world "${archive_path}"
              fi

              echo "[restore] restoring /data/world from snapshot -> PVC"
              timeout 120m restic restore "${snapshot_id}" \\
                --target /restore \\
                --include /data/world \\
                --include /data/world/**

              test -f /restore/data/world/level.dat
              echo "[restore] OK: restored world and found level.dat"
          volumeMounts:
            - name: data
              mountPath: /restore/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minecraft-data
EOF

kubectl -n minecraft-monifactory wait --for=condition=complete job/${job} --timeout=120m
kubectl -n minecraft-monifactory logs job/${job} -c restore
```

#### 5) Start the server again

```bash
export KUBECONFIG=tmp/kubeconfig-prod
kubectl -n minecraft-monifactory scale deploy/minecraft --replicas=1
kubectl -n minecraft-monifactory wait --for=condition=available deploy/minecraft --timeout=25m
kubectl -n minecraft-monifactory get pods -l app=minecraft-monifactory -o wide
```

#### 6) Re-enable Argo auto-sync

```bash
export KUBECONFIG=tmp/kubeconfig-prod
kubectl -n argocd patch application platform-apps --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n argocd patch application examples-apps --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n argocd patch application apps-minecraft-monifactory --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

#### 7) Optional: verify the archive exists

```bash
export KUBECONFIG=tmp/kubeconfig-prod
pod="$(kubectl -n minecraft-monifactory get pod -l app=minecraft-monifactory -o jsonpath='{.items[0].metadata.name}')"
kubectl -n minecraft-monifactory exec "${pod}" -c minecraft -- ls -la /data/world-archive | tail -n +1 | head -n 20
```

## Troubleshooting

- `mc-image-helper... The API key should start with '$2a$10$'`:
  - Means `curseforgeApiKey` is not a real CurseForge API key. Update the SOPS seed secret and run the `minecraft-monifactory-curseforge-rotate` Job (then restart the Deployment).
- `access-seed` CrashLoop:
  - Usually means `/bin/sh` shell incompatibility (e.g. `set -o pipefail` on ash). The script should be POSIX compliant.
- `backup` CrashLoop `client.MakeBucket: Forbidden`:
  - Usually means the Vault-managed backup config points at a bucket the Garage S3 key can't access. Check `secret/apps/minecraft-monifactory/backup` (Vault) and ensure the `secret/garage/s3` key has owner permissions on the bucket used by `RESTIC_REPOSITORY` (default: `garage-backups`).
