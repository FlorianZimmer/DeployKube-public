# API Reference: `DeploymentConfig` (`platform.darksite.cloud/v1alpha1`)

## Summary

- Group/version/kind: `platform.darksite.cloud/v1alpha1`, `DeploymentConfig`
- Scope: cluster-scoped (singleton)
- Reconciler/controller:
  - `deployment-config-controller` (in `tools/tenant-provisioner`)
  - Additional controllers may read snapshots (see component READMEs)
- Installed from (GitOps):
  - CRD: `platform/gitops/components/platform/deployment-config-crd`
  - Controller: `platform/gitops/components/platform/deployment-config-controller`

## When to use this

Use `DeploymentConfig` to declare **deployment identity + environment-specific configuration** that multiple components consume (DNS, cert modes, backup settings, etc.).

## Singleton contract (important)

DeployKube expects **exactly one** `DeploymentConfig` object in the cluster.

Invariants:
- `metadata.name == spec.deploymentId` (CRD validation + controller enforcement)
- Singleton: controllers error if there are 0 or >1 objects

## Spec (operator-relevant fields)

`spec.deploymentId` (string, required)
- Stable deployment identifier (also the GitOps deployment folder name).

`spec.environmentId` (enum, required)
- Semantic environment identifier (`dev`, `prod`, `staging`).

`spec.dns` (object, required)
- `baseDomain`: deployment base domain (internal convention).
- `hostnames`: explicit external hostnames for platform endpoints.
  - `argocd`: Argo CD public host.
  - `forgejo`: Forgejo public host.
  - `keycloak`: Keycloak public host (consumed by Argo CD OIDC bootstrap job and other OIDC clients).
- Optional: operator DNS servers for LAN/ops validation, delegation settings.

`spec.certificates` (object, optional)
- Platform ingress and tenant workload certificate issuance/projection modes (for example `subCa`, `acme`, `wildcard` for platform ingress).

> For the full schema, see the CRD: `platform/gitops/components/platform/deployment-config-crd/base/platform.darksite.cloud_deploymentconfigs.yaml`.

## Status

`DeploymentConfig.status` now publishes controller-owned observed state for selected deployment-wide surfaces.

Current status contract:
- `status.observedGeneration`: generation last observed by the status writer.
- `status.dns.delegation`: canonical delegation output surface derived by the DNS wiring controller.
  - `mode`
  - `baseDomain`
  - `parentZone` when delegation is configured
  - `nameServers`
  - `authoritativeDNSIP`
  - `parentNSRecords`
  - `parentGlueRecords`
  - `manualInstructions` for `mode=manual`

Do not treat other `.status` fields as stable unless they are explicitly documented.

## Outputs (published snapshots)

The `deployment-config-controller` publishes a per-namespace snapshot:
- `ConfigMap/<ns>/deploykube-deployment-config` (YAML under `.data.deployment-config.yaml`)

Snapshot namespaces are controller-configured and include control-plane namespaces (for example `argocd`, `backup-system`, `grafana`, …).

## Examples

Minimal example:

```yaml
apiVersion: platform.darksite.cloud/v1alpha1
kind: DeploymentConfig
metadata:
  name: proxmox-talos
spec:
  deploymentId: proxmox-talos
  environmentId: prod
  dns:
    baseDomain: prod.internal.example.com
    hostnames:
      argocd: argocd.prod.internal.example.com
      forgejo: forgejo.prod.internal.example.com
      keycloak: keycloak.prod.internal.example.com
  trustRoots: {}
  network: {}
  secrets: {}
  time: {}
```

## Upgrade / migration notes

- Treat `v1alpha1` as an incubating contract: any breaking spec change requires a migration plan + evidence.
- Keep a single object; do not create per-environment instances inside one cluster.
