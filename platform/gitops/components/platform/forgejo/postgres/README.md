# platform/forgejo/postgres

Forgejo now declares its database through the platform-owned API `data.darksite.cloud/v1alpha1`.

## What this component owns

- `PostgresInstance/postgres`
- `ExternalSecret/forgejo-postgres-app`
- `ExternalSecret/forgejo-postgres-superuser`
- Proxmox-specific backup overrides

The concrete backend resources are reconciled by `Application/platform-data-postgres-controller`, but the live Forgejo contract is unchanged:

- CNPG cluster name: `postgres`
- application host: `postgres-rw.forgejo.svc.cluster.local`
- app secret: `Secret/forgejo-postgres-app`
- superuser secret: `Secret/forgejo-postgres-superuser`
- backup helpers keep the legacy names `postgres-backup`, `postgres-backup-v2`, and `backup-encryption`

## Notes

- Base class: `PostgresClass/platform-ha`
- Proxmox overlay keeps the hourly tier-0 backup cadence and static PV binding `tier0-postgres-forgejo-proxmox-talos`
- Backups still use `sslmode=require` against `postgres-rw`

## Validation

- `kustomize build platform/gitops/components/platform/forgejo/postgres`
- `kustomize build platform/gitops/components/platform/forgejo/postgres/overlays/proxmox-talos`
