# Version bump automation issues

Tracks Renovate-backed proposal automation for curated version bumps in DeployKube.

Design:
- `docs/design/renovate-version-bump-proposals.md`
- `docs/design/supply-chain-pinning-policy.md`
- `docs/toils/version-bump-proposals.md`

## Open

- Add a constrained Renovate configuration in PR-only mode, scoped only to components already covered by `versions.lock.yaml`.
- Define the initial manager allowlist:
  - native managers for supported Helm/image surfaces
  - regex/custom managers only for stable curated pin sites
  - no free-range matching across docs or vendored/generated artefacts
- Decide and implement the `target-stack.md` sync path.
  - Recommended direction from `docs/design/renovate-version-bump-proposals.md`: use a repo-owned sync helper instead of direct bot edits to prose-heavy docs.
- Encode bump-class routing and cadence:
  - class labels and reviewer routing
  - separate treatment for patch/minor vs major bumps
  - conservative rate limits for `bootstrap-core` and `tier0-security`
- Prove the first rollout on one lower-risk class before enabling trust-plane or bootstrap-heavy components.
- Ensure Renovate PRs make missing follow-up work obvious when a bump still needs vendoring, committed render refresh, signed-chart verification, runtime evidence, or other repo-owned steps.

## Resolved

- **2026-03-09 – Repo policy clarified:** `versions.lock.yaml` remains the curated source of truth, `validate-version-lock-component-coverage.sh` keeps uncovered components explicitly tracked in their own component issue files, and Renovate is scoped as an optional proposal engine rather than a replacement for repo-owned validation and runtime gates.
