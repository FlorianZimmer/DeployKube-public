# NFS Subdir External Provisioner (storage-nfs-provisioner)

DeployKube uses the upstream **nfs-subdir-external-provisioner** to provide dynamic provisioning for the `shared-rwo` storage contract (PVCs backed by an NFS export).

This component intentionally vendors the Helm chart in-repo so **Argo CD does not need to fetch public Helm repos at runtime**, which is a prerequisite for fully offline installs.

For open/resolved items, see `docs/component-issues/storage-nfs-provisioner.md`.

## GitOps layout

- Vendored chart:
  - `platform/gitops/components/storage/nfs-provisioner/helm/charts/nfs-subdir-external-provisioner-4.0.18/nfs-subdir-external-provisioner`
- Argo CD Application:
  - `platform/gitops/apps/base/storage-nfs-provisioner.yaml`
  - Environment-specific Helm values are patched via:
    - `platform/gitops/apps/environments/<deploymentId>/patches/patch-app-storage-nfs-provisioner.yaml`

## Smoke Jobs / Test Coverage

- PVC provisioning and read/write coverage is provided by `shared-rwo` validation jobs:
  - `platform/gitops/components/storage/shared-rwo-storageclass/tests/`

## Notes

- This component is **not** the `shared-rwo` StorageClass itself; that lives under `components/storage/shared-rwo-storageclass/`.
- The NFS server/path are deployment-specific; do not hardcode them outside overlays/patches.
