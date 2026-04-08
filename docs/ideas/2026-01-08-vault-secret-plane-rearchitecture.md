# Idea: Vault/ESO secret plane re-architecture (OpenBao + better root of trust)

Date: 2026-01-08  
Status: Promoted (see `docs/design/openbao-secret-plane-kms-shim.md`)

Note (2026-01-31): `vault-transit` has since been retired. This document is kept as historical context for the design evolution.

## Problem statement

DeployKube’s secrets plane is currently:

- **Vault core** (`vault-system`): 3-replica Raft cluster, used as the *platform* system-of-record for secret values.
- **Vault transit** (`vault-transit`): dedicated cluster providing **auto-unseal** for Vault core via the transit seal.
- **ESO**: projects secrets from Vault into Kubernetes.
- **DSB (SOPS)**: stores bootstrap material (Vault init/transit init + tokens) encrypted in Git.

This stack is a frequent source of operational friction during:

- **new bootstraps** (ordering/secrets readiness),
- **restarts / cold boots** (dependency chain: transit health → core unseal → ESO → the rest),
- and “wipe/rebuild” recovery flows (Raft data + secrets-of-record drift).

Additionally, the current implementation is based on **HashiCorp Vault (BSL)** (repo reality: Vault `1.20.4`), which we want to replace with **OpenBao** to avoid the licensing constraints.

Finally, we want a stronger and more explicit **root of trust** for the entire platform:

- Today, the practical trust anchor is the **deployment Age private key** (Stage 1 seeds `argocd/argocd-sops-age`), which decrypts the DSB bundle, which in turn contains the transit/core bootstrap material.
- A future direction is to use **hardware-backed custody** (HSM / YubiKey-family devices) to reduce “file key” risk and align with a “private cloud-in-a-box” security posture.

## Why now / drivers

- The repo’s master delivery queue explicitly gates future growth on “**Vault + ESO hardening**”. (`docs/component-issues/master-delivery-queue.md`)
- Tenancy work will expand secret usage and makes reliability + clear custody requirements non-negotiable. (`docs/design/multitenancy-secrets-and-vault.md`)
- The licensing issue is structural: we should avoid deepening dependence on a BSL-licensed core.

## Proposed approach (high-level)

Treat the secrets plane as two separable layers:

1) **Root-of-trust / seal provider**  
   The component that ensures Vault/OpenBao can come up from a cold start (auto-unseal) and defines the custody story.

2) **Operational secrets store + projection**  
   OpenBao (as the secrets system-of-record) + ESO (projection into Kubernetes) with strong tenancy/scoping guardrails.

Then, pick an architecture that:

- eliminates “brittle dependency loops” during bootstrap/cold boot,
- remains GitOps-first (post Stage 1),
- is compatible with the multitenancy secrets model,
- and gives us a credible migration path from HashiVault → OpenBao.

## What is already implemented (repo reality)

- Core Vault + transit auto-unseal pattern:
  - `platform/gitops/components/secrets/vault/README.md`
- DSB (deployment-scoped SOPS bootstrap secrets) and stage-1 key seeding:
  - `docs/design/deployment-secrets-bundle.md`
  - `platform/gitops/components/secrets/bootstrap/README.md`
- Tenancy direction for Vault/ESO path conventions and scoped access (design, Phase 0 partially implemented):
  - `docs/design/multitenancy-secrets-and-vault.md`
- Canonical trackers for current gaps:
  - `docs/component-issues/vault.md`
  - `docs/component-issues/external-secrets.md`
- Existing high-level feature request placeholders (not a design):
  - `docs/feature-requests/vault.md`

## Architecture options (brainstorm)

### Option A — “Minimum change” migration: OpenBao, keep transit, harden the pattern

Keep the current topology (transit auto-unseal → core) but replace HashiVault with OpenBao and reduce bootstrap/cold-boot brittleness.

Ideas:

- **Swap the server image** (keep the current Helm chart wrapper if OpenBao is drop-in compatible at runtime).
- **Make transit HA** (3 replicas) to remove the single-node SPOF (requires thinking about node placement in dev/prod).
- **Decouple from Istio** for core Vault/OpenBao as much as possible (injection off, rely on NetworkPolicy + TLS), reducing mesh-induced bootstrap coupling.
- **TLS everywhere** (transit + core listeners) so we can tighten policies without relying on mesh exceptions.
- Keep the “root-of-trust” as DSB for now, but tighten custody (see Option D).

Trade-offs:

- Pros: preserves recovery-key model on core (auto-unseal), fewer behavioral changes for ESO + consumers, incremental migration possible.
- Cons: still two clusters + more moving parts; still have a dedicated “bootstrap key” Secret that must remain consistent.

### Option B — Remove transit entirely: self-unseal with Shamir key shares (DSB-backed)

Delete the transit cluster and configure OpenBao core to use Shamir unseal (no transit seal).

Implementation sketch:

- Store core unseal material in the DSB and mount it into each core pod.
- Add a best-effort `postStart` unseal loop (similar to today’s transit pattern) for each pod.

