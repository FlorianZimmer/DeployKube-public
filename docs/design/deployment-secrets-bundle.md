# Design: Deployment Secrets Bundle (SOPS Bootstrap Material)

Last updated: 2025-12-30  
Status: Implemented (v1)

Note (implemented / evolving):
- The DSB file set depends on `spec.secrets.rootOfTrust` in the deployment config contract:
  - `provider=kmsShim`: requires `kms-shim-*` secrets; the exact set depends on `mode=inCluster|external`.
  - See `docs/design/openbao-secret-plane-kms-shim.md`.
- In a future PKCS#11-backed seal provider mode, the seal key should live inside the HSM (so `kms-shim-key.secret.sops.yaml` should not exist; bootstrap becomes config + client auth).

## Tracking

- Canonical tracker: `docs/component-issues/deployment-secrets-bundle.md`

## Purpose

The deployment config contract (`docs/design/deployment-config-contract.md`) makes “deployment identity” easy to define and validate for new clusters. However, **bootstrap secrets** still require SOPS-encrypted files that are currently:

- **scattered across component directories**, and
- encrypted to a **single global Age recipient** (`.sops.yaml` at repo root).

This design introduces a **Deployment Secrets Bundle (DSB)** that:

- is **deployment-scoped** (one bundle per deployment),
- is compatible with GitOps mirroring (`platform/gitops/**` → Forgejo snapshot),
- makes **new deployment** setup and **rotation** low-toil and hard to get wrong, and
- cleanly aligns with the long-term direction (Cloud Productization Roadmap + “single YAML provisioner”) by making the “bootstrap trust chain” explicit and contract-driven.

Related docs:
- Deployment identity/config contract: `docs/design/deployment-config-contract.md`
- GitOps operating model: `docs/design/gitops-operating-model.md`
- Cloud Productization Roadmap: `docs/design/cloud-productization-roadmap.md`
- Long-term provisioning direction (“single YAML”): `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`

## Scope / ground truth

Repo-only scope (no live cluster assumptions):

- GitOps: `platform/gitops/**`
- Bootstrap/scripts: `scripts/**`, `shared/scripts/**`, `bootstrap/**`
- Docs: `docs/**`, `target-stack.md`

## Current State (repo reality)

### SOPS configuration and key usage

- Bootstrap SOPS material is now deployment-scoped under `platform/gitops/deployments/<deploymentId>/secrets/`.
- Each deployment declares its own recipients under `platform/gitops/deployments/<deploymentId>/.sops.yaml`.
- Stage 1 scripts load the operator’s Age key into the cluster as `argocd/argocd-sops-age` (and **fail fast** if the key is missing; no silent key generation):
  - `shared/scripts/bootstrap-mac-orbstack-stage1.sh`
  - `shared/scripts/bootstrap-proxmox-talos-stage1.sh`

### Where bootstrap SOPS files live now (DSB)

Bootstrap-critical SOPS files are stored under deployment directories:

- Vault/OpenBao init + seal provider secrets: `platform/gitops/deployments/<deploymentId>/secrets/*.secret.sops.yaml`
- Step CA seed bundle: `platform/gitops/deployments/<deploymentId>/secrets/step-ca-vault-seed.secret.sops.yaml`

These are **deployment-scoped by nature** (they should differ per deployment). The v1 implementation still supports a migration window where multiple deployments may temporarily share the same Age recipient, but the filesystem layout is now deployment-scoped.

## Problem statement

As we add more deployments (new clusters) using the deployment config contract patterns, we currently lack a contract-aligned way to:

1) **Guarantee the required SOPS files exist** for a new deployment (so GitOps renders cleanly and bootstrap Jobs can run).

2) **Guarantee the files are encrypted to the correct key(s)** for that deployment (avoiding “wrong key” failures).

3) Provide a **simple, repeatable rotation story** for:
   - the **Age recipients** used for SOPS encryption, and
   - the **underlying bootstrap secret material** (e.g., Vault init + kms-shim token/key, Step CA seed material).

4) Keep the system compatible with the repo’s operating model:
   - Stage 0/1 are small and should not grow into bespoke provisioning systems.
   - Everything after bootstrap converges via Argo CD from `platform/gitops/**`.

