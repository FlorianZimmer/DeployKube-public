# DeployKube scripts (user entrypoints)

## Public Mirror Notice

This document is included in the sanitized public mirror so the bootstrap and operator-facing script surface stays visible.

- Treat the scripts and commands here as representative implementation material, not a turnkey public installation guide.
- Some environment-specific inputs, credentials, and operational dependencies were intentionally removed or replaced.

If you are looking for the operator-facing script surface in the private working repo, this directory is where it lives.

`scripts/` contains *thin wrappers* around the implementation helpers in `shared/scripts/`. The goal is to keep the
operator-facing surface area small and obvious.

Bootstrap playbook (Mac + Proxmox, includes the deployment contracts + DSB workflow):
- `docs/guides/bootstrap-new-cluster.md`

## Deploy (macOS + OrbStack)

- **Fast path (recommended):** single-worker kind + single-node GitOps bundle (reuse existing Vault data)
  - `./scripts/bootstrap-mac-orbstack-single-preserve.sh`
- **Clean bootstrap (single-node / lowest memory):**
  - `./scripts/bootstrap-mac-orbstack-single-clean.sh`

> **Note:** You can choose the GitOps environment bundle via `ARGO_APP_PATH`:
> - `apps/environments/mac-orbstack-single` (dev, single-node / lowest memory)
>
> `*-preserve` assumes Vault has been initialized before (bootstrap sentinel exists). For a fresh cluster, run a `*-clean` bootstrap once or run `./shared/scripts/init-vault-secrets.sh`.
>
> **Important (what “preserve” actually preserves):**
> - `bootstrap-*-preserve.sh` is primarily about **Vault** (it skips Vault init/wipe/reseed). It does **not** guarantee workload data is preserved.
> - In the **single-node local-path profile** (`mac-orbstack-single`), PVCs are node-local `hostPath` inside the kind node. Deleting the kind cluster wipes that data regardless of “preserve”.
>
> Troubleshooting:
> - If `kind create cluster` fails with `node(s) already exist`, you likely have stale kind node containers; re-run the bootstrap after `./scripts/teardown-mac-orbstack-preserve.sh` (or `kind delete cluster --name deploykube-dev`).
> - If `kubectl --context kind-deploykube-dev...` returns `connection refused`, re-run the bootstrap (Stage 0 re-exports kubeconfig from the live kind cluster to refresh the localhost API port mapping).
> - The bootstrap also writes a repo-local kubeconfig at `tmp/kubeconfig-dev` (useful if your `KUBECONFIG` env var points elsewhere).
> - First-time (cold-cache) dev bootstraps can be slow because Vault/Keycloak/Argo images are large; the single-node *clean* bootstrap enables registry cache warming by default. If you don’t have `skopeo` installed, it will log a warning and continue.

## Deploy (Proxmox + Talos)

- `./scripts/bootstrap-proxmox-talos.sh`
  - Reads inputs from `bootstrap/proxmox-talos/`
  - The private working repo includes additional out-of-band recovery and custody steps for production bootstrap; those details are intentionally omitted from this public mirror.

### Advanced (run stages manually)

Stage 0/Stage 1 are intentionally *not* exposed as operator entrypoints.
If you are changing bootstrap logic and need to run them directly, use:

- Stage 0: `shared/scripts/bootstrap-mac-orbstack-stage0.sh`
- Stage 1: `shared/scripts/bootstrap-mac-orbstack-stage1.sh`

## Teardown (macOS + OrbStack)

- **Preserve data (recommended for iteration):** `./scripts/teardown-mac-orbstack-preserve.sh`
- **Wipe data (full reset):** `./scripts/teardown-mac-orbstack-wipe.sh`

## Notes

- The implementation lives in `shared/scripts/`. If you are editing bootstrap logic, start there.
- The OrbStack NFS host helper is internal (Stage 0 starts it). For troubleshooting, use `shared/scripts/orb-nfs-host.sh`.

## Dev maintenance helpers

- Self-improvement skill wrappers (stable entrypoints; auto-resolve newest installed `~/.codex/skills/self-improving-agent-*` version):
  - `./scripts/dev/self-improvement-activator.sh`
  - `./scripts/dev/self-improvement-error-detector.sh --exit-code <code> --command "<command>" [--output "<text>" | --output-file <path>]`
  - Note: detector output is signal-based; a passing syntax/lint/render check is not proof of runtime correctness.
- Distill learning backlog (`.learnings/ERRORS.md`, `.learnings/LEARNINGS.md`) into actionable promotion/resolve candidates:
  - `./scripts/dev/learnings-distill.sh` (compact, token-efficient default)
  - `./scripts/dev/learnings-distill.sh --human`
  - `./scripts/dev/learnings-distill.sh --verbose`
  - `./scripts/dev/learnings-distill.sh --check` (non-zero when stale pending entries exist)
  - `./scripts/dev/learnings-distill.sh --write-report docs/evidence/YYYY-MM-DD-learnings-distill.md`
