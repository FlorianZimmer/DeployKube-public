# Distribution Bundles Issues

## Design

- `docs/design/distribution-bundles.md`
- `docs/design/offline-bootstrap-and-oci-distribution.md`

## Open

- Implement the new two-surface artifact-governance contract for bundle inputs:
  - keep `platform/gitops/artifacts/package-index.yaml` for product-owned artifacts
  - add `platform/gitops/artifacts/runtime-artifact-index.yaml` for curated third-party runtime artifacts
- Make both catalogs the shared inputs for:
  - bundle BOM/export
  - offline registry preload/mirror preflight
  - `THIRD_PARTY_NOTICES.md` / corresponding-source compliance material
- Keep bundle ownership narrow and explicit:
  - this tracker owns bundle/BOM/export, offline preload, mirror/preflight, and notice/compliance consumers of the two catalogs
  - centralized Trivy CI already consumes the same artifact contract and is tracked in `docs/component-issues/security-scanning.md`

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### product-decisions-must-be-explicit
- Decide how we handle GPL/AGPL compliance in Mode C (ship corresponding source vs written offer vs “customer pulls upstream sources”). (ids: `dk.ca.finding.v1:distribution-bundles:15fb1b0d3a640744ef1cbc2cba83682d5ccce38e6715c16949e7d47042ecd2dd`)

#### technical-design-follow-ups
- Add a repo lint/gate that fails PRs when new components are introduced without license categorization (THIRDPARTYNOTICES.md / BOM metadata). (ids: `dk.ca.finding.v1:distribution-bundles:d4818923530768e60c24ba38a32beff83d1b983c4d1da67812dae0a3fa5e7529`)

- Choose the air-gapped rendering strategy (vendored charts vs internal Helm/OCI registry vs pre-rendered YAML) and the promotion path to the preferred long-term approach. (ids: `dk.ca.finding.v1:distribution-bundles:371302b5a8ef7920db3e57bdd5f410d7ca37e2f42d118926070935583239dd71`)

- Define how the bundle injects artefacts into the target environment (registry loading, chart hosting, git seeding). (ids: `dk.ca.finding.v1:distribution-bundles:29bbe7d4ca569f1afee7ed1398e66b9bef3cdc90413551290dfce05c375583c1`)

- Define the bootstrap registry + cutover contract (endpoint, trust/TLS posture, kind/Talos wiring, and when/how Harbor becomes the durable store). (ids: `dk.ca.finding.v1:distribution-bundles:31dc78f510348f0749c825b80055fff00edc405013d81bc224937c73bf13fc5b`)

### Medium

#### evidence-testing
- Add a repeatable “bundle build” smoke and capture evidence for at least one Mode B build. (ids: `dk.ca.finding.v1:distribution-bundles:a19ea52ae3b82717bf34079741c39312fe606fcfa7ef80af36466822a85b38ab`)

- For Mode C: prove an end-to-end install with public network disabled (dev first), with recorded evidence. (ids: `dk.ca.finding.v1:distribution-bundles:69c5fe8572028512de7521ad5261c66b461197046c80ce8a4a36f25c46eec7a9`)