## Goals

- **Per-deployment secret scoping**: bootstrap SOPS material is stored under the deployment root (`platform/gitops/deployments/<deploymentId>/…`).
- **A single “make a new deployment ready” workflow** for deployment personnel:
  - scaffold deployment config + secrets bundle,
  - generate/store the Age key with custody discipline,
  - populate bootstrap secrets via a deterministic helper.
- **Rotation that is safe and obvious**:
  - rotate Age recipients without downtime (two-phase),
  - rotate bootstrap secret values with documented procedures and evidence.
- **Contract compatibility**:
  - no secrets in the deployment config contract itself,
  - but the “secrets bundle” exists as a contract-adjacent, validated artifact under the same deployment root.
- **Roadmap alignment**:
  - make the “bootstrap trust chain” explicit and automatable, so future “single YAML” provisioning can own it without changing conventions.

## Non-goals

- Replace Vault/ESO with SOPS for steady-state secrets (Vault remains the default; SOPS is bootstrap-only).
- Implement a provisioning controller/CRDs (this is a filesystem + workflow contract that a future controller can adopt).
- Solve tenant-scoped secrets (tenant onboarding is a separate contract; see `docs/design/multitenancy-secrets-and-vault.md`).

## Decisions (v1)

These decisions are made to keep v1 low-complexity and aligned with current repo posture.

- **Age recipients live only in `deployments/<id>/.sops.yaml`** (not in `DeploymentConfig`):
  - `config.yaml` remains a plaintext identity/topology contract.
  - `.sops.yaml` remains the cryptographic access control mechanism.
  - Avoids drift/mismatch between “declared recipients” and “actual recipients”.
- **Start with 1 Age keypair per deployment**:
  - Simple 1:1 mapping (`deploymentId → Age key`) is sufficient for current operations.
  - Rotation (two-phase, §6.1) is the escape hatch when operators change or keys must be replaced.
  - This implies the v1 key is **team-shared** (not per-operator). Operator offboarding therefore requires a key rotation.
- **Keep Step CA seed material SOPS-in-Git for now**:
  - Maintains the current “Git as SSOT (encrypted)” posture and keeps this change bounded.
  - A future “Step CA hardening” phase may move to “generate → Vault SSOT → backup Vault”, but that is a larger architectural shift.
- **Filename convention**: bootstrap secret manifests must use `*.secret.sops.yaml` under the deployment bundle.

## Proposed design

### 1) Deployment Secrets Bundle (DSB) layout

For each deployment, extend the existing deployment directory:

```
platform/gitops/deployments/<deploymentId>/
  config.yaml               # DeploymentConfig (plaintext, versioned contract).sops.yaml                # SOPS creation rules for this deployment (recipients only; not secret)
  secrets/                  # SOPS-encrypted bootstrap-only Kubernetes Secret manifests
    vault-init.secret.sops.yaml

    # Seal provider secrets:
    # provider=kmsShim (mode=inCluster)
    kms-shim-key.secret.sops.yaml
    kms-shim-token.vault-seal-system.secret.sops.yaml
    kms-shim-token.vault-system.secret.sops.yaml
    # provider=kmsShim (mode=external)
    #   - kms-shim-token.vault-system.secret.sops.yaml (required; bootstrap injects the external address at apply time)

    step-ca-vault-seed.secret.sops.yaml
    # Optional per deployment (only if the platform bundle includes those apps):
    minecraft-monifactory-seed.secret.sops.yaml
```

Design intent:
- The **deployment directory becomes the single place** where deployment-scoped inputs live (identity + bootstrap secrets).
- Component directories remain reusable and mostly deployment-agnostic.

Required bundle files (v1):

Always:
- `vault-init.secret.sops.yaml`
- `step-ca-vault-seed.secret.sops.yaml`

Seal provider set:
- If `spec.secrets.rootOfTrust.provider=kmsShim` and `mode=inCluster`:
  - `kms-shim-key.secret.sops.yaml`
  - `kms-shim-token.vault-seal-system.secret.sops.yaml`
  - `kms-shim-token.vault-system.secret.sops.yaml`
