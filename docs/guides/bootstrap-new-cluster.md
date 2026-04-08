# Bootstrap a New DeployKube Cluster (Mac / Proxmox)

This guide is the operator playbook for bootstrapping DeployKube using the repo’s two central contracts:

- Deployment config contract (identity, non-secrets): `platform/gitops/deployments/<deploymentId>/config.yaml`  
  See: `docs/design/deployment-config-contract.md`
- Deployment Secrets Bundle (DSB) (bootstrap-only secrets, SOPS): `platform/gitops/deployments/<deploymentId>/secrets/*.secret.sops.yaml`  
  See: `docs/design/deployment-secrets-bundle.md`

If you are new to this repo’s GitOps workflow, read `docs/design/gitops-operating-model.md` first.

## What “bootstrap” means in this repo

- Stage 0 prepares the cluster (kind/OrbStack or Proxmox/Talos), core CRDs, networking, and storage.
- Stage 1 installs Forgejo + Argo CD, applies the Argo CD `AppProject/platform` boundary, and applies the root GitOps app (`platform-apps`).
- After Stage 1, everything is managed declaratively via Argo CD from `platform/gitops/**` (mirrored into Forgejo as a snapshot).

Operator entrypoints are in `scripts/` (thin wrappers); implementation is in `shared/scripts/`. See `scripts/README.md`.

## Key concepts you must not forget

### Deployment identity is a contract (`DeploymentConfig`)

Every deployment has:

- `platform/gitops/deployments/<deploymentId>/config.yaml`

Validated by:

- `./tests/scripts/validate-deployment-config.sh`

This is the repo’s single source of truth for deployment DNS identity (base domain and platform hostnames).

It also carries deployment-scoped backup/DR configuration (`spec.backup.*`). Full-deployment DR requires configuring a backup target; see `docs/design/disaster-recovery-and-backups.md`.

It also carries deployment-scoped **ops tuning knobs** that we want to single-source (example: Loki retention via `spec.observability.loki.limits.retentionPeriod`). See `docs/toils/observability-loki-retention.md`.

### Bootstrap secrets are deployment-scoped (DSB)

Bootstrap-only SOPS material is not stored in component folders anymore.

- Ciphertext bundle: `platform/gitops/deployments/<deploymentId>/secrets/*.secret.sops.yaml`
- Deployment publishes a ciphertext bundle ConfigMap:
  - `ConfigMap/argocd/deploykube-deployment-secrets`
- Bootstrap Jobs consume that ConfigMap and refuse placeholder secrets (`darksite.cloud/placeholder=true`).

Validated by:

- `./tests/scripts/validate-deployment-secrets-bundle.sh`

### Your SOPS Age key is now deployment-scoped (and may be custody-gated)

Stage 1 loads your local Age identities file into the cluster as:

- `Secret/argocd/argocd-sops-age` (created from `SOPS_AGE_KEY_FILE`)

Default key path (v1):

- `~/.config/deploykube/deployments/<deploymentId>/sops/age.key`

For prod deployments, Stage 1 enforces a custody acknowledgement sentinel:

- Record ack: `./shared/scripts/sops-age-key-custody-ack.sh`  
  Toil: `docs/toils/sops-age-key-custody.md`
- Rotate safely (two-phase): `./scripts/deployments/rotate-sops.sh`  
  Toil: `docs/toils/sops-age-key-rotation.md`
- Restore story (lost key / safe rebootstrap): `docs/runbooks/dsb-restore-story.md`

## Prerequisites (both targets)

- Repo is clean/committed for GitOps changes you expect Argo to see. Forgejo seeding uses `git archive` of `HEAD`.
- Stage 1 runs a GitOps seed preflight guardrail before seeding Forgejo:
  - it refuses to seed from a dirty working tree, and
  - it runs a focused set of repo validators to catch DeploymentConfig-driven render drift early.
- Tools (minimum):
  - `kubectl`, `helm`, `yq`, `sops`, `age` (`age-keygen`)
- Trust the platform root CA locally when you use HTTPS endpoints:
  - `shared/certs/deploykube-root-ca.crt`

## Step 0: Validate the contracts (recommended before every bootstrap)

```bash./tests/scripts/validate-deployment-config.sh./tests/scripts/validate-deployment-secrets-bundle.sh./tests/scripts/validate-ha-three-node-deadlock-contract.sh
```

If these fail, fix the repo before touching the cluster.

Notes:
- The HA validator enforces the `proxmox-talos` three-worker baseline and HA tier labels/floors on rendered platform workloads.
- This is a tiered policy (`darksite.cloud/ha-tier`), not a global “every workload must run 3 replicas” rule.

## Step 1: Prepare (or scaffold) the deployment contracts

