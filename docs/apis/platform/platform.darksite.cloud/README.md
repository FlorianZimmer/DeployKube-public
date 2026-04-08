# `platform.darksite.cloud` API group

Product-owned platform configuration APIs.

Controllers:
- `deployment-config-controller` (implemented in `tools/tenant-provisioner`) consumes the singleton `DeploymentConfig` and publishes per-namespace snapshot ConfigMaps.
- `platform-apps-controller` (implemented in `tools/tenant-provisioner`) consumes `PlatformApps` and manages Argo CD `Application` fan-out.

Installed from:
- CRD: `platform/gitops/components/platform/deployment-config-crd`
- Controller: `platform/gitops/components/platform/deployment-config-controller`
- CRD + controller: `platform/gitops/components/platform/platform-apps-controller`

Versions:
- `v1alpha1`