- If `spec.secrets.rootOfTrust.provider=kmsShim` and `mode=external`:
  - `kms-shim-token.vault-system.secret.sops.yaml`

Optional bundle files (v1):

- `minecraft-monifactory-seed.secret.sops.yaml` (only if the Minecraft app/seed is shipped in this deployment)

Consumption map (v1):

| File | Primary consumer | Output / target |
|------|------------------|-----------------|
| `vault-init.secret.sops.yaml` | `secrets-bootstrap` Job | Creates `Secret/vault-system/vault-init` |
| `kms-shim-key.secret.sops.yaml` | `secrets-bootstrap` Job | Creates `Secret/vault-seal-system/kms-shim-key` (kmsShim inCluster only) |
| `kms-shim-token.vault-seal-system.secret.sops.yaml` | `secrets-bootstrap` Job | Creates `Secret/vault-seal-system/kms-shim-token` (kmsShim inCluster only) |
| `kms-shim-token.vault-system.secret.sops.yaml` | `secrets-bootstrap` Job | Creates `Secret/vault-system/kms-shim-token` (kmsShim provider; external mode also injects address at apply time) |
| `step-ca-vault-seed.secret.sops.yaml` | `certificates-step-ca-seed` Job | Seeds Step CA material into Vault (KV writes) |
| `minecraft-monifactory-seed.secret.sops.yaml` | `secrets-bootstrap` Job | Creates `Secret/vault-system/minecraft-monifactory-seed` (optional) |

### 2) SOPS configuration per deployment (recipients)

Each deployment directory includes its own `.sops.yaml` containing:

- a `creation_rules` section scoping encryption to `secrets/*.secret.sops.yaml` under that deployment, and
- a single **Age recipient** as the steady-state default (v1; temporarily multiple during rotation).

This is intentionally compatible with future fleet use:
- Deployments can use different recipients.
- Rotations become per-deployment operations.

Operator guidance:
- Prefer the repo helper scripts for all SOPS operations (create/rotate/refresh) so the correct config is always used.
- Repo lint/CI (see §7) enforces “wrong key” detection as the safety net for any manual edits.

Hard rule (v1): SOPS invocation style is standardized for deployment bundles.

- All repo scripts that run `sops` must:
  1. `cd platform/gitops/deployments/<deploymentId>`, and then
  2. run `SOPS_CONFIG=.sops.yaml sops … secrets/<filename>.secret.sops.yaml` (example: `sops -d secrets/vault-init.secret.sops.yaml`).

Note: v1 uses `path_regex` that also matches absolute paths (`(^|.*/)secrets/...`) to avoid toolchain differences across environments.

If you must run SOPS from a different working directory, explicitly set:
- `SOPS_CONFIG="${REPO_ROOT}/platform/gitops/deployments/<deploymentId>/.sops.yaml"`, and
- use repo-root-relative paths for files (e.g., `platform/gitops/deployments/<deploymentId>/secrets/vault-init.secret.sops.yaml`),
so the same config and regex rules apply.

### 2.1 Stage 1 Age key discovery (contract)

Stage 1 must create/refresh the in-cluster Secret `argocd/argocd-sops-age` from a **deployment-scoped Age private key** on the operator machine.

Key lookup rules (v1):

1. If `SOPS_AGE_KEY_FILE` is set, use it.
2. Else if `DEPLOYKUBE_DEPLOYMENT_ID` is set and the deployment-scoped default exists, use:
   - `~/.config/deploykube/deployments/<deploymentId>/sops/age.key`
3. Else fallback (legacy compatibility during migration):
   - `~/.config/sops/age/keys.txt`

Notes:
- The key file is an “age identities” file. It may contain **multiple private keys** during a rotation window by concatenating identities (this enables the two-phase rotation in §6.1).
- The `scripts/deployments/scaffold.sh` helper is responsible for creating the default deployment key path (step 2 above) and printing an export snippet so operators can run Stage 1 without guessing.
- Stage 1 entrypoints should set `DEPLOYKUBE_DEPLOYMENT_ID` explicitly (or derive it from the deployment config contract) so the default path is stable and unambiguous.

