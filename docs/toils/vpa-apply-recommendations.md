# Apply VPA recommendations to workload requests (toil)

DeployKube keeps VPA in **recommendation-only** mode (`updateMode: Off`) by default. This toil helps you **materialize** VPA recommendations into the actual workload controller spec by patching:

- `Deployment.spec.template.spec.containers[].resources.requests`
- `StatefulSet.spec.template.spec.containers[].resources.requests`
- `DaemonSet.spec.template.spec.containers[].resources.requests`

Optional:
- `*.spec.template.spec.containers[].resources.limits.memory` (derived from the chosen VPA memory request bound + headroom)

This is useful when you want to “accept” recommendations without enabling VPA automation.

> Warning: this patches **live cluster objects** (it will drift from GitOps until you backport the request changes into `platform/gitops/**`).

## Script

- `scripts/toils/vpa-apply-recommendations.py`

## Safety / behavior

- Default mode is **dry-run** (prints JSON patches it would apply).
- Default safety: **never decrease** requests below the current request (skip instead).
  - Override with `--allow-decrease`.
- Default safety: **never set request above limit** (skip instead).
  - Override with `--allow-request-above-limit`.
- Warning: emits a warning when a request would be set close to the limit (default threshold: request/limit `>= 0.9`, configurable with `--warn-request-limit-ratio`).
- Warnings/errors are printed **at the end** by default (so they don’t get lost in large runs).
  - Stream them as they occur with `--print-issues-immediately`.
  - Limit end-of-run issue details with `--issues-max` (use `0` to show all).
  - Control color output with `--color auto|always|never`.
- Memory quantities are normalized for readability (default output uses `Mi`); use `--memory-unit bytes` to preserve raw byte values.
- Choose which VPA bound to apply:
  - `--bound lower` (lower bound)
  - `--bound target` (default)
  - `--bound upper` (upper bound)
- Choose which resources to apply:
  - `--resources cpu,memory` (default)
  - `--resources cpu` (CPU only)
  - `--resources memory` (memory only)
- Optional: set memory limits with headroom (default: off):
  - `--set-memory-limit`
    - Note: this can change `limits.memory` even when the request does not change (limits are derived from the chosen VPA memory request bound).
  - `--memory-limit-mode headroom|equal-request` (default: `headroom`)
  - `--memory-limit-headroom-percent-of-limit 20` (default)
  - `--memory-limit-min-headroom 32Mi` (default)
  - `--allow-decrease-memory-limit` (not recommended)
- Capacity safety checks (enabled by default):
  - Per-pod request must fit on at least one node (disable with `--no-check-fit-on-node`).
  - Total increase must fit in cluster headroom (allocatable - requested) (disable with `--no-check-cluster-headroom`).
- `istio-proxy` is skipped by default (use `--include-istio-proxy` to include it).
- Patching a controller’s pod template will typically trigger a rollout.
- The script prints a **plan summary** at the end (delta vs cluster headroom + max pod request vs max node allocatable).
- Optional: `--backport-gitops` writes **Kustomize patch files** into the local repo so Argo won’t revert the change.
  - By default it waits for `kubectl rollout status` for patched workloads, then asks for explicit confirmation before writing patches.
  - Use `--yes` for non-interactive runs; use `--no-rollout-wait` to skip waiting (not recommended).
  - If you already applied changes and only need to write Git, add `--backport-include-unchanged`.

## Selection

You can target:

- **All** workloads with VPA recommendations (default behavior).
- Specific **namespaces**: `--namespaces ns1,ns2` and/or `--exclude-namespaces nsX`.
- Specific **pods**: `--pod ns/podname` (repeatable). The script resolves the owning controller and patches it.
- Specific **workloads**: `--workload ns/Kind/name` (repeatable).
- Specific **containers** (regex): `--container '^my-container$'` (repeatable).

## Examples

Dry-run against everything (prints patches only):

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py
```

Apply the VPA *target* recommendation to all workloads in `dns-system` and `kube-system`:

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --namespaces dns-system,kube-system \
  --bound target \
  --apply
```

Apply the VPA *target* recommendation to requests, and set memory limits to `target + headroom`:

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --namespaces vault-system \
  --bound target \
  --resources cpu,memory \
  --set-memory-limit \
  --memory-limit-headroom-percent-of-limit 20 \
  --apply
```

Apply the *upper bound* to the `powerdns` Deployment only (and only the `powerdns` container):

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --workload dns-system/Deployment/powerdns \
  --bound upper \
  --apply
```

Patch the owning controller for a single pod (useful for debugging a specific replica):

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --pod dns-system/powerdns-xxxxxxxxxx-yyyyy \
  --apply
```

Allow decreasing requests (not recommended unless you are intentionally downsizing):

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --namespaces dns-system \
  --bound lower \
  --allow-decrease \
  --apply
```

Set memory `requests == limits` (no headroom) using the VPA target recommendation:

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --bound target \
  --resources memory \
  --allow-decrease \
  --set-memory-limit \
  --memory-limit-mode equal-request \
  --allow-decrease-memory-limit \
  --apply
```

## GitOps follow-up (recommended)

After applying changes for validation, backport the resource values into the GitOps manifests under `platform/gitops/**` and reconcile via Argo, then remove any breakglass drift.

The script can also do the backport automatically (writes Kustomize strategic merge patches into the Argo Application’s `spec.source.path`):

```bash
KUBECONFIG=tmp/kubeconfig-prod./scripts/toils/vpa-apply-recommendations.py \
  --namespaces vault-system \
  --bound target \
  --resources cpu,memory \
  --apply \
  --backport-gitops
```
