# Distribution Bundles (Packaging + Shipping)

## Tracking

- Canonical tracker: `docs/component-issues/distribution-bundles.md`

## Purpose

Define a **commercialization-safe** packaging and shipping model for DeployKube that:
- preserves the repo’s **GitOps-first** operating model,
- supports **regulated / air-gapped** installs,
- is repeatable and auditable (what exactly was shipped),
- and reduces the chance of **license non-compliance** when we distribute third-party software as part of a bundle.

This document is **not legal advice**. It is a technical design for a distribution pipeline; legal review is still required before selling/redistributing bundles.

## Scope / Ground Truth

Ground truth (today) lives in-repo:
- Platform definition: `platform/gitops/**`, `target-stack.md`
- Bootstrap boundaries: `docs/design/gitops-operating-model.md` + `scripts/**` + `shared/scripts/**`
- Third-party inventory notes: `THIRD_PARTY_NOTICES.md`
- Security scanning design: `docs/design/vulnerability-scanning-and-security-reports.md`

This design does **not** rely on live cluster state.

## Goals

1) **Multiple distribution modes** (source-only → offline bundle) with clear trade-offs.
2) **Deterministic outputs**: a bundle is tied to a git revision and has a machine-readable BOM.
3) **Air-gapped readiness**: no dependence on public registries or public Helm repos at install time.
4) **License + notice compliance by construction**:
   - we can emit the required attributions and license texts for redistributed artefacts,
   - and we can produce “corresponding source” artefacts where applicable (GPL/AGPL scenarios).
5) **Integrity + provenance**: bundles can be verified (checksums/signatures).

## Phase 0 Product Decisions (2026-02-18)

- **Commercial default mode:** Mode C (air-gapped bundle) is the intended commercial shipping target.
- **Delivery timing:** full Mode C productization is intentionally deferred until customer-readiness (first real customer pilot/pre-sales deployment); meanwhile, continue incremental tooling/guardrails and keep `docs/component-issues/distribution-bundles.md` open.
- **Secret-plane component in default bundle path:** OpenBao is the default bundled secret-plane implementation; HashiCorp Vault is not part of the default commercial bundle contract.
- **Example apps:** excluded from commercial bundles by default; remain opt-in only.
- **Proof-of-concepts:** excluded from commercial bundles by default; remain opt-in only unless explicitly promoted into a supported product surface.

## Non-goals

- Rewriting/“fixing” third-party licenses (we only comply or replace components).
- Defining the final commercial terms of DeployKube (pricing, SLA, trademark, etc.).
- Building a full hardware appliance / OS image pipeline in Phase 0 (VM/appliance can be a later phase).

## Key constraints (from the repo operating model)

- Bootstrap remains minimal: host scripts prepare the cluster and seed Forgejo/Argo; steady-state is GitOps.
- The GitOps payload is a deterministic snapshot of `platform/gitops` at repo `HEAD` (same principle as Forgejo seeding).
- Environment differences are expressed via overlays and the deployment config contract (avoid ad-hoc conditionals).

## Definitions

- **Bundle**: a shippable distribution artifact (or set of artifacts) that installs DeployKube.
- **BOM (Bill of Materials)**: machine-readable listing of included images/charts/manifests with versions + digests.
- **SBOM**: software bill of materials for binaries/images (optional but recommended for regulated environments).
- **Air-gapped**: install environment cannot reach public artifact sources (registries, Helm repos, GitHub).

## Artifact-governance contract

Distribution bundles must consume the same explicit artifact contract as centralized Trivy CI and offline bootstrap. Bundles should not infer “what we ship” only from ambient manifest discovery.

### Two catalog surfaces

- `platform/gitops/artifacts/package-index.yaml`
  - product-owned artifacts built or packaged by DeployKube
- `platform/gitops/artifacts/runtime-artifact-index.yaml`
  - curated third-party runtime artifacts that DeployKube redistributes/supports as part of the platform baseline

