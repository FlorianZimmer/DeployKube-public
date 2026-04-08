# Mac + OrbStack Implementation Guide

Bootstrap playbook (recommended entrypoint for operators):
- `docs/guides/bootstrap-new-cluster.md`

This guide captures the *implementation details* of the macOS + OrbStack + kind target. Operator-facing bootstrap steps live in `docs/guides/bootstrap-new-cluster.md`.

## Scope & assumptions
- macOS 13+ with admin privileges.
- OrbStack provides the Docker runtime; `kind` supplies the Kubernetes control plane.
- The goal is a reproducible, GitOps-driven path that later extends to Proxmox/bare metal with minimal divergence.
- Core control-plane components (Step CA, cert-manager, Vault, Keycloak, Forgejo, Argo CD, DNS, etc.) are owned declaratively through `platform/gitops/`. Operations that still run outside of Argo (host NFS bootstrap, Stage 0/1 orchestration) remain in `shared/scripts/` (operator entrypoints are under `scripts/`).

## Prerequisites
1. **macOS tooling**
   - Install Xcode Command Line Tools: `xcode-select --install`.
   - Install Homebrew if missing: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`.
   - Confirm `xcode-select -p` and `brew doctor` report success.
2. **OrbStack & Docker**
   - `brew install --cask orbstack`.
   - Launch OrbStack, grant required permissions, and keep the Docker socket integration enabled.
   - Run `orb version` / `orb status` to verify readiness.
3. **CLI toolchain**
   - Install the control-plane tools: `brew install kind kubectl helm cilium-cli istioctl step argocd` (pin versions as documented in `target-stack.md`).
   - Install the deployment contract + DSB helpers: `brew install yq sops age` (and ensure `age-keygen` is in `PATH`).
   - Confirm each binary responds to `--version`.
4. **Repository**
   - `git clone` the DeployKube repo and stay on the `main` branch, then review `README.md`, `agents.md`, and `docs/design/gitops-operating-model.md` for context.
5. **Docker context**
   - `eval "$(orb docker-env)"` (persist in your shell profile).  
   - Optional fallback: `export DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock`.
   - Validate the Docker context: `docker info | grep -i orbstack`.

## Bootstrap orchestration

For end-to-end operator steps (contracts, DSB, and bootstrap commands), use:
- `docs/guides/bootstrap-new-cluster.md`

This section is the “how it works under the hood” view and is intentionally more verbose.

1. **NFS host helper**
   - In the single-node local-path profile (`apps/environments/mac-orbstack-single`), Stage 0 intentionally skips the NFS host and `shared-rwo` is backed by node-local `local-path-provisioner` instead (`docs/design/storage-single-node.md`).
2. **Stage 0 & Stage 1**
   - Stage 0 (`shared/scripts/bootstrap-mac-orbstack-stage0.sh`) sets up the kind cluster, shared storage, and any prerequisites (storage classes, operator CRDs, etc.) using the inputs under `bootstrap/mac-orbstack/`.
  - Stage 0 starts local registries (`shared/scripts/local-registry-cache.sh`): pull-through caches for `docker.io`, `quay.io`, `registry.k8s.io`, `cr.smallstep.com`, `codeberg.org`, `code.forgejo.org`, and a mirror registry for `registry.example.internal`. Disable with `LOCAL_REGISTRY_CACHE_ENABLE=0`.
   - To pre-seed all images referenced in the repo, set `LOCAL_REGISTRY_WARM_IMAGES=1` before running Stage 0; it will invoke `shared/scripts/registry-sync.sh` to discover images from `platform/`, `shared/`, `bootstrap/`, `scripts/` and (by default) render the bootstrap Helm charts via `helm template` to warm chart-derived images too. Use `REGISTRY_SYNC_HELM_RENDER=0` to disable Helm discovery; override scan roots with `REGISTRY_SYNC_SCAN_DIRS` and add extras via `REGISTRY_SYNC_EXTRA_IMAGES`.
   - Stage 1 (`shared/scripts/bootstrap-mac-orbstack-stage1.sh`) seeds Forgejo/Argo and applies the gitops root repo (bootstrap values in `bootstrap/mac-orbstack/`).
     - In the private working repo, Stage 1 also wires deployment-scoped bootstrap secrets needed by DSB consumers. The exact secret material and key-custody flow are intentionally omitted from this public mirror.
   - Run the orchestrator wrappers instead of invoking Stage scripts manually:
     * `scripts/bootstrap-mac-orbstack-single-clean.sh` runs the same flow but selects the single-node GitOps bundle (`apps/environments/mac-orbstack-single`) and the single-node storage profile (`DEPLOYKUBE_STORAGE_PROFILE=local-path`).
     * `scripts/bootstrap-mac-orbstack-single-preserve.sh` is the single-node equivalent of preserve mode (Vault-focused; it does not preserve PVC data across kind cluster deletion).
   - The legacy `shared/scripts/bootstrap-mac-orbstack.sh` has been removed; use Stage 0/Stage 1 + wrappers exclusively.
3. **Bootstrap logs & evidence**
   - Run the orchestrator helpers with logging (e.g., append `| tee /tmp/deploykube-bootstrap-$(date +%s).log`) and capture the log path.
   - Record the exact command, key outputs (e.g., Vault init success, Argo sync status), and where the log lives in your notes before updating docs.
   - When bootstrap behaviour changes, note that explicitly in your docs/PR so reviewers know future bootstraps might differ.
4. **When to rerun full bootstrap**
   - Only touch Stage 0/Stage 1 when GitOps proves insufficient (e.g., new host prep logic or Vault init changes). For most component work, rely on Argo syncs/applying manifests directly.
   - The engineering team runs wipe + restore manually after gitops changes; agents should focus on ensuring the manifests/jobs are correct and declare success via Argo + smoke tests.

## GitOps workstream (post-migration)
1. **GitOps repo layout**
   - `platform/gitops/apps/` hosts the Argo CD app-of-apps definitions (base plus per-environment bundles).  
   - `platform/gitops/components/` contains each managed service (networking, secrets, certificates, storage, etc.) with its own Helm/Kustomize overlay, bootstrap jobs, and secrets.
   - `platform/gitops/deployments/` contains the central per-deployment contracts:
     - `deployments/<deploymentId>/config.yaml` (DeploymentConfig / identity)
     - deployment-scoped secret bundles exist in the private working repo but are intentionally omitted from this public mirror
   - Component directories must include a `README.md` describing purpose, architecture, HA posture, TLS, and operational runbooks. Track open work under `docs/component-issues/<component>.md` (keep TODO lists out of component READMEs).
   - The private working repo uses an internal upstream remote for day-to-day work; Forgejo only mirrors the `platform/gitops/` subtree.
   - New features (e.g., Grafana/observability) and fixes should land directly in GitOps; run Stage 0/Stage 1 only when bootstrap logic changes.
2. **Seeding Forgejo**
   - Stage 1 snapshots the current `platform/gitops/` tree (from the DeployKube git `HEAD`) into Forgejo via `shared/scripts/forgejo-seed-repo.sh` (port-forward + force-push). It does not rewrite any local git remotes.
   - When running the helper manually, keep your workstation pointed at the GitHub remote for the full repo and import `shared/certs/deploykube-root-ca.crt` into your trust store so HTTPS calls to `https://forgejo.dev.internal.example.com` (or `https://forgejo.dev-single.internal.example.com` for `mac-orbstack-single`) succeed.
   - Once the root reports `Synced/Healthy`, individual component Applications should succeed in the same manner.
