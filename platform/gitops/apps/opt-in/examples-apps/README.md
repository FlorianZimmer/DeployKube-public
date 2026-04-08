# Opt-in bundle: example apps (Minecraft + Factorio)

This folder ships **deployable, opt-in** Argo CD Applications for the “example apps” that should not be part of the default platform core bundle:

- `apps-factorio`
- `apps-minecraft-monifactory`

Why this exists:
- Platform core should be able to run without demo workloads by default (see `docs/design/cloud-productization-roadmap.md`).
- The app manifests still exist under `platform/gitops/components/apps/**` and remain deployable.

## How to enable (GitOps)

Pick the correct entrypoint Application and add it to your environment bundle:

- Dev (Mac/kind): add `apps/opt-in/examples-apps/applications/examples-apps-dev.yaml`
- Prod (Proxmox/Talos): add `apps/opt-in/examples-apps/applications/examples-apps-prod.yaml`

Then commit, reseed Forgejo, and refresh Argo.

## How to enable (one-off, manual apply)

Dev:

```bash
kubectl --context kind-deploykube-dev apply -f platform/gitops/apps/opt-in/examples-apps/applications/examples-apps-dev.yaml
```

Prod:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl apply -f platform/gitops/apps/opt-in/examples-apps/applications/examples-apps-prod.yaml
```

## Secret prerequisites (DSB)

These apps have secret prerequisites:

- **Minecraft (Monifactory):** requires the optional DSB seed secret:
  - `platform/gitops/deployments/<deploymentId>/secrets/minecraft-monifactory-seed.secret.sops.yaml`
  - The bootstrap Jobs **refuse placeholder secrets** (`darksite.cloud/placeholder=true`).
- **Factorio:** reads credentials from Vault via ESO:
  - Vault path: `secret/apps/factorio` (`username`, `token`)
  - Vault backup config (tenant backup plane): `secret/tenants/factorio/projects/factorio/sys/backup` (restic/S3 settings), provisioned by the platform tenant backup provisioners

See:
- `docs/design/deployment-secrets-bundle.md`
- `docs/guides/bootstrap-new-cluster.md`