### 3) GitOps wiring: how components consume DSB without per-deployment overlays

Today, bootstrap Jobs mount SOPS files via ConfigMaps generated inside component directories (e.g., `components/secrets/bootstrap/kustomization.yaml`).

End state (recommended):

0. **Chicken-and-egg note (bootstrap key vs. bundle)**
   - Stage 1 is still responsible for creating `argocd/argocd-sops-age` (the Age private key Secret).
   - The DSB ConfigMap can be applied as ciphertext without any decryption, but **bootstrap consumers** can only decrypt and apply the underlying Secret manifests after `argocd/argocd-sops-age` exists.

1. **Split bootstrap Jobs from secret bundles**
   - Keep the Jobs/scripts in their components (e.g., `components/secrets/bootstrap`).
   - Remove the embedded SOPS files from those components.
   - Instead, have the Jobs mount a **well-known ConfigMap** produced by the deployment bundle:
     - `argocd/deploykube-deployment-secrets` (ConfigMap)

2. **Deployments publish their bundle into the right namespace(s)**
   - The deployment directory contains a `kustomization.yaml` that publishes the bundle into `argocd`:
     - `deployments/<deploymentId>/kustomization.yaml`
   - Argo points at:
     - `deployments/<deploymentId>`
   - This bundle kustomization turns the deployment’s SOPS files into `argocd/deploykube-deployment-secrets`.
   - Implementation detail: use `configMapGenerator` + `generatorOptions.disableNameSuffixHash: true` so the name stays stable.
   - Optionality and file list management:
     - Kustomize does not support globbing `configMapGenerator.files`, so the deployment `kustomization.yaml` must list files explicitly.
     - Helper: `scripts/deployments/bundle-sync.sh` rewrites the file list by scanning `secrets/`.
     - Repo lint enforces:
       - only allowed filenames exist under `deployments/<id>/secrets/`, and
       - the bundle kustomization file list matches what is on disk.
   - Clarification: the ConfigMap contains the **ciphertext** (SOPS-encrypted Secret manifests) as files. It does not contain decrypted Kubernetes Secret objects.
     - This avoids requiring an Argo-side SOPS plugin (ksops / config management plugin).
     - Consumers (Jobs) decrypt at runtime using the `argocd/argocd-sops-age` key and then `kubectl apply` the resulting Secret manifests.
     - The encrypted `*.secret.sops.yaml` files are referenced only via `configMapGenerator.files` (they are not applied as `resources:`).
   - If we later decide to publish any additional generated `Secret` objects from the bundle (not recommended for bootstrap secrets), the same “stable name” requirement applies: `disableNameSuffixHash: true`.

3. **Argo CD applies the deployment bundle early (as a child of `platform-apps`)**
   - Add a dedicated Argo `Application` that applies `deployments/<id>/…` bundle resources.
   - This `Application` is managed by the root `platform-apps` app-of-apps (i.e., it lives in the environment bundle under `platform/gitops/apps/environments/<deploymentId>/…`).
   - The DSB app should be minimal: it typically contains only the ConfigMap generation needed by bootstrap consumers.
   - Use sync waves on the **Application resource itself** to ensure the bundle is applied before bootstrap consumers:
     - Example: `argocd.argoproj.io/sync-wave: "-10"` on the DSB `Application`.
     - Existing bootstrap consumers like `secrets-bootstrap` already run early (currently `-6`), so `-10` ensures `argocd/deploykube-deployment-secrets` exists before those Jobs/apps sync and mount it.
   - This keeps the platform core apps fully reusable; only the deployment bundle is deployment-specific.

This approach scales cleanly: adding a deployment means adding one deployment directory + one early app entry, not copying overlays across components.

### 4) Operator workflow: new deployment

Provide one entrypoint that scaffolds everything required for a new deployment to be GitOps-renderable, without requiring the operator to know the internal list of required SOPS files.

Proposed script (naming illustrative):

- `./scripts/deployments/scaffold.sh --deployment-id <id> --environment dev|prod --base-domain <domain> [--overlay-mode dev|prod]`

Responsibilities:

