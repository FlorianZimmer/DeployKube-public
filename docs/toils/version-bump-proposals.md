# Version bump proposals

This toil documents the proposal-driven version bump workflow for curated core pins.

Machine-readable catalog:
- `versions.lock.yaml`

Repo validator:
- `./tests/scripts/validate-version-lock.sh`
- `./tests/scripts/validate-version-lock-component-coverage.sh`

Related design:
- `docs/design/renovate-version-bump-proposals.md`

Proposal generator:
- `./scripts/dev/version-bump-proposal.sh`

Scope today:
- curated core pins only
- grouped by bump class, not the entire repo
- this is intentionally incremental; some version surfaces still rely on existing component-specific validators and the older pinning fixture while the catalog expands
- uncovered components must keep the gap explicitly tracked in their own `docs/component-issues/<component>.md` file until curated lock coverage is added

## Why this exists

DeployKube has version pins spread across:
- bootstrap scripts
- vendored chart metadata
- GitOps kustomizations
- human-facing docs such as `target-stack.md`

Blind “bump everything” automation is a poor fit for this repo because many changes affect:
- Stage 0 / Stage 1 bootstrap
- CRDs and webhooks
- digest-pinned images and mirror rewrites
- runtime GitOps reconciliation and smoke coverage

The goal here is therefore:
- make version inventory and proposal generation easy
- keep merge decisions and runtime validation case-by-case

## Generate a report

All curated classes:

```bash./scripts/dev/version-bump-proposal.sh
```

Single class:

```bash./scripts/dev/version-bump-proposal.sh --class tier0-security
```

Concrete candidate proposal without editing repo files:

```bash./scripts/dev/version-bump-proposal.sh \
  --class tier0-security \
  --set cert-manager-chart=v1.19.3
```

Write the report to disk:

```bash./scripts/dev/version-bump-proposal.sh \
  --class bootstrap-core \
  --write-report tmp/bootstrap-core-version-proposal.md
```

## Workflow

1. Generate the proposal report for one class or one component-sized change.
2. Decide whether the bump is worth doing now.
3. Update the actual repo pin sites for that component.
4. Update `versions.lock.yaml` in the same change.
5. If the component is now covered, remove the standard `DK:VERSION_LOCK_GAP_TRACKED` note from its issue tracker; if it is still intentionally uncovered, keep that note in place.
6. Run `./tests/scripts/validate-version-lock.sh`, `./tests/scripts/validate-version-lock-component-coverage.sh`, plus the component-specific validators listed in the proposal.
7. For tier-0 / bootstrap / access-plane changes, complete the required runtime validation and record evidence.

## What this does not do

- It does not fetch upstream latest versions.
- It does not edit pinned files automatically.
- It does not replace component-specific upgrade procedures.
- It does not authorize batch upgrades of unrelated tier-0 components.