- Component-assessment framework helpers:
  - Validate assessment catalog: `./scripts/dev/component-assessment-catalog-check.sh`
  - Generate per-component workpacks (all templates + scoped context manifests): `./scripts/dev/component-assessment-workpack.sh --all`
  - Runbook: `docs/ai/prompt-templates/component-assessment/execution-framework.md`
  - Render an LLM-deduped Open backlog snippet from promoted findings: `./scripts/dev/component-assessment-render-open.sh --run-dir <tmp/component-assessment/...>`
  - End-to-end (assess + promote + render Open): `./scripts/dev/component-assessment-codex-exec.sh --mode changed`
- Version-bump proposal helpers:
  - Render grouped version reports from the curated catalog: `./scripts/dev/version-bump-proposal.sh`
  - Validate curated catalog coverage against the component catalog + issue trackers: `./tests/scripts/validate-version-lock.sh`, `./tests/scripts/validate-version-lock-component-coverage.sh`
  - Runbook: `docs/toils/version-bump-proposals.md`

## Restore entrypoint (DR)

- Single-command restore orchestration (GitOps-safe baseline for currently implemented tiers: Vault + Postgres + S3 mirror):
  - `./scripts/ops/restore-from-backup.sh`
- Cert-manager Step CA trust regeneration drill (safe scratch mode by default; optional live replacement mode with explicit ack):
  - `./scripts/ops/cert-manager-restore-drill.sh`
- PVC restic password lifecycle (two-phase key rotation: `prepare`/`promote`):
  - `./scripts/ops/rotate-pvc-restic-password.sh`
- PVC restic repository permission migration for non-root backup/smoke jobs:
  - `./scripts/ops/migrate-pvc-restic-repo-permissions.sh`
- Sync offline breakglass kubeconfig into the operator-managed backup Secret used for encrypted recovery bundles:
  - `./scripts/ops/sync-breakglass-kubeconfig-to-backup.sh --deployment-id proxmox-talos --source-kubeconfig <path> --confirm-in-cluster-copy yes`
- Runbook:
  - `docs/guides/restore-from-backup.md`
  - `docs/guides/backups-and-dr.md` (restic lifecycle section)
  - `docs/toils/cert-manager-restore-drill.md`

## Deployment Secrets Bundle (DSB)

Deployment-scoped bootstrap secrets (SOPS) live under:
- `platform/gitops/deployments/<deploymentId>/secrets/`

Helpers:
- Scaffold a new deployment (config + DSB placeholders + age key): `./scripts/deployments/scaffold.sh`
- Keep the DSB ConfigMap file list in sync with `secrets/`: `./scripts/deployments/bundle-sync.sh`
- Rotate SOPS Age recipients (two-phase): `./scripts/deployments/rotate-sops.sh`
- Record SOPS Age key custody acknowledgement (prod Stage 1 gate): `./shared/scripts/sops-age-key-custody-ack.sh`

Related docs:
- `docs/design/deployment-secrets-bundle.md`
- `docs/guides/bootstrap-new-cluster.md`
- `docs/guides/sops-age-on-macos.md`
- `docs/toils/sops-age-key-rotation.md`
- `docs/toils/sops-age-key-custody.md`

## DeploymentConfig-derived controllers (no repo-side renderers)

DeployKube’s deployment identity inputs live under `platform/gitops/deployments/<deploymentId>/config.yaml` (and are also published into-cluster as a snapshot ConfigMap).

As of 2026-01-29, the following DeploymentConfig-derived outputs are controller-owned (tenant provisioner), not repo-rendered overlays:
- DNS wiring (PowerDNS/CoreDNS/external-sync): `docs/evidence/2026-01-29-dns-wiring-controller-cutover.md`
- Platform ingress Certificates: `docs/evidence/2026-01-29-platform-ingress-certificates-controller-cutover.md`
- Tenant egress proxy: `docs/evidence/2026-01-29-tenant-provisioner-renderer-retirement-scaffold.md`

## Opt-in example apps (Minecraft + Factorio)

Example apps are intentionally **not** part of the default platform core bundle (see `docs/design/cloud-productization-roadmap.md`).

Enable them via the opt-in Argo bundle:
- `platform/gitops/apps/opt-in/examples-apps/README.md`

## Opt-in proof-of-concepts

Proof-of-concepts are intentionally kept out of the default platform bundle and out of distribution defaults.

Current deployable PoC:
- IdP identity lab: `platform/gitops/apps/opt-in/idlab-poc/README.md`
