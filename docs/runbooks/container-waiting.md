# Runbook: Container waiting (`ContainerWaiting`)

Alert meaning: a container is stuck in a waiting reason such as `ErrImagePull`, `ImagePullBackOff`, `CrashLoopBackOff`, or `CreateContainerConfigError`.

## Triage (kubectl-only)

1) Identify the waiting reason and any kubelet error:

```bash
kubectl -n <namespace> get pod <pod> -o wide
kubectl -n <namespace> describe pod <pod>
```

2) Common branches:

- `ErrImagePull` / `ImagePullBackOff`
  - wrong image/tag/digest, registry outage, missing pull secret, auth/rate limits
  - check the image reference in GitOps and any `imagePullSecrets`

- `CreateContainerConfigError`
  - missing `Secret`/`ConfigMap`, invalid env var refs, invalid volume mounts
  - `describe` usually names the missing object

- `CrashLoopBackOff`
  - see `docs/runbooks/pod-crash-looping.md`

3) Inspect recent events:

```bash
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -n 50
```

## Remediation (preferred)

- Fix via GitOps (image reference, secret/config, values/CR).
- Avoid manual edits that will be reverted by Argo CD unless you are in an explicit troubleshooting loop.

