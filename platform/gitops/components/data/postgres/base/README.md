# Postgres Cluster Library (`base`)

> [!NOTE]
> This is a **Shared Library**. It does not deploy a running application on its own.
> It provides the Kustomize base for deploying High-Availability PostgreSQL clusters using CloudNativePG.

## Interface

When importing this base, the consumer MUST provide:

1. **Patches**: Override `metadata.name` and referencing Secrets.
2. **Secrets**: Provide `username/password` secrets (usually mapped from Vault via ExternalSecrets).
3. **Storage**: Ensure the `shared-rwo` StorageClass is available.

## Included Resources

| Resource | Type | Purpose |
|----------|------|---------|
| `cluster.yaml` | `Cluster` | 3-replica Postgres HA cluster with 20Gi/10Gi storage. |
| `backup-pvc.yaml` | `PersistentVolumeClaim` | `ReadWriteOnce` PVC for dumping SQL backups (interim). |
| `backup-warmup-job.yaml` | `Job` | Mounts the backup PVC once during bootstrap to trigger PV binding for `WaitForFirstConsumer` StorageClasses. |
| `backup-cronjob.yaml` | `CronJob` | Nightly `pg_dump` job (database-only) pointing to the PVC. |

## Usage Pattern

In your component's `kustomization.yaml`:

```yaml
resources:
  -../../../data/postgres/base
  - externalsecrets.yaml

patches:
  - target:
      kind: Cluster
      name: base-cluster
    patch: |-
      - op: replace
        path: /metadata/name
        value: my-postgres
      - op: replace
        path: /spec/bootstrap/initdb/owner
        value: myuser
```

## Backup Mechanism (Interim)

`backup-pvc.yaml` is annotated with an early Argo sync-wave and is warmed up by `Job/postgres-backup-warmup` so clusters using `WaitForFirstConsumer` (e.g. `mac-orbstack-single`) bind the PV during bootstrap instead of leaving the PVC Pending until the first scheduled CronJob run.

The `backup-cronjob.yaml` defines a nightly job that:
- Connects to the cluster RW service (`*-rw`) using the **superuser** credentials.
- Runs `pg_dump` for the application database (`PGDATABASE`) with `--clean --if-exists` (database-only; does not dump roles).
- Compresses and encrypts the dump at rest using `age`.
- Stores the output on the mounted backup PVC and advances an atomic `LATEST.json` marker.

> [!IMPORTANT]
> The backup job relies on the **Superuser** credentials. Ensure your Vault secret structure populates the `*-superuser` Kubernetes Secret.

Artifacts:
- Dump: `YYYYMMDDTHHMMSSZ-dump.sql.gz.age`
- Marker: `LATEST.json`

Restore procedure:
- `docs/runbooks/postgres-restore-from-tier0-backup.md`

## Istio Integration

CloudNativePG clusters and their consumers often span the mesh boundary.

### CNPG pods (data plane) vs CNPG operator (control plane)

- The **CNPG operator** is not in the mesh by default.
- If **CNPG instance pods** are mesh-injected while the operator is not, STRICT mTLS can break operator ↔ instance connectivity (status extraction, failover logic, backups).
- Therefore, overlays should typically keep CNPG instance pods **out of mesh** via `cnpg.io/podPatch` (example shape):

```yaml
- op: add
  path: /spec/podPatch
  value:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
```

### Meshed clients talking to out-of-mesh Postgres

If Postgres is out-of-mesh but callers are in-mesh, you must add a client-side exception:

- Create a `DestinationRule` for `postgres-rw.<namespace>.svc.cluster.local` with `tls.mode: DISABLE`.
- Treat this as an explicit mesh-security exception and document it in the relevant component README.

### Backup CronJobs (pg_dump)

The base `backup-cronjob.yaml` is written to run safely in mesh-injected namespaces:
- **Native Sidecar**: `sidecar.istio.io/nativeSidecar: 'true'`.
- **Exit Handler**: Calls `istio-native-exit.sh` (mounted from `platform/gitops/components/shared/bootstrap-scripts/istio-native-exit`) so the Job reaches `Complete`.
- **Hold Config**: `proxy.istio.io/config: {"holdApplicationUntilProxyStarts": true}` to prevent startup race conditions.

If the target Postgres endpoint is out-of-mesh and STRICT mTLS is enforced, you may also need:
- `traffic.sidecar.istio.io/excludeOutboundPorts: "5432"` (keep injected, but bypass Envoy for the Postgres port).
