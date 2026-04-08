# Toil: HPA with Argo CD (no GitOps fight)

Goal: run `HorizontalPodAutoscaler` for a GitOps-managed workload without Argo self-heal constantly resetting replicas.

## Preconditions

1) Resource metrics work (metrics-server):

```bash
kubectl top nodes
kubectl top pods -A | head
```

2) The workload has CPU requests (required for `% utilization` targets).

## Pattern

1) Add an HPA (GitOps) with an explicit floor:

- Set `minReplicas: 2` to keep baseline HA (and tolerate a single node failure for stateless workloads).
- Set a conservative `maxReplicas` to avoid “autoscaling into OOM” on small dev clusters.

2) Set the workload’s baseline replica field to match the HPA floor:

- Deployments: `.spec.replicas: 2`
- Keycloak CR: `.spec.instances: 2` (Keycloak CRD exposes scale via `/spec.instances`)
- Other CRDs: check the CRD `subresources.scale.specReplicasPath`

3) Tell Argo to ignore the HPA-managed replica field:

- For Deployments: ignore `/spec/replicas`
- For Keycloak CR: ignore `/spec/instances`
- Add `RespectIgnoreDifferences=true` so Argo does not overwrite ignored fields during unrelated syncs.

In DeployKube, do this in the `PlatformApps` catalog (`platform/gitops/components/platform/platform-apps-controller/base/platformapps.platform.darksite.cloud.yaml`) so environment overlays inherit consistent behavior.

## Verify

```bash
kubectl -n <ns> get hpa
kubectl -n <ns> describe hpa <name>
kubectl -n <ns> get <kind> <name> -o jsonpath='{.spec.replicas}{"\n"}' 2>/dev/null || true
```

Argo should show the owning app as `Synced` even while replicas change under load.
