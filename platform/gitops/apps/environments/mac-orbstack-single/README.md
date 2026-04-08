# Mac OrbStack Single-Node Environment (dev)

This environment is a **single-machine / single-node** dev target for Mac + OrbStack. It intentionally trades HA semantics for a much lower memory footprint, so you can keep developing on a laptop.

## Key Differences vs legacy `apps/environments/mac-orbstack` (removed)
- **Non-HA posture**: scales down HA-oriented control-plane components (e.g. Keycloak, Vault) to single-instance where applicable.
- **No heavy optional stacks**: disables the observability stack (Grafana/Mimir/Loki/Tempo/Alloy) and the Harbor registry stack. Demo apps (Minecraft/Factorio) are opt-in via `apps/opt-in/examples-apps/`.
- **Reduced background churn**: Istio control-plane is single-replica and mesh access logs are disabled to reduce steady-state CPU + disk writes.
- **Still GitOps-first**: same Argo app-of-apps model; uses `*.dev-single.internal.example.com` so it can run alongside the standard `*.dev.internal.example.com` dev bundle (via `overlays/mac-orbstack-single`).
- **Single-worker friendly**: uses `kms-shim` for auto-unseal (no dedicated transit node, no `vault-transit=dedicated` taints).
- **Local-first storage profile**: `shared-rwo` is backed by node-local `local-path-provisioner` (`/var/mnt/deploykube/local-path`) and `storage-nfs-provisioner` is not installed (see `docs/design/storage-single-node.md`).
  - **Preserve semantics**: because PVCs are `hostPath` inside the kind node container, deleting the kind cluster wipes PVC data regardless of `*-preserve` scripts.

## How to use

Stage 1 already supports selecting an environment bundle via `ARGO_APP_PATH`:

```bash
ARGO_APP_PATH=apps/environments/mac-orbstack-single \./shared/scripts/bootstrap-mac-orbstack-stage1.sh
```

## Environment Model

```
apps/environments/mac-orbstack-single/
├── kustomization.yaml          # resources:../../base +../../tenants/overlays/dev + patches
└── patches/
    ├── delete-*.yaml           # remove heavy optional apps/stacks
    └── patch-*.yaml            # select platform-apps-controller overlay + low-mem deltas
```