Trade-offs:

- Pros: fewer components; removes transit dependency; simpler cold-boot ordering.
- Cons: changes the security model (unseal keys become “hot material” in Kubernetes); changes operational semantics (recovery keys vs unseal keys); may be unacceptable for the long-term custody story.

### Option C — Externalize the root of trust: “KMS-like” service backed by hardware

Keep a small, *high-assurance* root-of-trust outside Kubernetes and let the in-cluster OpenBao core depend on it for auto-unseal.

Variants:

- **C1: External transit cluster** (OpenBao transit runs on a dedicated VM/host; core uses transit seal to that endpoint).
  - In this model, “the one thing you must unseal manually / with hardware custody” is the external transit cluster.
- **C2: HSM/PKCS#11 seal** (use an HSM-backed seal mechanism if supported by OpenBao in OSS).
  - Likely candidates: network HSM (e.g., YubiHSM-class devices) vs a PCIe HSM.
- **C3: “KMS shim”** (run a small KMS service that provides an API compatible with a supported seal backend).
  - This is attractive conceptually, but feasibility depends on OpenBao’s supported seal backends and whether a secure “shim” exists without creating a bespoke long-term maintenance burden.

Optionality requirement (dev vs prod):

- The KMS shim should be designed as a **pluggable “seal provider”** with distinct custody profiles, and this should be selectable per-deployment (not hard-coded to dev vs prod):
  - **C3a (prod, unattended): hardware-backed backend** (preferred for auto-unseal):
    - Use a service-grade device (e.g., YubiHSM-class / real HSM) that can perform unwrap operations without a human touch prompt.
  - **C3b (prod, human-present): YubiKey-unlocked backend** (acceptable if we can tolerate a manual cold-boot step):
    - A *YubiKey* is typically best treated as an **operator presence** device (unlock/unseal ceremony), not as an always-on KMS.
    - Model: KMS shim stores its master key encrypted-at-rest; an operator presents a YubiKey to unlock it after cold boot (then the shim can serve unwraps).
  - **C3c (dev *or* “low-assurance prod”): in-cluster backend**:
    - Provide a “software custody” backend (or route to an in-cluster transit instance) so clusters can cold boot without external hardware.
    - Treat this as explicitly weaker isolation (cluster admins effectively control the root-of-trust) but acceptable for customers who don’t require hardware custody.

