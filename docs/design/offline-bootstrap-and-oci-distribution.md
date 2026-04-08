# Design: Fully Offline Bootstrap + OCI Artifact Distribution

Last updated: 2026-02-01  
Status: Draft

This design defines how DeployKube can:
- bootstrap a cluster with **zero internet connectivity**, and
- operate steady-state without depending on public registries/Helm repos at runtime,
while staying compatible with the repo’s GitOps operating model and long-term multi-tenancy roadmap.

## Tracking

- Canonical tracker: `docs/component-issues/distribution-bundles.md`

Related:
- GitOps boundary: `docs/design/gitops-operating-model.md`
- Distribution bundles overview (modes A–D): `docs/design/distribution-bundles.md`
- Security scanning design: `docs/design/vulnerability-scanning-and-security-reports.md`
- In-cluster registry (tenants + platform): `docs/design/registry-harbor.md`
- Curated ingress idea (ARC + approval gate): `docs/ideas/2026-01-07-curated-package-ingress-to-harbor.md`
- Roadmap constraints: `docs/design/cloud-productization-roadmap.md`

## Scope / ground truth

Repo-only scope (no live cluster assumptions):
- Bootstrap scripts: `shared/scripts/bootstrap-*-stage{0,1}.sh`, `bootstrap/**`
- GitOps payload: `platform/gitops/**`
- Target stack + version expectations: `target-stack.md`
- Distribution doctrine + compliance: `docs/design/distribution-bundles.md`, `THIRD_PARTY_NOTICES.md`

## Problem statement

Today, “bootstrap” and “first reconcile” require internet access in multiple ways:
- Stage 0 fetches artefacts from GitHub (e.g. Gateway API CRDs URL; Talos ISO fallbacks).
- Stage 0/1 and GitOps controllers pull images from public registries.
- Helm charts are often sourced from public Helm repos (via Kustomize/Argo fetch), which fails offline.
- Vulnerability scanners (e.g. Trivy) require database updates from the internet by default.

This prevents DeployKube from meeting a core product goal: **private cloud where public cloud is not possible**.

## Goals

1) **True offline bootstrap** (Stage 0 + Stage 1) for both dev and prod paths.
2) **Offline first reconcile**: after Stage 1, Argo CD can reconcile the full platform without reaching the internet.
3) **OCI-native artefact distribution**:
   - images distributed in OCI Image Format (not “best effort” tag pulls),
   - optional OCI artefacts (Helm charts as OCI, SBOMs, attestation bundles).
4) **Optional connected upgrades**:
   - when a connection exists, import updates via a curated ingress pipeline (ARC) without changing the offline contract.
5) **Roadmap compatibility**:
   - does not bake in assumptions that would block multi-tenancy (Phase 1+) or multi-cluster (Phase 2+).

## Non-goals

- Building a “full appliance” (ISOs/VM images for every layer) in Phase 0.
- Solving every upstream licensing/compliance decision in this document (the distribution-bundles design + tracker owns that).
- Replacing Helm/Kustomize overnight. This design focuses on eliminating *network fetches* and standardizing artefact handling; rendering strategy can evolve.

## Definitions

- **Offline bundle**: a shippable directory/tarball containing everything required to bootstrap and reconcile a cluster without internet access.
- **OCI Image Format**: images stored as OCI layout or OCI archive, addressable by digest.
- **Bootstrap registry**: a temporary/local registry used before the in-cluster registry is available (host-local or node-local).
- **In-cluster registry**: Harbor (durable) installed via GitOps once Argo is running.

## Contract: Bootstrap artifact source (bootstrap registry)

Offline bootstrap fails unless the cluster has an artifact source **before Harbor exists**. Phase 0 must define the bootstrap registry contract explicitly.

### Endpoint contract

Phase 0 decision (must be explicit):
- The bootstrap registry endpoint **must be reachable by all nodes** (kind containers / Talos nodes) during Stage 0/1.
- The endpoint is expressed as a single string `<host>:<port>` and is treated as an install-time input (environment variable or deployment config contract field).

Recommended Phase 0 baseline:
- Use a **stable internal registry hostname** for image references from day 1 (so GitOps does not need later rewrites).
- During Stage 0/1, that hostname resolves to the bootstrap registry (host-local for kind; LAN-reachable host for proxmox/talos).
- Once Harbor is installed, the same hostname resolves to Harbor’s registry endpoint (cutover by DNS/route switch, not by rewriting manifests).

### Trust/TLS contract