These surfaces stay intentionally separate:
- product-owned artifacts and curated third-party runtime artifacts have different ownership, provenance, and support semantics
- mixing them into one undifferentiated list would make BOM, notice, and support decisions harder to audit

### Shared consumers of the catalogs

Both catalogs should feed the same platform surfaces:
- bundle BOM generation
- offline artifact export and registry preload
- mirror/preflight validation
- centralized Trivy CI image inventory
- third-party notice and corresponding-source/compliance generation

Repo discovery still matters, but only as lint:
- detect deployable images missing from the catalogs
- detect stale catalog entries
- detect policy drift between manifests and distribution inputs

The catalogs, not discovery scripts, are the authoritative “what DeployKube ships/supports” contract.

### Required catalog semantics

Each entry should carry enough metadata for bundle generation, scanning, and compliance review. Minimum required fields:
- owning component
- `source_ref`
- `distribution_ref`
- digest/pin contract
- bundle inclusion mode
- mirror expectation
- support surface
- provenance/license metadata

The `source_ref` to `distribution_ref` mapping is required because the platform needs both:
- provenance back to the upstream/build origin
- deterministic internal distribution targets for offline/bootstrap installs

## Distribution modes

### Mode A — Source-only (GitOps repo)

Deliverable: a git revision (or tarball) containing this repository (or a subset) and operator documentation.

Characteristics:
- Customer pulls container images and Helm charts from upstream sources.
- Lowest redistribution burden for DeployKube (you mainly distribute your Apache-2.0 repo).
- Not suitable for air-gapped installs.

### Mode B — Online “pinned installer” (no artefact redistribution)

Deliverable: source + a generated BOM (images with digests, charts with versions) and verification tooling.

Characteristics:
- Still pulls artefacts from upstream, but pins by digest/version.
- Useful as an intermediate step: improves reproducibility and upgrade safety without offline complexity.

### Mode C — Air-gapped bundle (artefact redistribution)

Deliverable: source + artefacts required for install with no public network access:
- OCI images (all required images, pinned by digest),
- Helm charts (or pre-rendered manifests),
- plus license/notice materials.

Characteristics:
- Highest compliance + operational responsibility (we become a redistributor).
- Supports regulated environments (offline registry + offline chart source).

### Mode D — Appliance (future)

Deliverable: Mode C plus VM images/hardware profiles/installation media.

Characteristics:
- Out of scope for Phase 0; included here to ensure Mode C does not block it.

## Bundle architecture (recommended)

### Bundle as a directory tree (exportable as tar/zip)

At a minimum, produce:

- `bundle.yaml` (metadata): bundle version, git SHA, build time, supported environments, tool versions.
- `bom.json` (BOM): images (repo/tag/digest), charts (name/version/source), vendored manifests.
- `LICENSE` / `NOTICE` (DeployKube)
- `THIRD_PARTY_NOTICES.md` (human inventory)
- `third_party/licenses/` (collected license texts for redistributed artefacts)
- `third_party/sources/` (only when needed; see “Copyleft compliance”)

For Mode C (air-gapped), additionally produce:
- `oci-images/*.tar` (or OCI layout) for all required images
- `charts/` (vendored chart tgz or chart source trees) **or** `rendered-manifests/`
- `install/` scripts that load artefacts into the target environment (registry, git server, etc.)

Bundle-generation rule:
- `bom.json` must record which catalog surface supplied each bundled artifact so product-owned and curated third-party payloads remain distinguishable in evidence, support, and compliance review.

### Rendering strategy choices (for air-gapped)

DeployKube today uses Kustomize `helmCharts` pointing at public Helm repos. Air-gapped installs need one of:

1) **Vendor Helm charts** and render at install time (Argo/Kustomize/Helm uses local charts).
2) **Host an internal Helm repo** (or OCI chart registry) in the air-gapped environment and repoint chart sources to it.
3) **Pre-render manifests** at bundle-build time and ship pure YAML to Argo (no Helm fetch at sync time).

