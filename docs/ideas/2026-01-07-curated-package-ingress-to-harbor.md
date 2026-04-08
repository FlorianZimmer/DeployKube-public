# Idea: Curated Package Ingress to Harbor (Scan + Approval Gate)

Date: 2026-01-07
Status: Draft

## Problem statement

DeployKube aims to run in environments where:
- outbound internet access is restricted or fully disabled (air-gapped), and
- supply-chain posture matters (CVE scanning, provenance, audit trail), and
- the platform should **not** depend on every node pulling from public registries at runtime.

Today, DeployKube has **local registry cache helpers** (dev) that reduce repeated pulls and can warm caches from repo image references, but this does not provide a durable, policy-controlled “ingress” mechanism for:
- curated imports from the internet into a **first-class local registry** (e.g., Harbor),
- consistent scanning + promotion of artifacts,
- explicit approvals and an audit trail for what entered the environment.

## Why now / drivers

- Harbor (or an equivalent in-cluster registry) is a likely future baseline (`target-stack.md` lists it as planned).
- Hardening “what can be pulled” becomes more important as multi-tenant posture evolves (policy engine, restricted namespaces, etc.).
- GitOps wants artifacts to be treated like inputs with an explicit review/approval story, not an ambient side effect of pods pulling from the internet.

## Proposed approach (high-level)

Introduce an explicit **Package Ingress Pipeline** that turns “external artifacts on the internet” into “approved internal artifacts in Harbor”.

### 1) Declare desired external artifacts in Git (the allowlist)

Add a repo-owned “package index” describing allowed upstream artifacts and how they map into Harbor:
- Container images (`registry/repo:tag` + pinned digest once approved)
- Helm charts (OCI charts, or chart archives mirrored into an OCI repo)
- Optional: other OCI artifacts (SBOMs, attestation bundles, policy bundles)

The index is the only input; it is reviewed like any other GitOps change (PR/merge).

### 2) Automation proposes updates; humans approve

Two complementary automation paths:
- **Update proposal bot**: periodically checks upstream for new versions and opens a PR updating pins (tags → digests, chart versions).
- **On-merge importer**: once the PR is approved/merged, an importer job pulls the referenced artifacts and pushes them into Harbor.

This keeps “internet reads” and “approval to import” separable: the cluster only ingresses what Git has approved.

### 3) Scan + policy gate on ingest

On import:
- Run CVE scanning (Harbor’s scanner, or an explicit Trivy scan job) and store results.
- Optionally generate and store SBOMs (e.g., Syft) alongside the artifact.
- Enforce a policy gate (severity thresholds, allowlists, exceptions with evidence).
- Store a machine-readable “ingress report” (what was imported, from where, with what digest, scan summary).

### 4) Provenance and “pull only from Harbor” enforcement

Once Harbor exists:
- Prefer storing artifacts under internal names and referencing them from GitOps manifests (images/charts come from Harbor).
- Optionally sign imported artifacts (Cosign) and enforce signature verification in-cluster.
- Use policy (Kyverno / admission policies) to restrict workloads to approved registries/projects.

## What is already implemented (repo reality)

- Dev has local registry caches and image warming (`shared/scripts/local-registry-cache.sh`, `shared/scripts/registry-sync.sh`; see `docs/guides/mac-orbstack.md`).
- GitOps boundary is strict: steady state changes should land under `platform/gitops/**` and be reconciled by Argo CD.
- There is an existing evidence discipline and documentation structure for introducing new platform workflows (`docs/evidence/**`, `docs/design/**`).

## What is missing / required to make this real

### A) Decide artifact scope and lifecycle

- What counts as a “package” for this pipeline (images only vs images + charts + OCI bundles)?
- How versions are pinned (digest-only vs tag+digest; how rollbacks work).
- How to handle retention/garbage collection (keep N versions; keep promoted versions only).

### B) Pick the implementation substrate

