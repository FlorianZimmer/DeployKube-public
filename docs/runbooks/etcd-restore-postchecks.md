# Runbook: Etcd restore post-checks (Kubernetes / Talos)

This runbook is the **post-recovery checklist** after an etcd snapshot restore / control-plane recovery event.

Goal: return the cluster to a clean, GitOps-reconciled state and avoid slow “mystery drift” (stale `Failed` pods, stuck smokes, noisy alerts).

## 1) Baseline: cluster is reachable

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl get nodes -o wide
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd get application platform-apps -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```

Expected:
- All nodes `Ready`
- Root app `Synced Healthy`

## 2) Clear “ContainerStatusUnknown” / stale failed pods (common after node shutdown/reboots)

If you see many `ContainerStatusUnknown` pods, first identify the owning workload and node lifecycle reason:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl get pods -A -o wide | rg 'ContainerStatusUnknown|Unknown' || true
```

### Common case: `cilium-operator` accumulated `Failed` pods during control-plane shutdown

Safe cleanup:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n kube-system delete pod \
  -l io.cilium/app=operator \
  --field-selector=status.phase=Failed
```

Post-check:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n kube-system get pods -l io.cilium/app=operator -o wide
KUBECONFIG=tmp/kubeconfig-prod kubectl get pods -A --no-headers | awk '$4=="ContainerStatusUnknown"{c++} END{print c+0}'
```

Expected:
- `cilium-operator` has the desired replicas, ideally on worker nodes when workers exist
- `ContainerStatusUnknown` count is `0`

## 3) Re-run / check continuous smokes

### Backup plane (S3 DR replication / mirror)

Check recent runs:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n backup-system get jobs | rg 'storage-s3-mirror-to-backup-target' || true
```

Manual trigger (operator action):

```bash
job="manual-s3-mirror-$(date +%s)"
KUBECONFIG=tmp/kubeconfig-prod kubectl -n backup-system create job --from=cronjob/storage-s3-mirror-to-backup-target "${job}"
```

### Observability (Tempo trace smoke)

Check:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n observability get jobs | rg 'observability-trace-smoke' || true
```

Manual trigger:

```bash
job="manual-trace-smoke-$(date +%s)"
KUBECONFIG=tmp/kubeconfig-prod kubectl -n observability create job --from=cronjob/observability-trace-smoke "${job}"
```

## 4) Evidence discipline

If you performed breakglass actions (deleting pods, scaling, Helm upgrades), record evidence:
- `docs/evidence/YYYY-MM-DD-<topic>.md`

Include:
- why it was necessary
- the exact commands
- pre/post checks
