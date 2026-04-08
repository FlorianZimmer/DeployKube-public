# Guide: Release checklist (homelab model)

This repo does not ship a full semantic-versioned release pipeline yet. Instead, “release” means promoting a specific Git commit/tag to your Proxmox (prod-like) cluster with evidence.

This checklist exists to prevent skipping the required runtime E2E gates.

## Required steps

1) Ensure the candidate revision is merged and pushed.

2) Run repo-local CI suites (fast):
- `./tests/scripts/ci.sh all`

3) Component-assessment baseline gate (checksum gate for tagging):
- `./scripts/release/release-tag.sh` validates baselines automatically.
- Note: updating baselines does NOT run any LLM evaluation; it is a fingerprint-only snapshot. This means you can fix findings and still tag without re-running the full component assessment (as long as you update baselines for the new commit).
- If baselines are missing/stale, you can either:
  - Manual regen + commit:
    - `./scripts/release/component-assessment-release-baseline.sh --ref main`
    - `git add docs/evidence/component-assessment/release-baseline/fingerprints-*.tsv docs/evidence/component-assessment/release-baseline/metadata.md`
    - `git commit -m "release: update component-assessment release baselines"`
    - `./tests/scripts/validate-component-assessment-release-baseline.sh --ref main`
  - One command (auto-regenerate + auto-commit when needed):
    - `DK_ALLOW_MAIN_COMMIT=1 DK_ALLOW_MAIN_PUSH=1./scripts/release/release-tag.sh --tag v0.1.0 --ref main --auto-commit-baselines yes`

4) Run Release E2E Gate (runtime, Proxmox cluster):
- Runbook: `docs/toils/release-e2e-gate.md`
- Command:
  - `./scripts/release/release-gate.sh --ref main --smoke-profile full`

Optional:
- Include backup restore canary in the gate run:
  - `./scripts/release/release-gate.sh --ref main --smoke-profile full --include-restore-canary yes`

5) Capture evidence:
- `docs/evidence/YYYY-MM-DD-<release-topic>.md`
- Include: git SHA, Argo `Synced/Healthy` for core apps, and the workflow run link/id for the Release E2E Gate.

6) Create and push the release tag (gated):
- Tag naming policy: SemVer with a leading `v` (examples: `v0.1.0`, `v1.2.3-rc.1`).
- `./scripts/release/release-tag.sh --tag v0.1.0 --ref main`

## Notes

- Release E2E Gate runs on a self-hosted runner and is concurrency-locked to prevent concurrent `DeploymentConfig` mutations.
- If the gate fails, fix the regression and rerun the gate on the new candidate commit.