1. Create `platform/gitops/deployments/<id>/config.yaml` (DeploymentConfig) and validate it (`tests/scripts/validate-deployment-config.sh`).
2. Generate a **deployment-specific Age keypair** to a deployment-specific location on disk (not inside the repo), and print:
   - the public recipient,
   - the local private key path,
   - where to store it out-of-band.
3. Create `platform/gitops/deployments/<id>/.sops.yaml` containing that recipient.
4. Create **valid SOPS-encrypted placeholder Secret manifests** under `platform/gitops/deployments/<id>/secrets/` for the required bundle file set (see §1).
   - Do **not** create truly empty files: consumers run `sops -d` and will fail on empty/non-SOPS documents.
   - Placeholders must follow a hard contract:
     - Kubernetes Secret manifests: `metadata.labels["darksite.cloud/placeholder"] == "true"`
     - Non-Secret bundle files (e.g., Step CA seed): top-level `darksite.cloud/placeholder` key is present
     - and the payload fields are sentinel placeholders (e.g., `REPLACE_ME`) so humans don’t confuse them with real values.
   - All DSB consumers must **fail-before-apply/write** when `darksite.cloud/placeholder=true` is present.
     - This is especially important for “write to Vault” consumers like Step CA seeding.
   - Implementation detail: generate a plaintext Secret stub (using `stringData`) and then encrypt it:
     - `cd platform/gitops/deployments/<id> && SOPS_CONFIG=.sops.yaml sops --encrypt --in-place secrets/vault-init.secret.sops.yaml`
   - High-risk consumers (notably Step CA seeding) must treat placeholders as invalid input and exit without writing anything to Vault (tracked under `docs/component-issues/step-ca.md` until implemented).
   - Optional app secrets (Minecraft/Factorio) are scaffolded only when explicitly requested (e.g., `--include-app-secrets minecraft-monifactory,factorio`) because the deployment identity contract does not (and should not) embed a full “apps enabled” list.
5. Write a custody acknowledgement sentinel/evidence record (see “Security model”).

Population of the *actual secret values* remains a separate step, because some values are created by running init flows against the cluster (e.g., `vault operator init`).

Expected state:
- After `scaffold`: Git contains deployment config + encrypted placeholder bundle files; Argo sync may progress until it hits components that validate/require real values.
- After `populate/refresh` (§5): bundle files contain real values (still encrypted), bootstrap Jobs succeed, and the platform can converge to `Synced/Healthy`.

### 5) Operator workflow: populate/refresh bootstrap secrets

Extend the existing init helper to be deployment-aware:

- `shared/scripts/init-vault-secrets.sh --deployment-id <id> …`

Responsibilities (deployment-scoped):

- Write secrets into `platform/gitops/deployments/<id>/secrets/…` (not into component directories).
- Encrypt using the standardized invocation style (§2):
  - `cd platform/gitops/deployments/<id> && SOPS_CONFIG=.sops.yaml sops --encrypt --in-place secrets/<filename>.secret.sops.yaml`
- Ensure real (non-scaffold) outputs do **not** carry `darksite.cloud/placeholder=true`.
- Apply the decrypted manifests to the target cluster (as it already does today).
- Commit changes and reseed Forgejo (as it already does today).

This keeps the “secret value generation” logic in one place and makes it per-deployment.

### 6) Rotation

Rotation needs to cover two distinct things:

Scope note:
- This document specifies **DSB/SOPS rotation** (the cryptographic access mechanism: recipients + Age identities + re-encryption).
- Rotation of the **secret values themselves** (Vault init material, kms-shim token/key, Step CA PKI material, app credentials) is owned by the relevant component runbooks/docs. This doc only links to those procedures.

#### 6.1 Rotate SOPS encryption keys (Age recipients)

Goal: rotate the Age key(s) used to encrypt deployment SOPS files without breaking decryption in-cluster.

Two-phase rotation:

1. Generate a new Age keypair (store private key out-of-band).
2. Add the new public recipient to `deployments/<id>/.sops.yaml`.
3. Re-encrypt all SOPS files for that deployment:
   - `cd platform/gitops/deployments/<id> && SOPS_CONFIG=.sops.yaml sops updatekeys secrets/*.secret.sops.yaml`
