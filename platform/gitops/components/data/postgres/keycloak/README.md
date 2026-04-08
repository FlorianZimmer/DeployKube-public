# Keycloak Postgres (`data/postgres/keycloak`)

This component now declares Keycloak's database through the platform-owned API `data.darksite.cloud/v1alpha1` instead of shipping raw CNPG manifests directly.

## What this component owns

- `PostgresInstance/keycloak-postgres`
- environment-specific class selection and backup overrides

The concrete backend resources are reconciled by `Application/platform-data-postgres-controller`:

- `Cluster/keycloak-postgres` (`postgresql.cnpg.io/v1`)
- `Service/keycloak-postgres` (`ExternalName` to `keycloak-postgres-rw`)
- `NetworkPolicy/keycloak-postgres-ingress`
- `ServiceAccount/postgres-backup`
- `PersistentVolumeClaim/postgres-backup-v2`
- `Job/postgres-backup-warmup`
- `CronJob/postgres-backup`
- `ConfigMap/backup-encryption`

## Contract

- Namespace: `keycloak`
- Connection secret input/output: `Secret/keycloak-db`
- Backend cluster name: `keycloak-postgres`
- Application host: `keycloak-postgres-rw.keycloak.svc.cluster.local`
- Access mode: same namespace only

Keycloak itself still consumes the same service and secret contract, so the app-facing wiring does not change.

## Overlays

- Base: `PostgresClass/platform-ha`
- `overlays/proxmox-talos`: hourly tier-0 backup schedule plus fixed PV bind (`tier0-postgres-keycloak-proxmox-talos`) and retained legacy backup PVC request size (`10Gi`) so the static claim can be adopted without an invalid resize attempt
- `components/data/postgres/overlays/mac-orbstack-single/keycloak`: `PostgresClass/platform-dev-small`

## Dependencies

- `Application/platform-data-postgres-api`
- `Application/platform-data-postgres-classes`
- `Application/platform-data-postgres-controller`
- `Application/data-postgres-operator`
- `Secret/keycloak-db` from the Keycloak ESO/Vault path
- `StorageClass/shared-rwo`

## Current limitations

- The first controller slice reuses the existing Vault/ESO connection secret flow; it does not mint credentials itself yet.
- Keycloak intentionally keeps the legacy helper names (`postgres-backup`, `postgres-backup-v2`, `backup-encryption`) to preserve the existing backup/PV contract during the cutover.

## Operations

Connect to the database:

```bash
kubectl -n keycloak exec -it keycloak-postgres-1 -- psql -U postgres
```

Trigger a manual backup:

```bash
kubectl -n keycloak create job --from=cronjob/postgres-backup manual-backup-kc-$(date +%s)
```

Run the smoke job:

```bash
kubectl -n keycloak create job --from=cronjob/keycloak-postgres-smoke smoke-manual-$(date +%s)
```

## Validation

- `kustomize build platform/gitops/components/data/postgres/keycloak`
- `kustomize build platform/gitops/components/data/postgres/keycloak/overlays/proxmox-talos`
- `kustomize build platform/gitops/components/data/postgres/overlays/mac-orbstack-single/keycloak`

For the platform API itself, see `docs/design/platform-postgres-api.md` and `docs/apis/data/data.darksite.cloud/README.md`.
