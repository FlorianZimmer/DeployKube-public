# Platform Postgres Controller

This component runs the platform-owned Postgres control plane for `data.darksite.cloud/v1alpha1`.

## Scope

- Watches `PostgresClass` and `PostgresInstance`
- Reconciles CNPG backend objects for approved instances
- Publishes status back onto `PostgresInstance`

Installed with:

- CRDs: `components/platform/apis/data/data.darksite.cloud/crd`
- class catalog: `components/platform/apis/data/data.darksite.cloud/classes`
- controller runtime: this component

## Current behavior

- backend: CloudNativePG only
- access mode: `SameNamespace` only
- credentials: reuses the existing namespace-local connection Secret
- helper resource names: unique by default, with explicit per-instance overrides for legacy cutovers
- service aliases: supported through controller-managed `ExternalName` Services
- backup TLS: supported through `spec.backup.connection.*`
- disposable classes: supported through class-driven backup disablement, backup-skip labeling, optional WAL omission, and PodMonitor suppression
- retained static backup PVCs: preserve the historical PVC request size with `spec.backup.volume.size` when adopting fixed `volumeName` bindings whose live PV capacity is larger than the immutable PVC request
- legacy warmup Jobs: unowned retained backup warmup Jobs are deleted and recreated during adoption so raw-CNPG cutovers do not wedge on immutable Job pod templates
- migration safety: controller strips Argo tracking from adopted backend resources so consumer apps can hand ownership over cleanly

Current internal consumers:

- `PostgresInstance/keycloak-postgres` in `keycloak`
- `PostgresInstance/postgres` in `forgejo`
- `PostgresInstance/postgres` in `dns-system`
- `PostgresInstance/postgres` in `harbor`
- `PostgresInstance/idlab-postgres` in `idlab` (disposable PoC class)

## Controller profile

- image: `registry.example.internal/deploykube/tenant-provisioner:0.2.24`
- args:
  - `--controller-profile=postgres`
  - `--leader-election-id=platform-postgres-controller.darksite.cloud`
  - `--postgres-observe-only=false`

## Managed resources

For each `PostgresInstance`, the controller currently manages:

- `Cluster/<instanceName>`
- `Service/<instanceName>` plus any declared alias Services
- `NetworkPolicy/<default or overridden name>`
- `ServiceAccount/<default or overridden name>`
- `PersistentVolumeClaim/<default or overridden name>`
- `Job/<default or overridden name>`
- `CronJob/<default or overridden name>`
- `ConfigMap/<default or overridden name>`

For classes with `spec.backup.mode=Disabled`, the controller omits backup helper resources and removes any previously managed backup helpers during reconciliation.

## HA posture

- Namespace: `data-system`
- Deployment: `replicas: 2` with leader election enabled
- Scheduling: preferred hostname anti-affinity plus hostname topology spread
- PodDisruptionBudget: `minAvailable: 1`
- HA tier: `darksite.cloud/ha-tier=tier-1`

## Validation

- `kustomize build platform/gitops/components/platform/apis/data/data.darksite.cloud/controller`
- `go test./...` under `tools/tenant-provisioner`