Phase 0 decision (must be explicit):
- Bootstrap registry transport is either:
  - **HTTP + explicit “insecure registry” config** (bootstrap-only), or
  - **TLS** with a CA trusted by nodes.

If TLS is used, node trust must be derived from the deployment config contract trust roots:
- `DeploymentConfig.spec.trustRoots.stepCaRootCertPath` (see `docs/design/deployment-config-contract.md`).

### Runtime wiring (kind + Talos/containerd)

Phase 0 contract requirements:
- **kind**: Stage 0 must configure containerd registry settings so pulls for the chosen internal registry hostname resolve to the bootstrap registry endpoint offline.
- **Talos**: Stage 0 must configure Talos/containerd registry settings so all nodes can pull from the bootstrap registry endpoint offline.

Important constraint:
- This must not rely on “pull-through cache to the internet.” The bootstrap registry is a **store** loaded from the bundle.

### Cutover contract (bootstrap registry → Harbor)

Phase 0 decision (must pick one primary mechanism):

A) **Manifest rewrite**: All GitOps image references are rewritten to Harbor/internal names at bundle-build time, and Stage 0/1 only ensures those images are present locally.

B) **Bootstrap-only mirrors**: Stage 0/1 configure temporary container runtime mirrors for public registries and then later remove them.

Recommendation:
- Prefer **A** (explicit internal image refs) because “forever implicit mirrors” become a multi-tenancy footgun and make admission enforcement harder.
- If any mirrors are used, constrain them to the **internal registry hostname only**, and make removal/cutover explicit and tested.

## Core idea: “Artefacts are inputs”

To go offline, DeployKube must stop treating images/charts/manifests as ambient network fetches and instead treat them as explicit inputs:
- enumerated in a BOM (digests, versions),
- shipped in an offline bundle,
- loaded into a registry/artifact store under controlled names,
- and referenced consistently from GitOps.

This aligns with the repo’s supply-chain direction in the cloud roadmap and the distribution bundles doctrine.

Practical repo-grounded note:
- The existing dev helpers (`shared/scripts/registry-sync.sh`) already know how to *discover* image references from the repo; the offline bundle builder should reuse the same discovery approach, but convert it from “warming caches” into “pin + export by digest”.

## Bundle build pipeline (connected environment)

Build the bundle in a connected environment (CI or an operator workstation with internet) from a specific git revision.

Minimum outputs (Mode C from `docs/design/distribution-bundles.md`):
- `bundle.yaml` + `bom.json` (authoritative list of artefacts and their digests/versions),
- `oci/` (OCI image layout or OCI archives for all required images),
- `manifests/` (raw YAML needed by Stage 0, e.g. Gateway API CRDs),
- `charts/` (either vendored charts or OCI chart artefacts, depending on the chosen rendering strategy),
- `install/` helpers that can load artefacts into the target environment without internet.

Important: the bundle is *tied to a git SHA* and is reproducible.

### Input contract: curated artifact catalogs

The offline bundle builder must have explicit, repo-owned inputs describing which artifacts must exist in the offline environment. A single mixed catalog is not enough because product-owned and curated third-party runtime artifacts have different ownership and compliance semantics.

Required surfaces:
- `platform/gitops/artifacts/package-index.yaml`
  - product-owned artifacts built or packaged by DeployKube
- `platform/gitops/artifacts/runtime-artifact-index.yaml`
  - curated third-party runtime artifacts that DeployKube redistributes/supports as part of the platform baseline

Contract:
- The bundle builder resolves all required entries from both catalogs to digests, produces the BOM, and exports OCI images under those digests.
- The bundle builder loads images into the bootstrap registry/Harbor under the deterministic naming scheme (mirrored upstream names do not collide).
- Each bundled artifact must preserve a `source_ref` to `distribution_ref` mapping so provenance and offline pull targets stay linked.

Why this split matters:
- bundles need a commercialization-safe distinction between product-owned and third-party payloads
- centralized Trivy CI, mirror/preflight, and notice/compliance generation must all consume the same artifact contract
- repo discovery should remain a lint/drift detector, not the authoritative distribution input

## Install pipeline (offline environment)

### Phase A: Stage 0 without internet

Requirements:
- Stage 0 must not download from GitHub or public registries.
- Stage 0 must not assume “brew install” or similar networked tooling.

Contract:
- Stage 0 consumes the offline bundle (path provided by the operator).
- Stage 0 provides an artefact source (bootstrap registry, loaded from bundle) so nodes can pull required images.

