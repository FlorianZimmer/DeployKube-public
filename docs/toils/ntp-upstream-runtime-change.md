# Toil: Change upstream NTP sources on a running proxmox cluster

Use this when `DeploymentConfig.spec.time.ntp.upstreamServers` must change after the cluster is already running.

Scope:
- Updates Talos node upstream NTP servers.
- Keeps platform internal NTP services (`platform-ntp`, `platform-ntp-headless`) in place.
- NTP only (PTP is deferred).

## Preconditions

- You have Proxmox/Talos operator access and required CLI tools (`kubectl`, `talosctl`, `yq`, `tofu`).
- Proxmox credentials are available (`PROXMOX_VE_API_TOKEN` or username/password env vars).
- You are on the repo root and targeting proxmox kubeconfig:

```bash
export KUBECONFIG=tmp/kubeconfig-prod
```

## 1) Update DeploymentConfig

Edit:
- `platform/gitops/deployments/proxmox-talos/config.yaml`

Set:
- `spec.time.ntp.upstreamServers` (ordered list, at least one server).

Example:

```yaml
spec:
  time:
    ntp:
      upstreamServers:
        - 198.51.100.20
        - 198.51.100.21
```

## 2) Validate, commit, seed Forgejo

```bash
tests/scripts/validate-deployment-config.sh

git add platform/gitops/deployments/proxmox-talos/config.yaml
DK_ALLOW_MAIN_COMMIT=1 git commit -m "chore(time): update proxmox upstream ntp servers"

FORGEJO_FORCE_SEED=true./shared/scripts/forgejo-seed-repo.sh
kubectl -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite
```

Wait for root app:

```bash
kubectl -n argocd get application platform-apps -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}{"\n"}'
```

## 3) Verify DeploymentConfig snapshot updated in-cluster

```bash
kubectl -n argocd get configmap deploykube-deployment-config -o jsonpath='{.data.deployment-config\.yaml}' \
  | yq -r '.spec.time.ntp.upstreamServers[]?'
```

The output must match the new upstream list.

## 4) Reconcile Talos node machine configs (runtime)

Run Stage 0 in normal reuse mode:

```bash
CONFIG_FILE=bootstrap/proxmox-talos/config.yaml \
PROXMOX_TALOS_REUSE_EXISTING_VMS=true \
PROXMOX_TALOS_FORCE_TOFU=false \./shared/scripts/bootstrap-proxmox-talos-stage0.sh
```

Notes:
- This path is intended to avoid VM reprovision when state is already present.
- Stage 0 now checks for NTP drift between DeploymentConfig and existing Talos configs; if drift is detected it will run the reconcile path instead of reusing stale configs.

## 5) Verify node time sync against new upstreams

```bash
export TALOSCONFIG=bootstrap/proxmox-talos/talos/talosconfig

for n in $(kubectl get nodes -o jsonpath='{range.items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
  echo "== $n =="
  talosctl -n "$n" time
done
```

Each node should report one of the expected NTP upstream servers.

## 6) Quick platform NTP surface check

```bash
kubectl -n time-system get svc platform-ntp platform-ntp-headless -o wide
```

Expected:
- `platform-ntp` is `LoadBalancer` on UDP/123.
- `platform-ntp-headless` exists for in-cluster workload path on UDP/123.

## Rollback

1. Revert `spec.time.ntp.upstreamServers` in `platform/gitops/deployments/proxmox-talos/config.yaml`.
2. Commit + reseed Forgejo + refresh `platform-apps`.
3. Re-run Stage 0 command from step 4.
4. Re-run time verification from step 5.
