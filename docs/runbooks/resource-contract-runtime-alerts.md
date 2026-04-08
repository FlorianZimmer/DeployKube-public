# Runbook: Resource contract runtime alerts (strict namespaces)

These alerts indicate that a workload running in a namespace labelled `darksite.cloud/resource-contract=strict` is missing required explicit resource fields.

Why this matters: DeployKube treats explicit requests/limits as part of the platform contract for predictable scheduling and safe multi-tenancy.

## What to do

1) Identify the violating container from the alert labels (`namespace`, `pod`, `container`).

2) Inspect the pod spec and confirm which fields are missing:

```bash
kubectl -n <namespace> get pod <pod> -o yaml | rg -n \"resources:|requests:|limits:\"
```

3) Fix via GitOps (preferred):
- Patch the Deployment/StatefulSet/DaemonSet manifest (or Helm values) so the container has the required fields.
- For operator-managed workloads, change the CR’s resources field (e.g., CNPG `Cluster.spec.resources`) rather than hand-editing Pods.

4) If the pod is operator-managed and you can’t immediately fix it, treat it as a short-lived exception and document the follow-up:
- Prefer a GitOps-scoped exception mechanism (not `kubectl edit`) and add evidence.

## Required fields (current contract)

Tier 1 (deny in strict namespaces):
- `requests.cpu`
- `requests.memory`
- `limits.memory`

Note: CPU limits (`limits.cpu`) are intentionally **not** part of the strict contract and are not alerted on. Use CPU limits only as an explicit, workload-specific tuning choice.
