# Runbook: Job failed (`JobFailed`)

Alert meaning: a `Job` had failures (`status.failed > 0`).

## Triage (kubectl-only)

1) Identify the failed pod(s) and reason:

```bash
kubectl -n <namespace> get job <job> -o wide
kubectl -n <namespace> describe job <job>
kubectl -n <namespace> get pods -l job-name=<job> -o wide
kubectl -n <namespace> describe pod <pod>
```

2) Check logs:

```bash
kubectl -n <namespace> logs <pod> --all-containers --tail=300
```

## Remediation (preferred)

- Fix the job spec (or its dependencies) via GitOps.
- For smoke/validation jobs, also check their component README for expected failure modes.

