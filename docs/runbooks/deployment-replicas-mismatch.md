# Runbook: Deployment replicas mismatch (`DeploymentReplicasMismatch`)

Alert meaning: a `Deployment` has fewer available replicas than desired.

## Triage (kubectl-only)

```bash
kubectl -n <namespace> get deploy <deployment> -o wide
kubectl -n <namespace> describe deploy <deployment>
kubectl -n <namespace> rollout status deploy/<deployment>
kubectl -n <namespace> get rs -o wide
kubectl -n <namespace> get pods -l app=<label> -o wide
```

Also check for autoscaling intent:

```bash
kubectl -n <namespace> get hpa || true
```

## Common causes

- Pod scheduling failures (see `docs/runbooks/pod-pending.md`).
- Pod crash loops (see `docs/runbooks/pod-crash-looping.md`).
- Image pull/config errors (see `docs/runbooks/container-waiting.md`).
- HPA scaling with insufficient cluster capacity.

## Remediation (preferred)

- Fix via GitOps (resources, config, image, HPA limits, node constraints).
- After applying the fix, re-check rollout status.

