# bootstrap-platform-drivers component issues

Canonical issue tracker for the multi-platform bootstrap abstraction (“platform drivers”) that keeps Stage 0 pluggable while preserving the GitOps bootstrap boundary.

Design:
- `docs/design/bootstrap-platform-drivers.md`
- (boundary) `docs/design/gitops-operating-model.md`

---

## Open

### Architecture

- Define the stable Stage 0 driver contract (inputs/outputs; minimum artifacts Stage 1 requires).
- Decide the mapping rule between `platformId` and `deploymentId` (recommended: `platformId` supports multiple `deploymentId`s).
- Decide where “cluster endpoint strategy” is expressed as a contract (bootstrap config vs `DeploymentConfig` fields).

### Refactors (to make adding platforms cheap)

- Unify Stage 1 into a shared implementation (keep current wrapper entrypoints stable; update `tests/scripts/validate-bootstrap-contract.sh`).
- Extract Talos bootstrap primitives from `shared/scripts/bootstrap-proxmox-talos-stage0.sh` into shared libs (no behavior changes).
- Convert Proxmox Stage 0 into a `proxmox-talos` platform driver that calls the shared Talos libs (reduce drift risk).

### New platform enablement

- Add a “driver scaffold” for a new Talos platform (pick one: Hetzner Cloud or vSphere) with:
  - `bootstrap/<platformId>/config.yaml` contract (no env hardcoding),
  - IaC module skeleton (likely OpenTofu),
  - Stage 0 driver wiring that emits the required artifacts even if the first implementation is minimal.

### Validation + evidence

- Add a repo-only lint for the driver registry (platformIds ↔ bootstrap inputs ↔ deployment profiles).
- For the first non-Proxmox Talos platform, capture an evidence note proving Stage 1 handoff + root app convergence.

### Runtime follow-ups

- Stage 1 Forgejo HTTPS bootstrap is still brittle in both inline stage1 scripts: `Deployment/forgejo-tls-proxy` keeps `readOnlyRootFilesystem: true` but only mounts `/tmp` writable, while `nginxinc/nginx-unprivileged:1.27-alpine` still needs writable cache/runtime paths such as `/var/cache/nginx` (and possibly `/var/run`). Add explicit `emptyDir` mounts without relaxing the read-only root filesystem contract.

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- (none yet)