Design preference (directional):
- Prefer **(2)** long-term (OCI registry as a single artifact source for images + charts).
- Use **(3)** as a pragmatic Phase 0 fallback if it proves simpler than chart vendoring, but be explicit about the customization boundary.

The chosen strategy must be reflected in `bom.json` and backed by an operator procedure and evidence.

## License and redistribution compliance (engineering contract)

### General rules

- DeployKube code stays **Apache-2.0** (`LICENSE`, `NOTICE`).
- Any copied/vendored upstream artefacts keep their upstream license headers and attribution.
- When we **redistribute** third-party software (Mode C/D), the bundle must include:
  - the relevant license text(s) and notices, and
  - a clear provenance mapping (component → upstream project → version/digest).

Engineering contract:
- every redistributed third-party runtime artifact in `runtime-artifact-index.yaml` must be able to map into:
  - bundle BOM entries
  - `THIRD_PARTY_NOTICES.md` / generated notice material
  - source/compliance handling where required

### Copyleft compliance (GPL/AGPL)

Some stack components are GPL/AGPL (see `THIRD_PARTY_NOTICES.md`):
- If we ship their container images/charts as part of a bundle, we must be able to provide **corresponding source** in a compliant way.
- If we modify an AGPL component and offer it as a network service, those modifications must be offered to users of that service.

Engineering implication:
- For any redistributed GPL/AGPL component, the bundle build process must either:
  1) include `third_party/sources/<component>/...` (exact source tarball/commit for the shipped version), or
  2) produce a compliant written offer / source retrieval method (policy decision; legal review required).

### Source-available / restricted-use (e.g. BSL)

Source-available components can impose business-model constraints (especially hosted offerings).
Current default stack direction uses OpenBao for the secret plane; if a source-available alternative is included (for example as a customer-supplied variant), that must be explicitly declared per bundle.

Engineering implication:
- The bundle mode (A/B/C/D) must declare whether such components are:
  - included in the bundle,
  - replaced (e.g. alternative backend),
  - or customer-supplied.

This decision must be explicit in the BOM and the release notes.

### Proprietary dependencies

Dev-only tooling (e.g. OrbStack) and optional example workloads (e.g. Factorio/Minecraft) must not “leak” into a commercial bundle unless explicitly reviewed.

Engineering implication:
- Bundle builder must support an “allowed components” allow-list and default to excluding proprietary/EULA workloads.

## Supply chain + integrity

Minimum bar for Mode B/C:
- Pin images by **digest** in the BOM; avoid floating tags.
- Emit cryptographic checksums for all bundle artefacts.
- Sign the bundle (at least the `bundle.yaml`/`bom.json` or tarball).

Recommended (regulated):
- SBOM generation for our own images (e.g. `bootstrap-tools`) and optionally for third-party images.
- Signature verification of upstream images where available (policy decision).

## Upgrade and customization model

Constraints:
- DeployKube relies on GitOps for steady-state. Customers will upgrade by moving the desired git revision/bundle version.

Recommended model:
- **Customization** happens via the deployment config contract + overlays, then a bundle is built from that input.
- Avoid “mutable installers” that patch resources post-render; prefer declarative config that can be reproduced and diffed.

Artifact-catalog compatibility rule:
- deployment config and overlays may change which supported components are in scope, but they must not bypass the two catalog surfaces for shipped artifacts
- if a deployable image enters the supported platform baseline, it must be added to the correct catalog before the bundle/release is considered complete

## Evidence expectations for a bundle release

For each published bundle version, capture evidence under `docs/evidence/` (exact naming conventions are tracked outside this design doc):
- bundle build command + git revision
- BOM excerpt (images + digests)
- verification output (checksum/signature verification)
- for Mode C: proof that install works without public network access (smoke output)
