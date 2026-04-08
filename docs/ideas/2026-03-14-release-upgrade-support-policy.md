# Idea: Release Upgrade Support Policy

Date: 2026-03-14
Status: Draft

## Problem statement

DeployKube already has runtime release gating and some component-local upgrade notes, but it does not yet have a clear product-level answer to:

- which upgrade paths are officially supported for field deployments
- what proof is required before tagging a release
- which components must support rollback vs roll-forward-only behavior
- how support expectations should be communicated once real deployed clusters exist

Without that, upgrades stay partly implicit:

- some components have concrete upgrade/rollback notes and evidence
- some do not
- the release gate proves a candidate commit is healthy, but not yet that `previous supported release -> candidate release` was exercised end to end

## Why now / drivers

- The cert-manager Proxmox rehearsal closed the first roadmap-level upgrade/rollback gap and showed that real runtime rehearsal produces useful operator knowledge.
- The repo already has release-gate entrypoints:
  - `scripts/release/release-gate.sh`
  - `scripts/release/release-tag.sh`
  - `docs/guides/release-checklist.md`
- Several component trackers still have open upgrade/rollback strategy items, so the repo truth is mixed rather than uniform.

At the same time, this is **not** ready for a design doc yet:

- only two real deployment shapes exist today: `proxmox-talos` and `mac-orbstack-single`
- there is no multi-customer or broader field-upgrade support burden yet
- forcing a hard support policy now would likely create process before we have enough runtime evidence to justify it

## Proposed approach (high-level)

Keep this as an idea until DeployKube has enough real upgrade surface to justify a product contract.

Likely eventual shape:

1. A repo-level upgrade support policy that defines:
   - supported release-to-release upgrade paths
   - supported proof environment(s)
   - what "rollback supported" means vs "roll-forward only"
2. Per-component upgrade metadata/runbooks that declare:
   - pre-checks
   - post-checks
   - validation commands
   - rollbackability class
3. A release-level runtime gate that proves:
   - previous supported release -> candidate release
   - curated post-upgrade smokes
   - optional restore canaries for risky stateful components

The likely long-term policy starting point is:

- support direct upgrade from the previous tagged release only
- prove it on Proxmox first
- keep fast CI structural, and keep real upgrade proof in self-hosted runtime gating

## What is already implemented (repo reality)

- Runtime release gate exists:
  - `scripts/release/release-gate.sh`
  - `docs/toils/release-e2e-gate.md`
- Release tagging is already gated on that runtime path:
  - `scripts/release/release-tag.sh`
- Release checklist already requires runtime gate evidence:
  - `docs/guides/release-checklist.md`
- At least one real tier-0 upgrade/rollback rehearsal now exists:
- Component-local upgrade gaps still exist in trackers such as:
  - `docs/component-issues/local-path-provisioner.md`
  - `docs/component-issues/powerdns.md`
  - `docs/component-issues/observability.md`

## What is missing / required to make this real

- A clear definition of "supported upgrade path" for tagged releases.
- A standard way to classify components:
  - rollback-supported
  - rollback-conditional
  - roll-forward-only
- A decision on whether every tagged release must prove `previous tag -> new tag`.
- A decision on whether proof initially covers only `proxmox-talos`, or also `mac-orbstack-single`.
- A structural CI contract that fails when shipped components do not declare upgrade metadata.
- A runtime workflow that can actually run upgrade-from-previous-tag proof, not only steady-state release smokes.
- A clear way to integrate this into the component-assessment framework once it becomes real, so upgrade support can be assessed as a first-class project-level/runtime-gating concern rather than only as ad hoc docs review.

## Risks / weaknesses

- **Too early**: formalizing this now could create process overhead before the supported deployment matrix is real.
- **False precision**: a support policy written before enough runtime rehearsal exists will likely overclaim.
- **Expensive gating**: full upgrade proof is a runtime concern and should not be forced into ordinary fast CI.
- **Component mismatch**: not every component should be held to the same rollback expectation, especially around CRDs and schema migrations.

## Alternatives considered

### Option A: Do nothing until real field deployments exist

- Pros: avoids premature process.
- Cons: easy to forget, and release gating may drift toward steady-state-only proof.

### Option B: Turn it into a design doc now

- Pros: more concrete.
- Cons: too early; the support surface is still too small and too hypothetical.

### Option C: Track as an idea now, promote only after more runtime evidence

- Pros: keeps the concept visible without freezing the wrong contract too early.
- Cons: does not immediately improve release safety on its own.

This is the right option for now.

## Open questions

1. Should the first supported rule be strictly `N-1 tag -> N tag`, with no skipped-release guarantee?
2. Is Proxmox the only required proof environment at first?
3. Should `mac-orbstack-single` be treated as a developer confidence path only, not a support path?
4. Which components are likely to be `roll-forward-only` because rollback after migrations is unsafe?
5. At what point does this become worth promoting:
   - second field deployment
   - first real customer deployment
   - or a broader release cadence where upgrade burden becomes recurring?

## Promotion criteria (to `docs/design/**`)

Promote this idea once all of the following are true:

- DeployKube has more than the current narrow deployment reality, or field-upgrade support becomes an explicit product concern.
- There is agreement on the first supported upgrade promise, for example `previous tag -> new tag`.
- There is at least one runtime workflow prototype that proves upgrade-from-previous-tag, not just steady-state release health.
- There is a concrete proposal for how component-level rollback classes will be declared and validated.
- There is a defined way to represent and assess this in the component-assessment framework, likely as a project-scoped runtime/release-gating concern plus component-local upgrade-contract checks.
- The repo can distinguish clearly between:
  - fast structural CI
  - runtime release gate
  - upgrade-proof gate