4. Update the cluster secret `argocd/argocd-sops-age` to contain **both** identities temporarily (concatenate keys in `age.key`) or switch to the new key after confirming all Jobs succeed.
   - Mechanism (v1): the rotation helper updates `argocd/argocd-sops-age` directly via `kubectl apply` (do not require re-running full Stage 1).
5. Remove the old recipient from `.sops.yaml`, re-run `sops updatekeys`, and remove the old identity from `argocd-sops-age`.

This should be wrapped in a script:
- `./scripts/deployments/rotate-sops.sh --deployment-id <id>`

#### 6.2 Rotate the bootstrap secret values (content rotation)

This is separate from SOPS key rotation.

Examples:
- KMS shim token/key rotation (and Vault init secret refresh) already exists in `shared/scripts/init-vault-secrets.sh`. Track runbook gaps under:
  - `docs/component-issues/vault.md`
- Step CA material rotation is a higher-level PKI operation and is tracked under `docs/component-issues/step-ca.md` until we document and evidence a safe procedure.
  - Brief intent: rotating the **root** trust anchor has large blast radius (all clients must trust the new root), so prefer “rotate intermediate/provisioner material under a stable root” where possible.

### 7) Validation / guardrails (repo-only)

Add repo-only checks to ensure the DSB is “ready enough” for GitOps:

- For every `platform/gitops/deployments/<id>/config.yaml`, require:
  - `platform/gitops/deployments/<id>/.sops.yaml` exists and contains at least one age recipient.
  - `platform/gitops/deployments/<id>/secrets/` exists with the required placeholder files.
  - all bundle secret manifests follow the naming convention `*.secret.sops.yaml`.

Add a “wrong key” detector to address operator ergonomics:

- For each file under `platform/gitops/deployments/<id>/secrets/*.secret.sops.yaml`, validate that:
  - the SOPS metadata recipients (`.sops.age[].recipient`) are a subset of (or equal to) the recipients configured in `platform/gitops/deployments/<id>/.sops.yaml`, and
  - no legacy/global recipient(s) are used (during migration from the repo-root `.sops.yaml` model).

This is intended as a repo-level lint/CI check (optionally also runnable as a local pre-commit hook), so operators don’t need to remember `SOPS_CONFIG=…` during manual edits — mistakes become fast, deterministic failures.

Additionally, add a lint rule to prevent regression:
- No new bootstrap SOPS secrets should be added under `platform/gitops/components/**/secrets/`.
- Bootstrap SOPS secrets must live under `platform/gitops/deployments/**/secrets/` in the end state.

This keeps “deployment-scoped” secrets from creeping back into shared component directories.

v1 implementation:
- Local lint script: `tests/scripts/validate-deployment-secrets-bundle.sh`
- CI: `.github/workflows/deployment-contracts.yml`

### 7.1 Validation strategy (v1)

We intentionally avoid adding a separate “DSB smoke job” by default because DSB is an enablement mechanism and already has strong natural failure signals:

- Argo CD health: if consumers fail, apps are not `Healthy`.
- Consumer Jobs: bootstrap consumers (`secrets-bootstrap`, `certificates-step-ca-seed`, app bootstrap Jobs) already run real decryption + apply/write steps; failures here are actionable and occur at the right sync point.

Required validation layers (v1):

1) **Repo-only (CI / local)**
   - DSB file layout checks (presence + allowed filenames).
   - Wrong-key detection: SOPS metadata recipients match the deployment `.sops.yaml`.
   - Bundle wiring checks: `deployments/<id>/kustomization.yaml` file list matches the `secrets/` directory contents.

2) **Runtime (in consumer logic)**
   - Every DSB consumer must:
     - fail fast if a required file is missing,
     - fail fast if decryption fails, and
     - fail-before-apply/write when `darksite.cloud/placeholder=true` is present.

Optional (recommended once we have prod-class fleet ops):

