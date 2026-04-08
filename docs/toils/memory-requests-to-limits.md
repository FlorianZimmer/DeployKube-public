# Apply memory requests as memory limits (toil)

For most long-lived workloads, setting `resources.limits.memory` equal to `resources.requests.memory` is a common best practice:

- It makes memory limits explicit (and avoids accidental “unbounded” memory growth).
- It keeps scheduling and OOM behavior aligned (memory is not compressible; big limit/request gaps can hide risk).

This toil patches live workload controllers so that **each selected container’s memory limit equals its current memory request**.

> Warning: this patches **live cluster objects** (it will drift from GitOps until you backport the changes into `platform/gitops/**`).

## Script

- `scripts/toils/memory-requests-to-limits.py`

## Safety / behavior

- Default mode is **dry-run** (prints JSON patches it would apply).
- Skips containers without a memory request.
- By default, it will **not decrease** an existing memory limit down to the request (skip + warning).
  - Override with `--allow-decrease-limit`.
- Warnings/errors are printed **at the end** by default.
  - Stream them as they occur with `--print-issues-immediately`.
  - Limit end-of-run issue details with `--issues-max` (use `0` to show all).
  - Control color output with `--color auto|always|never`.
- `istio-proxy` is skipped by default (use `--include-istio-proxy` to include it).
- Patching a controller’s pod template will typically trigger a rollout.

## Selection

You can target:

- All `Deployment`/`StatefulSet`/`DaemonSet` workloads (default behavior).
- Specific namespaces: `--namespaces ns1,ns2` and/or `--exclude-namespaces nsX`.
- Specific pods: `--pod ns/podname` (repeatable). The script resolves the owning controller and patches it.
- Specific workloads: `--workload ns/Kind/name` (repeatable).
- Specific containers (regex): `--container '^my-container$'` (repeatable).

## Examples

Dry-run against everything:

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/memory-requests-to-limits.py
```

Apply in selected namespaces:

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/memory-requests-to-limits.py \
  --namespaces vault-system,dns-system \
  --apply
```

Allow decreasing existing memory limits:

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/memory-requests-to-limits.py \
  --namespaces vault-system \
  --allow-decrease-limit \
  --apply
```

