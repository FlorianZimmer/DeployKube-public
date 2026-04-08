# Introduction

This component provides the **single-node local-first** `shared-rwo` StorageClass by installing Rancher’s `local-path-provisioner`.

Provisioner name: `darksite.cloud/local-path`

It exists to support the single-node storage profile described in `docs/design/storage-single-node.md` (node-local PVCs as the performance default).

---

## Architecture

- `Deployment/local-path-provisioner` runs in `storage-system` and dynamically provisions `hostPath`-backed PVs on the node.
- `StorageClass/shared-rwo` points to provisioner `darksite.cloud/local-path` and is marked as the default StorageClass.
- Provisioned volumes are created under `/var/mnt/deploykube/local-path` on the target node, with per-PVC directories named `rwo/<namespace>-<pvc>`.

---

## Subfolders

This component is a single Kustomize package (no overlays yet).

---

## Container Images / Artefacts

| Artefact | Version | Registry |
|----------|---------|----------|
| local-path-provisioner | `v0.0.30` | `rancher/local-path-provisioner:v0.0.30` |
| helper image | `v20241212-8ac705d0` | `docker.io/kindest/local-path-helper:v20241212-8ac705d0` |

---

## Dependencies

- Linux nodes (hostPath provisioning).
- Node path `/var/mnt/deploykube/local-path` must be writable. For Talos/prod this should be a dedicated persistent mount.

---

## Communications With Other Services

### Kubernetes Service → Service calls

None.

### External dependencies (Vault, Keycloak, PowerDNS)

None.

### Mesh-level concerns (DestinationRules, mTLS exceptions)

Namespace `storage-system` disables Istio injection; no mesh concerns.

---

## Initialization / Hydration

- On PVC provisioning, the helper pod creates the target directory on the node (mode `0777`).

---

## Argo CD / Sync Order

- Intended to sync **before** stateful components that create PVCs on `shared-rwo` (Vault, Postgres, Garage, etc.).

---

## Operations (Toils, Runbooks)

- Verify StorageClasses: `kubectl get storageclass`
- Verify a PVC provisions on `shared-rwo` and binds to a node-affined PV.

---

## Customisation Knobs

- Provisioner path: `ConfigMap/local-path-config` (`config.json`).
- Provisioner name: `Deployment/local-path-provisioner` `--provisioner-name` (must match `StorageClass/shared-rwo.provisioner`).

## Changing the provisioner name (warning)

`StorageClass.provisioner` is immutable. Changing it requires either:
- a dev-only wipe/rebootstrap, or
- a careful migration plan (new StorageClass + data copy per PVC).

---

## Oddities / Quirks

- Local-path volumes are node-affined; rescheduling a pod to a different node will not be able to mount the volume.

---

## TLS, Access & Credentials

None.

---

## Dev → Prod

- Dev (kind) can run with the path inside the node container filesystem.
- Prod must ensure `/var/mnt/deploykube/local-path` is a persistent mount backed by a dedicated disk/partition.

---

## Smoke Jobs / Test Coverage

- Repo/CI: this component is rendered/validated as part of `./tests/scripts/ci.sh all`.
- Runtime: no dedicated local-path provisioning smoke Job is shipped yet (track in `docs/component-issues/local-path-provisioner.md`).

---

## HA Posture

- This is a **single-node / single failure domain** storage backend.
- Volumes are **node-affined**; rescheduling a workload to a different node cannot mount the PV.
- There is no built-in disk replication or failover. “Node/disk loss” is treated as a DR event (restore from backups).

---

## Security

- Data is stored on the node filesystem (`hostPath` via `local-path-provisioner`).
- There is no encryption-at-rest by default; treat node/root access as equivalent to volume access.
- Tenant safety: this backend is intended for platform-owned single-node profiles; do not expose it as a tenant-selectable StorageClass.

---

## Backup and Restore

- Backups are out-of-band: stateful workloads using `shared-rwo` must be covered by the backup plane (app-native snapshots and/or file-level backups to the external backup target).
- Restore is “rebuild + restore”: if the node/disk is replaced, recreate the workload and restore its data from the backup target.
