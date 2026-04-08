# Dev -> Prod Promotion Doctrine (homelab-first)

## Tracking

- Canonical tracker: `docs/component-issues/dev-to-prod-promotion.md`

## Intent

DeployKube currently runs in a constrained homelab model, not in a multi-cluster customer production model.

The promotion doctrine therefore standardizes **promotion evidence and guardrails** now, while deferring a true dedicated prod split until customer-facing reliability/SLA requirements exist.

## Current deployment roles

| Deployment ID | Role in this phase | Primary expectation |
|---|---|---|
| `mac-orbstack` | dev | rapid iteration, break/fix acceptable |
| `mac-orbstack-single` | dev (travel/lightweight) | quick local validation when resources are limited |
| `proxmox-talos` | prod-like (homelab) | data durability for selected workloads, no customer-grade uptime SLA |
| `staging` | reserved | not currently required |

Notes:
- `proxmox-talos` is the highest-confidence environment today, but it is still homelab-operated.
- Stateful workloads that matter (for example game worlds) are treated as durability-critical even in this prod-like model.

## HA baseline for `proxmox-talos`

- Product baseline: minimum 3 worker nodes.
- Replication policy is tiered per workload (`darksite.cloud/ha-tier`), not global `replicas: 3`:
  - `tier-0`: odd quorum replicas, minimum 3
  - `tier-1`: minimum 2 replicas
  - `tier-2`: singleton/non-critical allowed
- Promotion into `proxmox-talos` must keep the HA tier contract valid under CI:
  - `./tests/scripts/validate-ha-three-node-deadlock-contract.sh`

## Repository structure expectations

- **Environment-neutral base**: component `base/` carries shared manifests and no deployment-specific hostnames or URLs.
- **Deployment overlays**: `overlays/<deploymentId>/` contains deployment-specific deltas (`mac-orbstack`, `mac-orbstack-single`, `proxmox-talos`; `staging` when used).
- **Environment bundles**: `platform/gitops/apps/environments/<deploymentId>/` assembles the deployment.
- **Promotion path (current)**: promote from a dev deployment (`mac-orbstack*`) to `proxmox-talos`.

## Minimum promotion evidence (required per promoted component)

1. **Argo status evidence**
   - Root app and promoted app show `Synced Healthy` after reconciliation.
2. **Smoke output path**
   - At least one relevant smoke/validation output path is captured in the evidence note.
3. **Rollback note**
   - Evidence note includes the rollback path (commit revert target + Argo reconcile expectation).
4. **Stateful durability check (when applicable)**
   - If a promoted change touches durability-critical stateful workloads, include backup/restore or equivalent data-safety evidence.

## What to document in each component README

Add a **Dev -> Prod** section that answers:

- What changes between dev and `proxmox-talos` (replicas/resources/storage/network exposure).
- Where these changes are configured (overlay/value file paths).
- Safe promotion steps (sync order, expected health checks, required smoke).
- Rollback path and expected blast radius.

## Guardrails decision (2026-02-18)

Decision:
- Do **not** enforce a repo-wide CI gate yet that forbids all prod-only drift.

Why:
- Current infrastructure is intentionally mixed (homelab prod-like + travel/dev clusters), and a hard global parity gate would block valid incremental work.

Required guardrails now:
- Promotion evidence is mandatory for changes shipped to `proxmox-talos`.
- Any intentional drift that exists only in `proxmox-talos` must be justified in docs/evidence with rollback notes.
- Platform-critical components should still prefer overlay parity, with explicit rationale when parity is not possible.

## Trigger for true prod split

Move from this doctrine to a strict multi-environment promotion model when either condition becomes true:

1. external customers depend on the platform, or
2. formal uptime/SLA requirements exceed homelab operations.

At that point, introduce dedicated staging/prod capacity and tighten CI policy from "documented drift allowed" to "parity required unless explicitly waived."
