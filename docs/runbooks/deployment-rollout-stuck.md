# Runbook: Deployment rollout stuck (`DeploymentRolloutStuck`)

Alert meaning: the deployment controller is not observing/applied the latest desired generation.

## Triage (kubectl-only)

```bash
kubectl -n <namespace> get deploy <deployment> -o wide
kubectl -n <namespace> describe deploy <deployment>
kubectl -n <namespace> rollout status deploy/<deployment>
kubectl -n <namespace> get rs -o wide
kubectl -n <namespace> get pods -l app=<label> -o wide
```

Pay special attention to:
- `ProgressDeadlineExceeded`
- admission webhook denials
- stuck terminating pods / finalizers

## Remediation (preferred)

- Fix the underlying issue via GitOps (image/config/resources/admission policy conflicts).
- If the controller itself looks wedged, a safe first step is often a GitOps-managed rollout restart:

```bash
kubectl -n <namespace> rollout restart deploy/<deployment>
```