Potential implementation shapes (not mutually exclusive):
- A dedicated GitOps component that installs an importer controller + CRDs (e.g., `PackageImport` resources).
- A scheduled Job/CronJob driven by a ConfigMap/Secret containing the allowlist.
- A Forgejo Actions runner / in-cluster CI runner that performs the import on PR merge.
- Adopt an existing open-source “artifact gateway” that already targets restricted environments and policy-driven transfers, e.g. **Artifact Conduit (ARC)**: <https://github.com/opendefensecloud/artifact-conduit>.

Constraints to capture explicitly:
- internet egress restrictions (which namespaces/pods are allowed egress, and how that is enforced),
- credentials custody for upstream registries (Vault + ESO),
- ability to run in dev (easy) and prod (hardened) with minimal divergence.

#### Artifact Conduit (ARC) as a candidate building block

The public repo `opendefensecloud/artifact-conduit` (“ARC”) is explicitly scoped as an orchestration/gateway layer for procuring artifacts (OCI images, Helm charts, etc.) into restricted environments with automated scanning/validation, policy enforcement, and auditability. This aligns closely with the goals of this idea doc (ingress + scanning + approval/audit trail) while still allowing Harbor to remain the durable in-cluster registry.

Open fit questions to resolve before adopting ARC:
- Can ARC be configured to treat the DeployKube “package index” as the sole desired-state input (Git-reviewed allowlist)?
- Can ARC push artifacts into Harbor projects/repositories in a way that fits DeployKube’s naming + promotion model?
- Which scanners/validators are supported, and how do their outputs map into the desired “ingress report” contract?
- What are ARC’s operational requirements (CRDs/controllers, storage, DB, HA assumptions) and how do they fit dev vs proxmox-talos?

### C) Define “ingress report” + audit surface

Minimum outputs per imported artifact:
- upstream ref + resolved digest
- internal Harbor ref
- scan timestamp + scanner version
- summary counts by severity + policy decision (pass/fail/exception)
- link to evidence note when an exception is approved

### D) Tie into policies and GitOps ergonomics

- A clear pattern for how GitOps manifests reference imported artifacts (images/charts point to Harbor).
- A policy story for preventing “bypass” (workloads pulling directly from public registries).
- A “breakglass” story (manual import with evidence note).

## Risks / weaknesses

- Complexity: building a robust importer + policy engine integration is non-trivial.
- Scanning reality: CVE results are noisy; exception handling needs a disciplined process to avoid “ignore forever”.
- Storage cost: mirroring images/charts increases required registry storage and retention management.
- Supply chain edge cases: multi-arch images, signature/provenance mismatch, rate limits, auth failures.

## Alternatives considered

- **Pull-through cache only** (status quo-ish): simpler, but doesn’t provide explicit approvals, durable artifacts, or a strong policy gate.
- **Harbor replication rules**: can mirror registries, but tends to be coarse-grained and may not map cleanly to Git-reviewed allowlists + per-artifact approval.
- **Out-of-cluster CI-only** (GitHub Actions): strong control/audit in GitHub, but less aligned with “in-cluster / air-gapped” operation and may not work offline.
- **Offline distribution bundles** (tarballs/ISOs): best for fully air-gapped, but heavier operational workflow; may still benefit from the same index + scanning pipeline.

## Open questions

- Do we want a single global allowlist, or per-environment/project allowlists?
- What is the approval model?
  - PR approval only, or an additional “two-person import” gate?
- Where do we run the importer (in-cluster with limited egress, or external “staging” that pushes into Harbor)?
- What is the minimum acceptable policy gate (severity threshold, fix availability, exploitability signals)?
- How do we handle CRDs/operators that ship as Helm charts with embedded images (chart import + image import coupling)?

## Promotion criteria (to `docs/design/**`)

Promote once the following are specified and a thin end-to-end prototype exists:
- Harbor (or equivalent) is selected as the internal artifact store, with a documented project/namespace layout.
- A concrete “package index” schema is defined (images + optional charts) and stored in-repo.
- A working importer path exists (manual or automated) that:
  - resolves upstream → digest
  - imports into Harbor
  - produces an ingress report
  - runs scanning and enforces a policy gate
- A first policy enforcement step exists (at minimum: “workloads must pull from approved registries/projects”).