Affordable-ish hardware options (still keep an “enterprise HSM later” path via PKCS#11):

- **TPM 2.0 (built-in) + `tpm2-pkcs11`** (cheapest “real hardware”):
  - Concept: run the KMS shim on a dedicated node/VM host and use that machine’s TPM as the KEK boundary (PKCS#11 interface via `tpm2-pkcs11`).
  - Pros: often already present in servers; no extra dongles; supports unattended operation; can be tied to measured boot/PCRs.
  - Cons: the root-of-trust is now “that host”; HA means provisioning multiple TPM-backed nodes with explicit key provisioning/backup semantics.
- **YubiHSM-class device** (budget HSM, designed for unattended service use):
  - Concept: KMS shim uses a PKCS#11 library/connector to wrap/unwrap keys using a non-exportable key inside the device.
  - Pros: much closer to “real HSM” operational semantics (unattended, non-exportable keys, purpose-built); still far cheaper than enterprise network HSMs.
  - Cons: still a dedicated device; needs a custody + recovery procedure (spares, key backup strategy, physical access controls).
- **SmartCard-HSM / Nitrokey HSM-class tokens** (low-cost, but often “operator-present” in practice):
  - Concept: use a smart-card-style HSM with PKCS#11, attached to the KMS shim host.
  - Pros: inexpensive; PKCS#11 is common; reasonable for “unlock on boot” ceremonies.
  - Cons: many workflows devolve into “store the PIN somewhere” (which reduces benefit) unless you accept a human-present boot step; throughput/features vary a lot.

Non-goal: treat a touch-required **YubiKey** as a service-grade KMS. It can still be useful as a *boot unlock token* (C3b), but it is usually the wrong fit for unattended auto-unseal.

Trade-offs:

- Pros: best story for “secure root of trust”; potentially best cold-boot behavior (KMS is independent of in-cluster scheduling).
- Cons: pushes some lifecycle outside GitOps/Kubernetes; extends the bootstrap boundary; requires hardware/device ops and on-prem key custody/runbooks.

### Option D — Strengthen the existing trust anchor: hardware-backed SOPS/DSB keys

Keep the current in-cluster topology (or any of the above) but reduce risk by moving from “Age private key file” custody to “hardware-backed decrypt”.

Ideas:

- Use a **YubiKey-backed** key for SOPS decryption (e.g., via age plugin or PGP-on-hardware) so the DSB can’t be decrypted without the device.
- Split recipients (two-person rule) for prod DSB material.

Trade-offs:

- Pros: improves security without major runtime changes; aligns with DSB design notes about out-of-band storage.
- Cons: doesn’t directly fix runtime brittleness; may make bootstrap less convenient unless we design an operator workflow that is still low-toil.

### Option E — Tenancy readiness (orthogonal but must stay compatible)

Independently of the unseal/root-of-trust decision, any redesign should converge toward the tenancy model:

- phase out the broad “read-anything” ESO role (Phase 0 reality today),
- use **scoped SecretStores** per org/project, and
- keep Vault authorization state GitOps-managed. (`docs/design/multitenancy-secrets-and-vault.md`)

## What is missing / required to make this real

Common work (regardless of option):

- Define “cold-boot success criteria” and a repeatable test:
  - transit/core/ESO health, plus at least one consumer that depends on ESO.
- Decide whether Vault should be **in-mesh or out-of-mesh** as a reliability principle (then align NetworkPolicy/TLS accordingly).
- Decide the long-term custody story:
  - what is allowed to live in Git (SOPS ciphertext),
  - what must live out-of-band (hardware/offline),
  - and how operators perform breakglass/unseal actions with evidence.

Configuration knob (proposal): select the root-of-trust mechanism in `DeploymentConfig`

- Add a non-secret, deployment-scoped selector to `platform/gitops/deployments/<deploymentId>/config.yaml` (fits the “deployment identity / ops knobs” posture; no secrets).
- This selector should drive which GitOps components are installed and how they’re wired (e.g., “in-cluster transit”, “in-cluster KMS shim”, “external KMS shim endpoint”, etc.).

Illustrative shape (draft only; exact naming TBD):

```yaml
spec:
  secrets:
    # A policy choice: what root-of-trust profile does this deployment want?
    rootOfTrust:
      mode: inCluster        # inCluster | external
      provider: kmsShim      # kmsShim | transit (legacy) | tbd
      assurance: low         # low | high (affects defaults/guards)

    # If provider=kmsShim, define how the shim gets its key boundary.
    kmsShim:
      backend: soft          # soft | tpm2-pkcs11 | yubihsm-pkcs11 | enterprise-pkcs11
      # If mode=external, this would be an endpoint/identity reference (no secrets here).
      # endpoint: https://kms.example.internal
```

Notes:

- Keep this **non-secret**: no PINs, tokens, keys, or device secrets in the DeploymentConfig.
- “Assurance=low” should be explicit and ideally gate/label evidence so we don’t accidentally ship a low-assurance posture as “prod-default”.

Option-specific work:

- OpenBao migration:
  - compatibility matrix (which Vault version semantics does OpenBao track for our use cases: raft, transit seal, auth methods, KV v2).
  - in-place migration plan (data export/import vs storage-level migration).
- Hardware-backed root-of-trust:
  - pick device class (YubiKey vs YubiHSM vs dedicated HSM),
  - pick integration point (SOPS key custody vs seal backend),
  - write a custody/runbook story compatible with the existing DSB and breakglass doctrine.

## Risks / weaknesses

- **Compatibility unknowns**: “OpenBao as drop-in” must be validated against our specific features (raft + transit seal + auth methods + backup jobs).
- **Increased complexity**: introducing hardware or out-of-cluster services can easily violate the “keep Stage 0/1 small” principle unless tightly scoped.
- **Custody vs convenience tension**: stronger root-of-trust usually means more manual steps; we need to be explicit about acceptable toil, especially for cold boots.
- **Tenant isolation**: ESO + Vault policies must converge toward scoped access, or the secret plane becomes the biggest multi-tenant escape hatch.

## Alternatives considered

- Keep HashiVault and accept BSL constraints: rejected direction (licensing).
- Replace Vault/ESO entirely (e.g., SOPS-only steady state): rejected by current repo posture (SOPS is bootstrap-only).

## Open questions

1. What “cold boot” behavior do we want as a hard requirement?
   - fully automatic recovery, or “requires a human to present hardware once”?
2. Is the transit cluster intended to remain single-node forever, or should it be HA (and if so, what nodes does it run on in prod)?
3. If we want “YubiKey as HSM”, do we actually mean:
   - YubiKey (interactive/manual presence), or
   - YubiHSM-class device (service-like, suitable for auto-unseal), or
   - hardware-backed SOPS keys only (keep runtime as-is)?
4. Does our multitenancy plan require **per-tenant Vault instances**, or is “one cluster + policies + scoped ESO stores” sufficient for Tier S?
5. How do we want to treat Vault/OpenBao relative to Istio:
   - completely out of mesh, or in mesh with strict mTLS + exceptions minimized?
6. If we pursue a KMS shim, do we have a trustworthy implementation to reuse, or are we willing to own a security-critical service long-term?

## Promotion criteria (to `docs/design/**`)

Promote this idea when we have:

- A chosen “target architecture” (A/B/C + D as a separate custody decision).
- A validated compatibility note for OpenBao (dev cluster POC at minimum).
- A documented operator workflow for bootstrap + cold boot (including evidence expectations).
- A high-level migration plan (what changes in `platform/gitops/components/secrets/{vault,vault-transit,external-secrets}` and what new/removed components exist).