### Existing deployments (most common)

- Mac dev: `platform/gitops/deployments/mac-orbstack-single/`
- Proxmox prod: `platform/gitops/deployments/proxmox-talos/`

Review and edit:

- `platform/gitops/deployments/<deploymentId>/config.yaml`
- `platform/gitops/deployments/<deploymentId>/secrets/*.secret.sops.yaml` (ciphertext only)

### New deployment (new cluster identity)

Use the scaffold helper to create a new deployment directory and a new Age key (placeholder secrets are encrypted to that key):

```bash./scripts/deployments/scaffold.sh \
  --deployment-id <deploymentId> \
  --environment dev|prod|staging \
  --base-domain <baseDomain> \
  --handoff-mode l2 \
  --metallb-pool-range 203.0.113.240-203.0.113.250
```

Then:

1. Commit the new deployment directory under `platform/gitops/deployments/<deploymentId>/`.
2. Store the Age key file out-of-band (do not keep it only on your laptop).
3. For prod deployments, follow the private operational custody workflow for deployment keys. Those procedural details are intentionally omitted from this public mirror.

Important: a scaffolded deployment still contains placeholder secrets. You must replace them with real values (and keep them SOPS-encrypted) before bootstrap Jobs will apply them.

## Step 2: Bootstrap on macOS (OrbStack + kind)

### Quick start (recommended)

First-time or “reset everything”:

```bash./scripts/bootstrap-mac-orbstack-single-clean.sh
```

Iterate without wiping Vault:

```bash./scripts/bootstrap-mac-orbstack-single-preserve.sh
```

Low-memory single-worker variant:

```bash./scripts/bootstrap-mac-orbstack-single-clean.sh
# or./scripts/bootstrap-mac-orbstack-single-preserve.sh
```

### Required secret/key inputs (Mac)

Stage 1 needs an Age identities file to load into `argocd/argocd-sops-age`.

Defaults:

- Deployment-scoped (preferred): `~/.config/deploykube/deployments/mac-orbstack-single/sops/age.key`
- Legacy fallback: `~/.config/sops/age/keys.txt`

Override explicitly (useful for debugging):

```bash
export DEPLOYKUBE_DEPLOYMENT_ID=mac-orbstack-single
export SOPS_AGE_KEY_FILE="$HOME/.config/deploykube/deployments/mac-orbstack-single/sops/age.key"
```

Note: `mac-orbstack-single` uses a distinct base domain (`dev-single.internal.example.com`) and a distinct DSB directory under `platform/gitops/deployments/mac-orbstack-single/`.

### Opt-in example apps (Factorio/Minecraft)

These apps are intentionally not part of the default platform core bundle.

To enable them, apply the opt-in app-of-apps Application:

```bash
kubectl --context kind-deploykube-dev apply -f platform/gitops/apps/opt-in/examples-apps/applications/examples-apps-dev.yaml
```

You must also provide real DSB secrets (not placeholders) for:
- `platform/gitops/deployments/mac-orbstack-single/secrets/minecraft-monifactory-seed.secret.sops.yaml`

### Verify success (Mac)

```bash
kubectl --context kind-deploykube-dev -n argocd get application platform-apps \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.spec.project}{"\n"}'
```

You want: `Synced Healthy platform`

Also verify the DSB app:

```bash
kubectl --context kind-deploykube-dev -n argocd get application deployment-secrets-bundle \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```

### Mac DNS note

Do not guess DNS setup; follow: `docs/guides/macos-dns-argocd-access.md`.

## Step 3: Bootstrap on Proxmox (Talos)

### 3.1 Configure Proxmox/Talos Stage 0 inputs

Stage 0 uses host/bootstrap inputs under `bootstrap/proxmox-talos/`:

- `bootstrap/proxmox-talos/config.yaml` (copy from `config.example.yaml`)
- `bootstrap/proxmox-talos/talos/` (Talos machine configs)

See: `bootstrap/proxmox-talos/README.md`.

HA baseline requirement:
- Define at least 3 worker nodes in `bootstrap/proxmox-talos/config.yaml` (`nodes.workers` length).

### 3.2 Provide Proxmox credentials

Recommended: `PROXMOX_VE_API_TOKEN` (bpg/proxmox provider format):

