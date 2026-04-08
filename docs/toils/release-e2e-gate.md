# Toil: Release E2E Gate (Proxmox cluster)

This repo uses **gated runtime E2E workflows** for checks that require a live cluster and may mutate the singleton `DeploymentConfig`.

The canonical “don’t forget before release” workflow is:
- GitHub Actions workflow: `.github/workflows/release-e2e-gate.yml` (manual dispatch)
- Local helper: `scripts/release/release-gate.sh` (recommended)

## Why this exists

- In-cluster smoke CronJobs provide continuous assurance, but they do not cover all mode permutations.
- Runtime mode-matrix runners (`tests/scripts/e2e-*-modes-matrix.sh`) **mutate** `DeploymentConfig` and must not run concurrently.
- Release E2E Gate runs the full certificate matrix, full IAM matrix, and curated release runtime smoke suite in one deterministic sequence.

## One-time setup (self-hosted runner)

You need a **self-hosted GitHub Actions runner** that can talk to your Proxmox cluster.

Recommended placement:
- A small VM on Proxmox, or
- A machine on the same LAN with stable access to the cluster API.

Requirements on the runner:
- `kubectl` installed
- Network reachability to the Kubernetes API server
- A kubeconfig file present on disk (do not store kubeconfig in GitHub secrets)

Recommended kubeconfig placement:
- Put the file at a stable path, for example `/home/runner/.kube/config-proxmox`.

Then set one of these repository variables:
- `DK_E2E_KUBECONFIG=/home/runner/.kube/config-proxmox` (preferred single knob)

Alternatives (legacy):
- `DK_CERT_E2E_KUBECONFIG=...`
- `DK_IAM_E2E_KUBECONFIG=...`

Finally, enable the gated E2E workflows:
- `DK_CERT_E2E_ENABLED=true` (repo var)
- `DK_IAM_E2E_ENABLED=true` (repo var)

## Running the gate (recommended)

From your workstation:

```bash./scripts/release/release-gate.sh --ref main
```

## Release tag enforcement (component assessment baselines)

Release tags should be created via `scripts/release/release-tag.sh`, which enforces that:
- Release E2E Gate passes for the target commit, and
- The component-assessment release baselines match the target commit (fingerprint checksum gate).

Baseline update flow:
- Recommended (one command; auto-regenerates + auto-commits baselines when needed):
  - `DK_ALLOW_MAIN_COMMIT=1 DK_ALLOW_MAIN_PUSH=1./scripts/release/release-tag.sh --tag v0.1.0 --ref main --auto-commit-baselines yes`
- Manual (if you want to inspect/commit baselines explicitly):
  - `./scripts/release/component-assessment-release-baseline.sh --ref main`
  - `git add docs/evidence/component-assessment/release-baseline/fingerprints-*.tsv docs/evidence/component-assessment/release-baseline/metadata.md`
  - `git commit -m "release: update component-assessment release baselines"`
  - `./tests/scripts/validate-component-assessment-release-baseline.sh --ref main`
  - `./scripts/release/release-tag.sh --tag v0.1.0 --ref main`

Important notes:
- Updating baselines does NOT run any LLM evaluation; it is a fingerprint-only snapshot used to gate tagging on repo state.
- Breakglass for tagging from a dirty worktree exists, but must be explicit:
  - `DK_ALLOW_DIRTY_RELEASE_TAG=1./scripts/release/release-tag.sh --tag v0.1.0 --allow-dirty yes`

Optional: point workflow at a specific kubeconfig path on the runner:

```bash./scripts/release/release-gate.sh \
  --ref main \
  --kubeconfig-path /home/runner/.kube/config-proxmox
```

Optional: choose smoke profile and include restore canary:

```bash./scripts/release/release-gate.sh \
  --ref main \
  --smoke-profile full \
  --include-restore-canary no
```

## What runs

The gate runs:

1) Certificates mode matrix (full):
- `tests/scripts/e2e-cert-modes-matrix.sh` (`subCa,acme,wildcard`)

2) IAM mode matrix (full):
- `tests/scripts/e2e-iam-modes-matrix.sh` (`profile=full`)

3) Curated release runtime smokes:
- `tests/scripts/e2e-release-runtime-smokes.sh` (`profile=quick|full`)
- Full profile is the release default.
- Restore canary remains opt-in via `include_restore_canary=yes`.

Concurrency protection:
- All runtime E2E workflows share `concurrency.group=deploykube-runtime-e2e` to prevent parallel DeploymentConfig mutations.

## Expected outcome

- Workflow run finishes green.
- If it fails, inspect the workflow logs first; the scripts print `kubectl describe` and job logs on failures.
