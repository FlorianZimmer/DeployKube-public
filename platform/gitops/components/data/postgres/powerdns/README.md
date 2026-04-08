# Postgres PowerDNS Cluster (`postgres/powerdns`)

This component now declares the PowerDNS database through the platform-owned API `data.darksite.cloud/v1alpha1`.

## What this component owns

- `PostgresInstance/postgres`
- `ExternalSecret/powerdns-postgres-app`
- `ExternalSecret/powerdns-postgres-superuser`
- Proxmox-specific backup overrides

The concrete backend resources are reconciled by `Application/platform-data-postgres-controller`, while the PowerDNS-facing contract stays stable:

- CNPG cluster name: `postgres`
- alias Service: `powerdns-postgresql.dns-system.svc.cluster.local`
- backup host: `postgres-rw.dns-system.svc.cluster.local`
- backup TLS: `sslmode=verify-full` with `Secret/postgres-ca`
- legacy helper names stay in place: `postgres-backup`, `postgres-backup-v2`, `backup-encryption`, `powerdns-postgres-ingress`

## Notes

- Base class: `PostgresClass/platform-ha`
- PowerDNS still uses the `powerdns-postgresql` alias and CNPG certificate SAN to keep `verify-full` working
- Proxmox overlay keeps the hourly tier-0 backup cadence, static PV binding `tier0-postgres-powerdns-proxmox-talos`, and the retained legacy backup PVC request size (`5Gi`) so the static claim can be adopted without an invalid resize attempt

## Operations

Connect to the database:

```bash
kubectl -n dns-system exec -it postgres-1 -- psql
```

Trigger a manual backup:

```bash
kubectl -n dns-system create job --from=cronjob/postgres-backup manual-backup-powerdns-$(date +%s)
```

Run the smoke job:

```bash
kubectl -n dns-system create job --from=cronjob/powerdns-postgres-smoke smoke-manual-$(date +%s)
```

## Validation

- `kustomize build platform/gitops/components/data/postgres/powerdns`
- `kustomize build platform/gitops/components/data/postgres/powerdns/overlays/proxmox-talos`
