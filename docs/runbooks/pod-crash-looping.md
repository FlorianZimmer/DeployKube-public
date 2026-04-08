# Runbook: Pod crash looping (`PodCrashLooping`)

Alert meaning: a container in `namespace/pod` restarted repeatedly (typically `CrashLoopBackOff`).

## Triage (kubectl-only)

1) Inspect the pod and its recent events:

```bash
kubectl -n <namespace> get pod <pod> -o wide
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -n 50
```

2) Check logs (current + previous container instance):

```bash
kubectl -n <namespace> logs <pod> -c <container> --tail=200
kubectl -n <namespace> logs <pod> -c <container> --previous --tail=200 || true
```

3) Common quick checks:
- **Config**: missing `Secret`/`ConfigMap`, bad env var, bad command/args (shows in `describe`).
- **Probes**: failing readiness/liveness (events show probe failures).
- **OOM / resources**: check `Last State` and `Reason` in `describe`; confirm requests/limits are sane.
- **Permissions**: filesystem/permission errors, securityContext mismatch.

## Remediation (preferred)

- Fix the root cause via GitOps (manifest/values/CR). Avoid `kubectl edit` except for temporary breakglass.
- If you need to un-wedge a rollout after fixing Git, restart the owning controller:

```bash
kubectl -n <namespace> rollout restart deploy/<deployment>
```

## Evidence

If this is a platform incident or required breakglass actions, capture an evidence note under `docs/evidence/YYYY-MM-DD-<topic>.md`.

