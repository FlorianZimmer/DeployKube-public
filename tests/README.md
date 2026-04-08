# Tests / Validation Scripts

This repo’s “validation scripts” live under `tests/scripts/` and are intended to be **repo-only** checks (no live cluster access) that CI can run on every PR.

## Run locally

- Run the default CI suite: `./tests/scripts/ci.sh`
- Run a specific suite:
  - Deployment contracts: `./tests/scripts/ci.sh deployment-contracts`
  - Validation-jobs doctrine: `./tests/scripts/ci.sh validation-jobs`

Notes:
- Some checks render Helm charts via Kustomize and require **Helm v3** (CI installs it). If you have Helm v4 locally, set `HELM_BIN` to a Helm v3 binary.
- Deployment-contracts suite includes `./scripts/dev/learnings-distill.sh --check` to fail CI when `.learnings/` has stale pending entries.

## CI wiring

GitHub Actions workflows should call the suite runner (not individual scripts):

- `.github/workflows/deployment-contracts.yml` → `./tests/scripts/ci.sh deployment-contracts`
- `.github/workflows/validation-jobs.yml` → `./tests/scripts/ci.sh validation-jobs`

`tests/scripts/ci.sh` is the source of truth for what each suite executes.

## Adding new validation scripts (rules)

1. Keep the script standalone and directly runnable (shebang + executable bit).
2. Make it deterministic and repo-only (avoid kubectl/argocd/live cluster state unless explicitly part of a suite).
3. Fail fast with a non-zero exit code and actionable output.
4. Add it to the right suite in `tests/scripts/ci.sh` (this is what CI runs).
