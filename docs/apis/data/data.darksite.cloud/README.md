# `data.darksite.cloud` API group

Product-owned managed data-service APIs.

## Versions

- `v1alpha1`

## Kinds

### `PostgresClass`

Cluster-scoped platform-owned service plan.

Current responsibilities:

- Postgres engine family/version pin
- instance count and resource envelope
- storage profile
- backup schedule/retention baseline
- disposable/no-backup policy for platform-only PoCs and labs
- monitoring baseline
- access mode policy

Examples:

- `platform-ha`
- `platform-dev-small`
- `platform-poc-disposable`

### `PostgresInstance`

Namespaced managed Postgres request object.

Current required fields:

- `spec.classRef.name`
- `spec.databaseName`
- `spec.ownerRole`
- `spec.connectionSecretName`

Current optional fields:

- `spec.superuserSecretName`
- `spec.serviceAliases[]`
- `spec.resourceNames.*`
- `spec.backup.schedule`
- `spec.backup.sourceName`
- `spec.backup.connection.*`
- `spec.backup.volume.*`
- `spec.network.accessMode`

Current status outputs:

- `status.phase`
- `status.conditions`
- `status.endpoint`
- `status.secretRef`
- `status.className`
- `status.databaseName`
- `status.backendRef`
- `status.observedGeneration`

## Installed from

- CRDs: `platform/gitops/components/platform/apis/data/data.darksite.cloud/crd`
- Classes: `platform/gitops/components/platform/apis/data/data.darksite.cloud/classes`
- Controller: `platform/gitops/components/platform/apis/data/data.darksite.cloud/controller`

## Current implementation notes

- Backend: CloudNativePG
- Internal platform consumers already migrated: Keycloak, Forgejo, PowerDNS, Harbor
- Platform-only disposable consumer already migrated: IDLab via `PostgresClass/platform-poc-disposable`
- Helper resource names are unique by default and can be explicitly overridden for legacy cutovers
- Service alias publication, backup TLS wiring, optional WAL volumes, and class-driven backup-disable/monitoring posture are implemented
- Current credential flow: existing namespace-local secret is reused; controller-side credential minting is not implemented yet

See `docs/design/platform-postgres-api.md` for the long-term direction.