Concrete “remove internet dependencies” targets (repo reality today):
- Replace `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/...` with a bundle-provided manifest.
- Replace Talos ISO “download fallback from GitHub releases” with a bundle-provided ISO (or require pre-staged ISO).
- Eliminate bootstrap-time pulls of DeployKube-owned images from external registries by loading them into the bootstrap registry from the bundle.

Concrete “remove GitHub image dependency” targets (repo reality today; non-exhaustive):
- DeployKube-owned bootstrap/job images currently referenced from `registry.example.internal/...` (e.g. `bootstrap-tools`, `tenant-provisioner`).
- Upstream images currently referenced from `registry.example.internal/...` (e.g. Talos installer images, CloudNativePG Postgres base image).

Offline contract:
- the bundle must include these images (by digest) and load them into the bootstrap registry / Harbor so **no external registry pull** is required at install time.
- this requirement applies to both product-owned artifacts and curated third-party runtime artifacts from the two catalogs

Repo changes required (Phase 0; repo-grounded):
- **Gateway API CRDs**: Stage 0 must not apply the upstream GitHub URL. Use the repo-vendored manifest:
  - `platform/gitops/components/networking/gateway-api/standard-install.yaml`
- **Stage 0 (Proxmox/Talos)**: add offline-mode wiring:
  - `OFFLINE_BUNDLE_DIR` enables “no download” Talos ISO and “local chart” installs for Cilium/MetalLB/NFS.
  - `OFFLINE_BUNDLE_AUTO_LOAD_REGISTRY=1` optionally loads bundle images into the bootstrap registry before Talos pre-pulls.
- **Stage 1 (Proxmox/Talos + mac/orbstack)**: add offline-mode wiring:
  - `OFFLINE_BUNDLE_DIR` switches Forgejo/Argo CD charts to local `charts/*.tgz` from the bundle.
  - Forgejo seeding must support a bundle-provided GitOps snapshot (non-git directory).

Phase 0 implementation status (initial; this repo):
- ✅ Vendored Gateway API CRDs used by Stage 0 (no GitHub apply).
- ✅ `shared/scripts/offline-bundle-build.sh` creates a Phase 0 “bootstrap” bundle (charts + OCI image archives + GitOps snapshot + Talos ISO).
- ✅ `shared/scripts/offline-bundle-load-registry.sh` can load **pushable** registries from the bundle into the bootstrap registry (see “pushable vs proxy” note below).
- ✅ GitOps “first reconcile” no longer requires public Helm repos for the two boot-critical Helm apps:
  - `Application/networking-metallb` now sources the vendored chart from Forgejo git (`components/networking/metallb/helm/charts/...`).
  - `Application/storage-nfs-provisioner` now sources the vendored chart from Forgejo git (`components/storage/nfs-provisioner/helm/charts/...`).
- ✅ Forgejo seeding includes vendored artefacts even when the GitOps snapshot contains `.gitignore` patterns that would otherwise exclude them (e.g. vendored Helm charts).
- ✅ Bootstrap/verification Jobs for the default `shared-rwo` storage smoke no longer depend on `busybox` pulls (they use `bootstrap-tools`, which is already part of the offline bootstrap bundle set).

Pushable vs proxy registry note (Phase 0 reality):
- Some local “registry cache” deployments are pull-through **proxies** and reject pushes (“unsupported”).
- True offline bundle injection requires **pushable mirrors** (plain registries you seed), not proxies.
- Phase 0 bundles therefore need an explicit “which registries are mirrors vs proxies” contract, and the bootstrap registry implementation must support pushable mirrors for the required upstream registries.

### Phase B: Stage 1 without internet

Requirements:
- Forgejo + Argo CD install must not require pulling images/charts from the internet.
- Forgejo seeding must work from the bundle snapshot (same principle as “seed Forgejo from repo `HEAD`”).

Contract:
- Stage 1 seeds Forgejo with the `platform/gitops/**` snapshot contained in the bundle (or a repo tarball).
- Stage 1 installs Argo and points it at Forgejo.
- Argo reconciles the root app with all artefacts resolvable offline.

### Phase C: First reconcile and steady-state (offline)

Requirements:
- All image references used by GitOps resolve to the internal registry (Harbor) or the bootstrap registry until Harbor is ready.
- Helm chart fetching (if used) must not require public Helm repos.

Design direction:
- Harbor becomes the steady-state artefact store (images, and optionally OCI charts).
- The platform converges to “pull only from Harbor” for both platform and tenant namespaces.
- bundle/export tooling and centralized Trivy CI should therefore target the same `distribution_ref` contract used for Harbor/bootstrap distribution.