3. **Testing & validation**
   - Ensure component-specific smoke tests (documented in the component README) run successfully, ideally invoked via `just`/`go test` commands that Stage 1 or follow-on jobs can trigger.
   - Capture smoke test output/logs and link them to the GitOps evidence discipline.
   - Success is defined by Argo reporting `Synced/Healthy` for the affected Applications and the smoke tests passing; only rerun Stage 0/Stage 1 when bootstrap logic changes.

## Component readiness & documentation
- Treat `docs/design/gitops-operating-model.md` as the repo-level operating model; component sequencing and prerequisites live in the component READMEs and Argo sync waves.
- Maintain `docs/component-issues/<component>.md` for open HA/security tasks linked from the component README.
- Observability is GitOps-managed; see `platform/gitops/components/platform/observability/README.md` for the current stack and access/runbooks.

## Operations & teardown
- Use `scripts/teardown-mac-orbstack-preserve.sh` for fast iteration and `scripts/teardown-mac-orbstack-wipe.sh` when storage/state must be rebuilt from scratch.
- In the single-node local-path profile (`apps/environments/mac-orbstack-single`), PVCs are node-local `hostPath` inside the kind node; deleting the kind cluster wipes that data regardless of teardown “preserve”.
- Respect storage cleanup instructions: drain/delete pods before rerunning Stage 0 if shared PVCs remain bound.
- Keep the bootstrap helpers idempotent so Argo can reapply Applications without intervention; guard duplicates with checks in scripts when necessary.
- When troubleshooting manifests/jobs, collect `kubectl logs`, `kubectl describe`, `argo app diff/status`, and record the suspected root cause in the relevant component issue log before pushing any code changes.

## Notes
- Continue to document smoke tests and access instructions for new components in their README and link back to this guide where helpful.
- Avoid Bitnami images; prefer CloudNativePG for PostgreSQL and Valkey for Redis-compatible workloads unless a documented exception exists.
- Keep secrets encrypted (Vault/SOPS) and verify Helm/OCI artefacts whenever possible; record pinned versions/digests in the design notes.

## Demo apps (Factorio/Minecraft) are opt-in

The default platform core bundle does not include demo apps.

Enable them via:
- `platform/gitops/apps/opt-in/examples-apps/README.md`