#### technical-design-follow-ups
- Define the on-disk bundle format (bundle.yaml + bom.json schema, folder layout, versioning). (ids: `dk.ca.finding.v1:distribution-bundles:0b98aaea62159acf6ea8062ac44f9fdc6be9fa7b3b21d74303c4d72877631d58`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Decide how we handle **GPL/AGPL** compliance in Mode C (ship corresponding source vs written offer vs \u201ccustomer pulls upstream sources\u201d).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:15fb1b0d3a640744ef1cbc2cba83682d5ccce38e6715c16949e7d47042ecd2dd", "last_seen_at": "2026-02-25", "recommendation": "Decide how we handle GPL/AGPL compliance in Mode C (ship corresponding source vs written offer vs \u201ccustomer pulls upstream sources\u201d).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide how we handle GPL/AGPL compliance in Mode C (ship corresponding source vs written offer vs \u201ccustomer pulls upstream sources\u201d).", "topic": "product-decisions-must-be-explicit"}
{"class": "actionable", "details": "- Define the on-disk bundle format (`bundle.yaml` + `bom.json` schema, folder layout, versioning).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:0b98aaea62159acf6ea8062ac44f9fdc6be9fa7b3b21d74303c4d72877631d58", "last_seen_at": "2026-02-25", "recommendation": "Define the on-disk bundle format (bundle.yaml + bom.json schema, folder layout, versioning).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define the on-disk bundle format (bundle.yaml + bom.json schema, folder layout, versioning).", "topic": "technical-design-follow-ups"}
{"class": "actionable", "details": "- Define the **bootstrap registry + cutover** contract (endpoint, trust/TLS posture, kind/Talos wiring, and when/how Harbor becomes the durable store).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:31dc78f510348f0749c825b80055fff00edc405013d81bc224937c73bf13fc5b", "last_seen_at": "2026-02-25", "recommendation": "Define the bootstrap registry + cutover contract (endpoint, trust/TLS posture, kind/Talos wiring, and when/how Harbor becomes the durable store).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define the bootstrap registry + cutover contract (endpoint, trust/TLS posture, kind/Talos wiring, and when/how Harbor becomes the durable store).", "topic": "technical-design-follow-ups"}
{"class": "actionable", "details": "- Choose the air-gapped rendering strategy (vendored charts vs internal Helm/OCI registry vs pre-rendered YAML) and the promotion path to the preferred long-term approach.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:371302b5a8ef7920db3e57bdd5f410d7ca37e2f42d118926070935583239dd71", "last_seen_at": "2026-02-25", "recommendation": "Choose the air-gapped rendering strategy (vendored charts vs internal Helm/OCI registry vs pre-rendered YAML) and the promotion path to the preferred long-term approach.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Choose the air-gapped rendering strategy (vendored charts vs internal Helm/OCI registry vs pre-rendered YAML) and the promotion path to the preferred long-term approach.", "topic": "technical-design-follow-ups"}
{"class": "actionable", "details": "- Define how the bundle injects artefacts into the target environment (registry loading, chart hosting, git seeding).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:29bbe7d4ca569f1afee7ed1398e66b9bef3cdc90413551290dfce05c375583c1", "last_seen_at": "2026-02-25", "recommendation": "Define how the bundle injects artefacts into the target environment (registry loading, chart hosting, git seeding).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define how the bundle injects artefacts into the target environment (registry loading, chart hosting, git seeding).", "topic": "technical-design-follow-ups"}
{"class": "actionable", "details": "- Add a repo lint/gate that fails PRs when new components are introduced without license categorization (`THIRD_PARTY_NOTICES.md` / BOM metadata).\n  - Add specific offline-mode \u201cno implicit network fetch\u201d gates (no `kubectl apply -f https://...`, no public registries, no public Helm repos).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:d4818923530768e60c24ba38a32beff83d1b983c4d1da67812dae0a3fa5e7529", "last_seen_at": "2026-02-25", "recommendation": "Add a repo lint/gate that fails PRs when new components are introduced without license categorization (THIRDPARTYNOTICES.md / BOM metadata).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Add a repo lint/gate that fails PRs when new components are introduced without license categorization (THIRDPARTYNOTICES.md / BOM metadata).", "topic": "technical-design-follow-ups"}
{"class": "actionable", "details": "- Add a repeatable \u201cbundle build\u201d smoke and capture evidence for at least one Mode B build.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:a19ea52ae3b82717bf34079741c39312fe606fcfa7ef80af36466822a85b38ab", "last_seen_at": "2026-02-25", "recommendation": "Add a repeatable \u201cbundle build\u201d smoke and capture evidence for at least one Mode B build.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Add a repeatable \u201cbundle build\u201d smoke and capture evidence for at least one Mode B build.", "topic": "evidence-testing"}
{"class": "actionable", "details": "- For Mode C: prove an end-to-end install with public network disabled (dev first), with recorded evidence.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:distribution-bundles:69c5fe8572028512de7521ad5261c66b461197046c80ce8a4a36f25c46eec7a9", "last_seen_at": "2026-02-25", "recommendation": "For Mode C: prove an end-to-end install with public network disabled (dev first), with recorded evidence.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "For Mode C: prove an end-to-end install with public network disabled (dev first), with recorded evidence.", "topic": "evidence-testing"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **2026-03-11 – Artifact-governance direction documented for bundle compatibility:**
  - Distribution bundles now explicitly align with the planned two-catalog artifact model:
    - `package-index.yaml` for product-owned artifacts
    - `runtime-artifact-index.yaml` for curated third-party runtime artifacts
  - The design now requires bundle BOM/export, offline preload, centralized Trivy CI, and notice/compliance generation to consume the same artifact contract instead of drifting into subsystem-specific inventories.
- **2026-02-18 – Delivery timing decision (explicit deferral):**
  - Commercial shipping target remains **Mode C (air-gapped bundle)**.
  - Full Mode C productization is intentionally deferred until a customer-readiness trigger (first real customer pilot/pre-sales deployment), while active development continues on the current Phase 0 bootstrap bundle baseline.
  - Until the trigger, keep this tracker open and continue shipping incremental guardrails/tooling.
- **2026-02-18 – Secret-plane component decision for commercial bundles:**
  - Default/commercial bundle path is **OpenBao** (current implemented core secret plane), not HashiCorp Vault.
  - HashiCorp Vault (BSL) is treated as an optional customer-supplied/alternate path and is not part of the default bundle contract.
- **2026-02-18 – Example-apps distribution decision:**
  - Commercial bundles exclude example apps by default (`platform/gitops/apps/opt-in/examples-apps/` stays opt-in only).
- Phase 0: remove Stage 0 GitHub manifest apply for Gateway API (Stage 0 now uses the vendored manifest in `platform/gitops/components/networking/gateway-api/standard-install.yaml`).
- Phase 0: add initial offline bundle tooling (bootstrap profile):
  - `shared/scripts/offline-bundle-build.sh`
  - `shared/scripts/offline-bundle-load-registry.sh`
- Phase 0: remove public Helm repo dependencies for boot-critical GitOps apps:
  - `Application/networking-metallb` and `Application/storage-nfs-provisioner` now source vendored charts from Forgejo git.
- Phase 0: fix Forgejo seeding to include vendored artefacts even when `.gitignore` would exclude them (required for vendored Helm charts in the seeded GitOps repo).
- Phase 0: shared storage bootstrap smoke Jobs no longer depend on `busybox` image pulls (use `bootstrap-tools`, which is included in the bootstrap bundle set).