3) **Periodic drift detection**
   - Add a lightweight `CronJob` in `argocd` that mounts:
     - `argocd/deploykube-deployment-secrets` (ciphertext bundle), and
     - `argocd/argocd-sops-age` (Age identities),
     then decrypts all bundle files and fails if:
     - any file cannot be decrypted,
     - any file is still marked `darksite.cloud/placeholder=true`, or
     - any required file is missing.
   - If implemented, this job must follow `docs/design/validation-jobs-doctrine.md` and should be wired into alerting/staleness for prod so “SOPS key drift” is caught before the next manual rotation.

### 8) Security model (custody + least privilege)

Bootstrap SOPS files contain **tier-0 credentials** (e.g., Vault init material, kms-shim auto-unseal token/key, CA seed material). Treat the Age private key as a **breakglass-class credential**, similar in spirit to the offline Proxmox kubeconfig custody gate:

- Store the deployment Age private key out-of-band (password manager/HSM-backed secret store).
- Record a custody acknowledgement with evidence under `docs/evidence/` that includes:
  - deploymentId
  - key fingerprint / recipient
  - storage location (human-readable, not the secret itself)

Custody tooling (implemented):

- `./shared/scripts/sops-age-key-custody-ack.sh` (modeled after `shared/scripts/breakglass-kubeconfig-custody-ack.sh`):
  - writes a local sentinel under `tmp/bootstrap/`:
    - `tmp/bootstrap/sops-age-key-acked-<deploymentId>`
  - writes an evidence markdown file under `docs/evidence/`:
    - `docs/evidence/YYYY-MM-DD-sops-age-key-custody-ack-<deploymentId>.md`
  - evidence includes:
    - key recipient(s)
    - SHA256 of the local key file (identified, not stored)
    - out-of-band storage location reference

Custody gate (implemented, prod only):

- For prod-class deployments (`spec.environmentId: prod`), Stage 1 refuses to proceed unless the custody sentinel exists and matches the current key SHA256.
- For dev/staging deployments, this is warn-only to keep local iteration fast.
- After rotations (§6.1), re-run the custody acknowledgement for the new key file SHA.

Operationally:
- Stage 1 should *prefer* using the deployment-scoped key path and should not silently generate new keys for prod-class deployments.
- Recovery is possible (the key exists in `argocd/argocd-sops-age` after Stage 1), but recovering it should be treated as breakglass with evidence.

## Migration plan (incremental)

1) **Define the DSB contract + validation (no behavior change)**
   - Add this design doc.
   - Add placeholder DSB directories for existing deployments (`mac-orbstack`, `proxmox-talos`).
   - Add repo-only validation script (do not move secrets yet).
   - Introduce the “no new SOPS under components/**/secrets/” lint as **warn-only** (or with an allow-list) so we can land the checker without breaking existing deployments.

2) **Move bootstrap SOPS secrets to DSB**
   - Copy (not delete) existing encrypted files from `components/**/secrets/*.sops.yaml` into `deployments/<id>/secrets/` so consumers can be switched incrementally.
   - Decide whether to keep the same recipient initially:
     - Low-disruption option: keep the existing (global) recipient for the first migration PR, then rotate to a deployment-specific key as a second PR with evidence.
     - Strict option: generate a deployment-specific key immediately, add it to `deployments/<id>/.sops.yaml`, then run `sops updatekeys` for all bundle files.
   - Update `shared/scripts/init-vault-secrets.sh` to write into the DSB paths (so refresh/rotate workflows stop touching component directories).

3) **Refactor bootstrap Jobs to consume the DSB-published ConfigMaps**
   - Split “bootstrap job logic” from “bundle files”.
   - Add a deployment bundle Application that publishes the ConfigMaps to `argocd`.
   - Once all consumers read from the DSB, delete the old component-scoped SOPS files and flip the lint rule to **fail**.

4) **Harden key custody gates**
   - Add a custody acknowledgement gate for prod-class deployments (aligned with the breakglass kubeconfig gate).

5) **Roadmap integration**

## Evidence (mac dev)

   - Record this as closing part of the “Secrets and bootstrap trust chain” gap in the Cloud Productization Roadmap.

## Open questions

- None for v1. Any future evolution (multi-recipient policies, Vault-only Step CA SSOT, per-operator keys) should be proposed as a follow-up design once we have at least one full DSB migration + rotation drill with evidence.
