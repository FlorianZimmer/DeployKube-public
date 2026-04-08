# Tier-0 Supply-Chain Pinning Policy

## Tracking

- Canonical tracker: `docs/component-issues/cloud-productization-roadmap.md`
- Related tracker: `docs/component-issues/distribution-bundles.md`

## Purpose

Define a concrete, CI-enforced minimum bar for tier-0 supply-chain pinning so bootstrap and first GitOps reconcile stay reproducible across deployments.

## Scope

Tier-0 scope for this policy:
- Stage 0/Stage 1 bootstrap entrypoints (`shared/scripts/bootstrap-*-stage0.sh`, `shared/scripts/bootstrap-*-stage1.sh`).
- Tier-0 GitOps install sources (`platform/gitops/components/**`) for foundational control-plane/security components.

This policy is repo-truth only. It does not claim runtime cluster state.

## Rules

1. Tier-0 installs must be explicitly pinned.
- Helm installs must set an explicit chart version (no implicit latest).
- Image references must use a fixed version identifier (digest preferred; version tag allowed when digest pinning is not yet practical, but must be paired with an explicit verification control).
- Static vendored manifests must carry an explicit upstream bundle/version marker.

2. Unpinned tier-0 usage is only allowed as a temporary exception.
- Exception must be explicitly listed in `tests/fixtures/supply-chain-tier0-pinning.tsv`.
- Exception must include an expiry date and a canonical tracker reference.
- Expired exceptions fail CI.

3. New tier-0 components must be registered before merge.
- Any new tier-0 bootstrap/install source must add at least one matching rule to `tests/fixtures/supply-chain-tier0-pinning.tsv`.
- If the component cannot be pinned yet, add a temporary exception row with expiry + tracker.

## CI enforcement

- Validator: `tests/scripts/validate-supply-chain-pinning.sh`
- Curated machine-readable proposal catalog: `versions.lock.yaml`
- Catalog validator: `tests/scripts/validate-version-lock.sh`
- Component coverage validator: `tests/scripts/validate-version-lock-component-coverage.sh`
- Component-specific verification controls (when version tags are intentionally retained) should be wired into `tests/scripts/ci.sh` `deployment-contracts` suite.
- Fixture: `tests/fixtures/supply-chain-tier0-pinning.tsv`
- CI suite wiring: `tests/scripts/ci.sh` (`deployment-contracts` suite)

## Proposal workflow (incremental)

- Related design: `docs/design/renovate-version-bump-proposals.md`
- Use `versions.lock.yaml` as the curated machine-readable catalog for grouped bump proposals.
- Each covered version entry should declare which component tracker(s) it owns via `tracks_issue_slugs`.
- Component-level coverage status now lives in `docs/ai/prompt-templates/component-assessment/component-catalog.tsv`:
  - `version_lock_mode=direct|shared|none|gap`
  - `version_lock_refs_csv=<versions.lock.yaml component ids>`
- Use `./scripts/dev/version-bump-proposal.sh` to render a reviewable report by bump class.
- This does **not** authorize blind repo-wide auto-bumps; merge/runtime validation stays component-by-component.
- The lock file is intentionally incremental for now and complements the existing TSV pinning fixture while the catalog expands.
- Only components marked `version_lock_mode=gap` should carry the explicit open tracking note in `docs/component-issues/<component>.md`.

## Current temporary exceptions (tracked)

- None currently.