## Chart and manifest strategy (offline-safe)

Air-gapped installs require eliminating network fetches during rendering.

Compatible strategies (ordered by long-term direction):

1) **OCI charts hosted in Harbor**  
   - Bundle loads charts into Harbor as OCI artefacts.
   - GitOps sources charts from Harbor (no public Helm repos).
   - Directional preference: one artefact store for images + charts.

2) **Vendored charts in-repo**  
   - Bundle includes chart sources/tgz; Argo/Kustomize references local paths.
   - Simple and deterministic, but increases repo/bundle size and chart update toil.

3) **Pre-rendered YAML**  
   - Bundle ships rendered YAML; Argo applies pure KRM manifests.
   - Pragmatic, and aligned with the “no in-flight YAML rendering” direction, but requires a robust regeneration pipeline.

This design does not mandate which strategy ships first, but it requires that whichever strategy is chosen is:
- deterministic and pinned, and
- captured in the BOM.

### Phase 0 decision (must pick one)

Phase 0 (implemented in-repo today):
- Use **vendored charts in-repo** for a small, boot-critical set of Helm components so Argo can render them without reaching public Helm repos.

Longer-term direction (Phase 1+):
- Prefer **OCI charts hosted in Harbor**, or a move toward **pre-rendered KRM YAML**, once the bootstrap/cutover sequence and update pipeline are proven.

If Phase 0 uses “vendored charts”, the design must specify:
- where charts live in the bundle,
- how Argo/Kustomize resolves them via local paths, and
- how charts are pinned (version + digest/hash) and updated.

### Required BOM fields for charts

Even if `bom.json` is defined elsewhere, offline install requires recording at least:
- chart name,
- chart version,
- chart source (upstream URL or internal OCI reference),
- digest/hash of the chart artifact (or rendered-manifest hash if using pre-rendered YAML),
- and the rendering toolchain versions used (Helm/Kustomize/Argo).

## Vulnerability scanning in air-gapped mode (ARC + DB custody)

Vulnerability scanning is only meaningful offline if the scanner database is also handled as an artefact.

Design contract:
- Scanning (whether done by Harbor’s scanner integration or ARC’s pipeline) must be able to run without reaching the internet.
- Database updates become an explicit input:
  - imported when connectivity exists, or
  - shipped as part of the offline bundle.
- Image scope for centralized Trivy CI should come from the same two curated artifact catalogs used to build the bundle, so “what we scan before shipping” and “what we export offline” stay aligned.

This avoids a “we’re offline, so scanning silently stops” trap.

## Multi-tenancy and roadmap compatibility

This design avoids blocking the cloud roadmap by:
- keeping the offline install pipeline purely “bootstrap + seed + reconcile” (no bespoke per-tenant workflows),
- making artefact sourcing a deployment-level contract (portable to per-tenant clusters later),
- and aligning with the supply-chain and marketplace direction (curated ingress + approvals rather than ambient internet pulls).

## Quality gates (required)

To prevent “offline” from rotting over time, the repo must add mechanical gates (exact implementation is tracked under distribution bundles):

- Fail when bootstrap scripts try to apply remote manifests:
  - example check: reject `kubectl apply -f http(s)://...` under `shared/scripts/**` (excluding docs/tests).
- Fail when offline-mode GitOps payload references public registries:
  - example check: reject `registry.example.internal/`, `docker.io/`, `quay.io/`, `registry.k8s.io/` under `platform/gitops/**` for Mode C builds, with an explicit allowlist/exception model.
- Fail when offline-mode rendering requires public Helm repos:
  - example check: reject Argo Helm `repoURL: https://...` and Kustomize `helmCharts.repo:` pointing at public sources for Mode C builds.
- Fail when a deployable supported platform image is not present in either curated artifact catalog:
  - `package-index.yaml`
  - `runtime-artifact-index.yaml`

These gates must be paired with evidence: an end-to-end Stage 0 → Stage 1 → first reconcile run with public network disabled.

## Evidence expectations

To claim “fully offline bootstrap” we need evidence (dev first, then prod) that:
- Stage 0 completes with internet disabled.
- Stage 1 completes with internet disabled.
- `platform-apps` reaches `Synced Healthy` without public egress.
- A minimal tenant workload can build/push/pull from the internal registry without public egress.

Evidence should be captured under `docs/evidence/` per the repo’s evidence discipline.
