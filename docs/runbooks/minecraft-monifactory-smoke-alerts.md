# Runbook: Minecraft Monifactory smoke alerts (TCP reachability)

These alerts cover the Monifactory server reachability smoke in namespace `minecraft-monifactory`:

- `MinecraftMonifactorySmokeJobFailed` (critical)
- `MinecraftMonifactorySmokeCronJobStale` (warning)

Underlying CronJob:
- `CronJob/minecraft-monifactory/minecraft-tcp-smoke`

## What this smoke validates

Every 15 minutes, the CronJob attempts to open a TCP connection to:
- `minecraft.minecraft-monifactory.svc.cluster.local:25565`

Success means the in-cluster Service endpoint is accepting game traffic on the expected port.

## Quick triage (kubectl-only)

1. Confirm the CronJob is present and scheduling:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get cronjob minecraft-tcp-smoke -o wide
```

2. Inspect recent Jobs:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get jobs --sort-by=.metadata.creationTimestamp | tail -n 20
```

3. Check logs from the newest failed Job:

```bash
job="$(KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get jobs -o name | rg 'minecraft-tcp-smoke-' | tail -n 1 | sed 's#job.batch/##')"
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory logs "job/${job}" -c tcp-smoke
```

4. Verify workload and Service readiness:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get deploy minecraft
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get pods -l app=minecraft-monifactory -o wide
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get svc minecraft -o wide
KUBECONFIG=tmp/kubeconfig-prod kubectl -n minecraft-monifactory get endpoints minecraft -o wide
```

## Common causes

- Minecraft container is not fully started yet (cold startup, modpack update, long chunkgen).
- Pod is restarting/CrashLoopBackOff and never reaches steady-state readiness.
- Service has no ready endpoints (selector mismatch, no Ready pod).
- Network policy or mesh-side changes block in-namespace TCP reachability.
