# Design: Renovate-Driven Version Bump Proposals

Last updated: 2026-03-09  
Status: Proposed

This design defines how DeployKube should use Renovate as a proposal engine for curated version bumps without weakening the existing GitOps, CI, and runtime-validation contracts.

## Tracking

- Canonical tracker: `docs/component-issues/version-bump-automation.md`

Related:
- Current proposal workflow: `docs/toils/version-bump-proposals.md`
- Pinning baseline: `docs/design/supply-chain-pinning-policy.md`
- Version catalog: `versions.lock.yaml`
- Coverage validator: `tests/scripts/validate-version-lock-component-coverage.sh`

## Scope / ground truth

Repo-truth scope for this design:
- curated version inventory in `versions.lock.yaml`
- concrete pin sites under `platform/gitops/**`, `shared/scripts/**`, and selected repo metadata files
- validators under `tests/scripts/**`
- component trackers under `docs/component-issues/**`

This design is intentionally narrower than “platform auto-upgrades”. It covers update discovery and PR generation for curated, repo-owned version surfaces only.

## Problem statement

DeployKube now has a curated version catalog and CI coverage guardrails, but update discovery is still largely manual. That does not scale well as more components move into `versions.lock.yaml`.

At the same time, blind automation is a poor fit for this repo because many upgrades require repo-specific work:
- vendored Helm chart refreshes
- committed render refreshes
- signed-chart or image verification
- runtime GitOps reconcile checks
- smoke tests and evidence notes

Using Renovate safely therefore requires a repo-specific contract. Without one, the bot either misses important version surfaces or opens misleading PRs that look smaller than the real operational change.

## Decision summary

DeployKube should use Renovate in a constrained role:
- `versions.lock.yaml` remains the curated source of truth for covered components.
- Renovate proposes version bumps only for components already covered by that catalog.
- Renovate opens PRs only; it does not auto-merge or auto-deploy.
- PRs stay component-sized, even when labels and schedules are grouped by bump class.
- CI validators and component-specific runtime/evidence workflows remain mandatory and are not delegated to Renovate.

This keeps the current policy model intact while reducing the manual toil of tracking upstream releases.

## Goals

1. Reduce manual version-discovery work for covered components.
2. Keep proposal PRs aligned with `versions.lock.yaml` and its bump classes.
3. Preserve GitOps-first review, runtime validation, and evidence discipline.
4. Avoid unsafe repo-wide “bump everything” automation.
5. Keep uncovered components explicitly tracked in their own component-issue files until they are curated.

## Non-goals

- Auto-merging version bumps.
- Auto-applying runtime follow-up steps such as vendoring charts, regenerating renders, or writing evidence.
- Managing every version-looking string in the repo from day one.
- Replacing `versions.lock.yaml` with Renovate-native state.
- Creating one mega-PR for every available update in the platform.

## Architecture

### 1. Source of truth remains repo-owned

`versions.lock.yaml` stays authoritative for:
- which components are curated,
- which bump class they belong to,
- which component issue trackers they own,
- and which shared validations apply to that class.

Renovate is a consumer of this catalog, not the replacement for it.

Consequences:
- if a component is not in `versions.lock.yaml`, Renovate should ignore it,
- if a component is intentionally uncovered, the gap must remain tracked in its own `docs/component-issues/<component>.md`,
- and CI remains the enforcement point for coverage completeness.

### 2. Renovate updates curated pin sites, not the whole repo

Renovate should manage only the machine-oriented version surfaces that map cleanly to the curated catalog:
- Helm chart versions in `kustomization.yaml` or upstream metadata files
- selected image tags in bootstrap scripts or GitOps values
- vendored bundle/version markers that can be expressed as explicit regex-managed fields
- the matching component entry in `versions.lock.yaml`

Renovate should not directly “manage everything that looks like a version”, especially:
- evidence notes
- free-form prose in old docs
- generated or vendored content that requires a repo helper
- component trackers

For human-facing docs such as `target-stack.md`, the safer contract is:
- either update them via a repo-owned sync helper in the same PR,
- or keep them as required manual follow-up until that helper exists.

### 3. PR granularity: one component-sized change

The proposal report workflow groups inventory by bump class. Renovate PRs should not blindly mirror that grouping.