```bash
export PROXMOX_VE_API_TOKEN="root@pam!deploykube=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### 3.3 Ensure the deployment-scoped SOPS Age key exists (and is custody-acked for prod)

```bash
export DEPLOYKUBE_DEPLOYMENT_ID=proxmox-talos
export SOPS_AGE_KEY_FILE="$HOME/.config/deploykube/deployments/proxmox-talos/sops/age.key"
```

For prod, Stage 1 enforces the SOPS Age custody ack sentinel (see `docs/toils/sops-age-key-custody.md`).

### 3.4 Run the bootstrap

```bash./scripts/bootstrap-proxmox-talos.sh
```

Stage 0 now includes a darksite image-mirror preflight before cluster bootstrap completes:
- It discovers `registry.example.internal/*` runtime image refs from repo contracts.
- It verifies those refs are present in the configured local mirror endpoint (`registry.mirrors.registry.example.internal`) for `linux/amd64`.
- It performs a Talos node `image pull` smoke for one discovered darksite image to validate mirror wiring end-to-end.

If this preflight fails, seed/mirror the missing images into your local registry mirror first, then rerun Stage 0.

### Opt-in example apps (Factorio/Minecraft)

These apps are intentionally not part of the default platform core bundle.

To enable them:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl apply -f platform/gitops/apps/opt-in/examples-apps/applications/examples-apps-prod.yaml
```

You must also provide real DSB secrets (not placeholders) for:
- `platform/gitops/deployments/proxmox-talos/secrets/minecraft-monifactory-seed.secret.sops.yaml`

Factorio credentials are managed in Vault (via ESO). After `secrets-vault-config` has run at least once, populate:

```bash
export VAULT_ADDR=https://vault.<env>.internal.example.com
export VAULT_CACERT=shared/certs/deploykube-root-ca.crt
vault kv patch secret/apps/factorio username="YOUR_USERNAME" token="YOUR_TOKEN"
```

### 3.5 Breakglass kubeconfig custody (required for Proxmox/Talos)

Stage 0 writes the offline breakglass kubeconfig to:

- `tmp/kubeconfig-prod`

You must store it out-of-band and follow the private operational acknowledgement process. The exact recovery and custody procedure is intentionally omitted from this public mirror.

If Stage 0 already finished and you just need to rerun Stage 1 after fixing GitOps content:

```bash
BOOTSTRAP_SKIP_STAGE0=true FORGEJO_FORCE_SEED=true./scripts/bootstrap-proxmox-talos.sh
```

## Knobs reference (operator-facing)

### Common knobs (Stage 1 / GitOps / DSB)

- `DEPLOYKUBE_DEPLOYMENT_ID`: selects `platform/gitops/deployments/<id>/` and the default Age key path.
- `SOPS_AGE_KEY_FILE`: explicit Age identities file to load into `argocd/argocd-sops-age`.
- `FORGEJO_FORCE_SEED=true`: force re-seed Forgejo GitOps snapshot (overrides the seed sentinel guard).

### Mac (OrbStack + kind) knobs

Entry points:

- `./scripts/bootstrap-mac-orbstack-single-clean.sh`
- `./scripts/bootstrap-mac-orbstack-single-preserve.sh`

Orchestrator (`shared/scripts/bootstrap-mac-orbstack-orchestrator.sh`):

- `BOOTSTRAP_SKIP_VAULT_INIT=true|false`: skip running `init-vault-secrets.sh` (preserve mode uses `true`).
- `BOOTSTRAP_WIPE_VAULT_DATA=true|false`: wipe Vault PVC state before reinit (clean mode uses `true`).
- `BOOTSTRAP_REINIT_VAULT=true|false`: force `vault operator init` for transit/core (clean mode uses `true`).
- `BOOTSTRAP_FORCE_VAULT=true|false`: force re-seeding secrets even if sentinels exist (clean mode uses `true`).

Notes on “preserve”:
- `*-preserve` bootstraps are primarily about **Vault** (skip init/wipe/reseed). They do not guarantee workload PVC data is preserved.
- In the single-node local-path profile (`apps/environments/mac-orbstack-single`), PVCs are node-local `hostPath` inside the kind node; deleting the kind cluster wipes that data regardless.
- `BOOTSTRAP_WAIT_ROOT_APP=true|false`: wait for `platform-apps` to exist after Stage 1.
- `CLUSTER_NAME` (default `deploykube-dev`): kind cluster name.
- `KUBECTL_CONTEXT` (default `kind-${CLUSTER_NAME}`): kubectl context used by bootstrap.
- `FORGEJO_SKIP_REMOTE_SWITCH=true|false`: skip switching the GitOps repo to HTTPS after bootstrap.

Stage 0 (`shared/scripts/bootstrap-mac-orbstack-stage0.sh`):

- `KIND_CONFIG`: kind config file (defaults to the single-worker config).
- `LOCAL_REGISTRY_CACHE_ENABLE=1|0`: enable local pull-through caches for common registries.
- `LOCAL_REGISTRY_WARM_IMAGES=1|0`: best-effort cache warming (requires `rg`, `python3`, `skopeo`).
- `NFS_USE_DOCKER_VOLUME=1|0`: use a Docker volume vs a host path for the OrbStack NFS export.
- `NFS_EXPORT_VOLUME`, `NFS_EXPORT_PATH`: choose volume name or host path for NFS data.
- `NFS_HOST_IP`, `NFS_REMOTE_PATH`: NFS service IP/path consumed by the in-cluster provisioner.
- `GATEWAY_API_VERSION` / `GATEWAY_API_URL`: Gateway API CRDs version/source.
- `SHARED_STORAGE_VERIFY=1|0`: run the `shared-rwo` read/write verification jobs (Stage 0).
  - GitOps also gates default PVC provisioning via an Argo PostSync hook: `Job/shared-rwo-postsync-smoke` (namespace: `storage-system`) owned by the `storage-shared-rwo` app.
- `BOOTSTRAP_TOOLS_IMAGE`: image ref for the shared bootstrap tools image.

Stage 1 (`shared/scripts/bootstrap-mac-orbstack-stage1.sh`):

- `ARGO_APP_PATH` (default `apps/environments/mac-orbstack-single`): root GitOps bundle path.
- `FORGEJO_FORCE_SEED=true|false`: force reseeding even if sentinel exists.
- `FORGEJO_SEED_SENTINEL`: sentinel path to gate reseeding.
- `WAIT_FOR_PLATFORM_APPS=true|false`: Stage 1 internal wait (orchestrator sets this to `false` and waits itself).
- `HELM_NO_USER_PLUGINS=true|false`: isolate Helm from user plugins (recommended `true`).
- `HELM_SERVER_SIDE`, `HELM_FORCE_CONFLICTS`: Helm upgrade behavior knobs (best left default).

### Proxmox (Talos) knobs

Entry point:

- `./scripts/bootstrap-proxmox-talos.sh`

Orchestrator (`shared/scripts/bootstrap-proxmox-talos-orchestrator.sh`):

- `CONFIG_FILE`: path to `bootstrap/proxmox-talos/config.yaml`.
- `KUBECONFIG`: kubeconfig path (default `tmp/kubeconfig-prod`).
- `BOOTSTRAP_SKIP_STAGE0=true|false`: reuse an existing cluster and run Stage 1 only.
- `BOOTSTRAP_SKIP_VAULT_INIT=true|false`
- `BOOTSTRAP_WIPE_VAULT_DATA=true|false`
- `BOOTSTRAP_REINIT_VAULT=true|false`
- `BOOTSTRAP_FORCE_VAULT=true|false`
- Breakglass custody gating:
  - `BREAKGLASS_CUSTODY_ACK_SKIP=true|false`
  - `BREAKGLASS_DEPLOYMENT_ID` (default `proxmox-talos`)
  - `BREAKGLASS_CUSTODY_SENTINEL` (default `tmp/bootstrap/breakglass-kubeconfig-acked-<id>`)

Stage 0 (`shared/scripts/bootstrap-proxmox-talos-stage0.sh`):

- OpenTofu:
  - `TOFU_PARALLELISM` (default `1`)
  - `TOFU_LOCK_TIMEOUT` (default `10m`)
  - `PROXMOX_TALOS_REUSE_EXISTING_VMS=true|false`
  - `PROXMOX_TALOS_FORCE_TOFU=true|false`
- Timeouts (seconds):
  - `TALOS_DHCP_BOOT_WAIT_SECONDS`
  - `TALOS_TALOSAPI_WAIT_TIMEOUT_SECONDS`
  - `TALOS_REBOOT_WAIT_TIMEOUT_SECONDS`
  - `TALOS_BOOTSTRAP_TIMEOUT_SECONDS`
  - `TALOS_IMAGE_PULL_WAIT_TIMEOUT_SECONDS`
  - `TALOS_IMAGE_PULL_CMD_TIMEOUT_SECONDS`
  - `KUBECONFIG_WAIT_TIMEOUT_SECONDS`
  - `KUBERNETES_API_WAIT_TIMEOUT_SECONDS`
- Networking/storage/PSA:
  - `FORCE_CILIUM_UPGRADE=true|false`
  - `METALLB_CONFIGURE_POD_SECURITY=true|false`, `METALLB_POD_SECURITY_LEVEL`
  - `NFS_CONFIGURE_POD_SECURITY=true|false`, `NFS_POD_SECURITY_LEVEL`
  - `NFS_RWO_SUBDIR` (default `rwo`)

Stage 1 (`shared/scripts/bootstrap-proxmox-talos-stage1.sh`):

- GitOps bundle:
  - `GITOPS_OVERLAY` (default `proxmox-talos`)
  - `AUTO_RESEED_ON_COMPARISON_ERROR=true|false`
- Helm plugin isolation:
  - `HELM_NO_USER_PLUGINS=true|false`
