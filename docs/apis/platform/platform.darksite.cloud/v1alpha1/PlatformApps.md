# API Reference: `PlatformApps` (`platform.darksite.cloud/v1alpha1`)

## Summary

- Group/version/kind: `platform.darksite.cloud/v1alpha1`, `PlatformApps`
- Scope: namespaced (DeployKube contract expects a single object in `argocd`)
- Reconciler/controller:
  - `platform-apps-controller` (implemented in `tools/tenant-provisioner`)
- Installed from (GitOps):
  - CRD + controller: `platform/gitops/components/platform/platform-apps-controller`

## When to use this

Use `PlatformApps` to declare the desired Argo CD `Application` fan-out for platform components (paths, destinations, sync policy, and optional overlays), replacing the legacy rendered chart approach.

## Singleton contract (important)

DeployKube expects one primary `PlatformApps` instance:

- `metadata.name: platform-apps`
- `metadata.namespace: argocd`

Controllers and validation scripts assume this singleton contract.

## Spec (operator-relevant fields)

`spec.repoURL` (string, required)
- Git repository URL Argo should read component manifests from.

`spec.targetRevision` (string, required)
- Git revision for all generated child Applications (for example `main`).

`spec.overlayMode` (string, required)
- Environment overlay selection mode used by the controller when resolving app paths.

`spec.deploymentId` (string, required)
- Deployment identifier used for overlay path interpolation and environment-specific selection.

`spec.enabledApps` / `spec.disabledApps` (string arrays, optional)
- Explicit allow/deny toggles applied by the controller.

`spec.globalKustomizeImages` (string array, optional)
- Global image rewrite list injected into generated Applications.

`spec.apps` (array, required)
- List of desired platform apps.
- Key per-app fields:
  - `name`, `path` (required)
  - `project`, `enabled`, `overlay`, `overlayPaths`
  - `destination.cluster`, `destination.namespace`
  - `syncWave`, `annotations`
  - `syncPolicy` (preserve-unknown-fields)
  - `ignoreDifferences[]` (preserve-unknown-fields items)

> For the full schema, see `platform/gitops/components/platform/platform-apps-controller/base/platform.darksite.cloud_platformapps.yaml`.

## Status

`PlatformApps` currently has no declared status schema in `v1alpha1`. Treat it as a spec-driven contract; inspect generated Argo CD `Application` resources for reconciliation state.

## Example

```yaml
apiVersion: platform.darksite.cloud/v1alpha1
kind: PlatformApps
metadata:
  name: platform-apps
  namespace: argocd
spec:
  repoURL: https://forgejo-https.forgejo.svc.cluster.local/platform/cluster-config.git
  targetRevision: main
  overlayMode: ""
  deploymentId: proxmox-talos
  enabledApps: []
  disabledApps: []
  globalKustomizeImages: []
  apps:
    - name: platform-argocd-config
      path: components/platform/argocd/config/overlays/proxmox-talos
      destination:
        namespace: argocd
      syncWave: "3.5"
```

## Upgrade / migration notes

- Treat `v1alpha1` as an incubating API; breaking shape changes require migration docs and evidence.
- Keep the singleton `argocd/platform-apps` object stable to avoid fan-out churn.