Recommended PR shape:
- one PR per covered component,
- class-based labels, schedules, and reviewer routing,
- separate major bumps from minor/patch bumps,
- and tighter concurrency limits for `tier0-security` and `bootstrap-core`.

Why:
- cert-manager, Vault/OpenBao, Kyverno, Argo CD, and similar components have too much blast radius for multi-component bot PRs,
- runtime validation and evidence are easier to reason about when the PR matches one operational change,
- and rollback is simpler when each PR maps to one component.

### 4. Native managers first, regex/custom managers second

Recommended order:
1. Use Renovate native managers where the file format is well understood.
2. Use regex/custom managers only for curated pin surfaces that have a stable repo contract.
3. Do not add regex rules for ad hoc strings just to increase coverage quickly.

Likely initial manager set:
- Helm chart versions in `kustomization.yaml` or chart metadata
- Docker/image tags in selected YAML and shell pin sites
- regex manager for `versions.lock.yaml` entries that map one-to-one to those pin sites
- regex manager for static bundle markers such as Gateway API bundle version annotations

## Pull request contract

Every Renovate PR must satisfy the same repo contract as a manual bump:
- `./tests/scripts/validate-version-lock.sh`
- `./tests/scripts/validate-version-lock-component-coverage.sh`
- `./tests/scripts/validate-supply-chain-pinning.sh`
- class-shared validations from `versions.lock.yaml`
- component-specific validators referenced by the touched component
- runtime validation and evidence for tier-0, bootstrap, access-plane, CRD-heavy, or trust-plane changes

Renovate is allowed to propose the change. It is not allowed to waive any required validation.

## Operational policy

Recommended baseline:
- PR-only mode
- no automerge
- dashboard enabled so backlog is visible without flooding reviewers
- schedule regular proposal windows instead of constant churn
- class-based labels such as `dependencies`, `bump-class:tier0-security`, `bump-class:bootstrap-core`
- separate reviewer routing for tier-0 vs lower-blast-radius classes

Recommended conservative defaults:
- pause or heavily rate-limit `bootstrap-core` and `tier0-security` proposals
- allow somewhat higher cadence for lower-risk platform-service bumps once the workflow is proven
- major-version PRs always separate from patch/minor PRs

## Required repo follow-up outside Renovate

Several upgrade actions remain explicitly repo-owned:
- vendoring or refreshing upstream charts
- regenerating committed rendered manifests
- running signed-chart or supply-chain verification helpers
- updating `target-stack.md` and similar operator-facing docs
- collecting runtime evidence and recording risk acceptance where needed

If a bump cannot be completed safely without one of these steps, the PR should remain draft or blocked until the repo workflow provides that follow-up.

## Open implementation decisions

These do not block the design, but they should be resolved before turning Renovate on:

1. `target-stack.md` synchronization
- Option A: let Renovate edit selected `target-stack.md` fragments directly.
- Option B: add a repo-owned sync helper and keep the doc update out of Renovate rules.
- Recommended: Option B. It keeps Renovate on machine-oriented pin sites and avoids brittle prose matching.

2. `versions.lock.yaml` update strategy
- Option A: Renovate edits only real pin sites and a repo helper updates the lock file afterward.
- Option B: Renovate updates the lock entry in the same PR via regex/custom manager rules.
- Recommended: Option B, as long as each rule is tied to a curated component and validated by `validate-version-lock.sh`.

3. Initial class rollout
- Option A: enable Renovate for every current class immediately.
- Option B: start with `platform-services`, then add `bootstrap-core`, then `tier0-security`.
- Recommended: Option B. It gives the repo one lower-risk proving ground before exposing trust/bootstrap components to bot-generated PRs.

## Rollout plan

1. Add the design/tracker and keep Renovate disabled by default.
2. Expand `versions.lock.yaml` only where the repo has a clear validation story.
3. Add a constrained Renovate config for one initial class.
4. Prove that PRs update the expected pin sites and fail cleanly when follow-up work is missing.
5. Add more classes only after the first class produces clean, reviewable PRs.

## Success criteria

This design is successful when:
- covered components receive reviewable proposal PRs without manual version discovery,
- uncovered components remain visibly tracked instead of silently skipped,
- no bot PR bypasses CI/runtime validation expectations,
- and operators can still understand the blast radius of each proposed bump from the PR itself.
