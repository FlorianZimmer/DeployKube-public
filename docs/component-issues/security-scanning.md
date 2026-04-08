# Security Scanning (CI) Issues

Tracks the repo/CI vulnerability-scanning plane for DeployKube.

Design:
- `docs/design/vulnerability-scanning-and-security-reports.md`
- `docs/design/supply-chain-pinning-policy.md`
- `docs/design/offline-bootstrap-and-oci-distribution.md`

## Open

- Define CI gate semantics:
  - explicit risk-acceptance/exception workflow in Git still needs to be defined
- Keep CI ownership narrow and explicit:
  - centralized Trivy CI owns scan/gate semantics, scheduled scan observability, and the CI-side use of the two artifact catalogs
  - `tests/trivy/components/*.yaml` should stay focused on config targets, watch paths, and ownership/grouping rather than becoming a second image inventory
- Define the CI-side contract for shared consumers of the two catalogs:
  - CI must consume the same artifact contract that bundle/export, mirror/preflight, and notice/compliance tooling use
  - bundle/BOM/export implementation ownership stays in `docs/component-issues/distribution-bundles.md`
- Add regression-oriented operator value beyond freshness/failure:
  - baseline severity drift alerting
  - a longer-term trend/report surface for accepted-risk reviews
- Make the Trivy DB update story compatible with offline bundles and mirrored/internal sources.

## Resolved

- **2026-03-11 – Full supported platform baseline is now covered by centralized CI Trivy:** the remaining uncovered platform components were added under the shared fragment model (`garage`, `metallb`, `nfs-provisioner`, and `valkey`), the runtime-artifact catalog was expanded to the remaining third-party platform images, and the standard aggregate profile set (`platform-core`, `platform-services`, `platform-foundations`) now provides full intended CI coverage for the supported platform baseline without new one-off wrappers.
- **2026-03-11 – Initial runtime-artifact catalog and catalog-backed image resolution implemented:** added `platform/gitops/artifacts/runtime-artifact-index.yaml`, taught `tests/scripts/scan-trivy-ci.sh` to resolve image targets from named artifact catalogs, migrated the active Argo CD, Forgejo, Keycloak, DNS, Istio/Kiali, and Step CA image targets onto that catalog, and extended `validate-security-scanning-contract.sh` to enforce coverage for both the product-owned and runtime artifact catalogs.
- **2026-03-11 – Two-surface artifact-governance direction documented:** the design now keeps `package-index.yaml` for product-owned artifacts and adds `runtime-artifact-index.yaml` for curated third-party runtime artifacts, with centralized Trivy CI expected to consume both in the same contract used by bundles, mirroring, and compliance tooling.
- **2026-03-11 – Repo-wide validator now catches uncatalogued DeployKube-owned images in GitOps manifests:** `validate-trivy-repo-owned-image-coverage.sh` scans deployable GitOps YAML for `registry.example.internal/deploykube/*` `image:`/`repository:` refs and fails unless each image is either curated in `platform/gitops/artifacts/package-index.yaml` or listed in an explicit exemption file.
- **2026-03-11 – Platform foundations coverage expanded:** added centralized Trivy fragments for `step-ca`, `external-secrets`, `dns`, `postgres`, `istio`, and `observability`, introduced the `platform-foundations` aggregate profile, expanded the default scheduled/push aggregate set, and generalized the CI dashboard/alerts from `platform-core` to all published inventories.
- **2026-03-11 – CI now fails on uncovered curated artifacts and unwatched Trivy fragment paths:** `validate-security-scanning-contract.sh` now enforces that every `platform/gitops/artifacts/package-index.yaml` image is present in the default aggregate profile set and that `.github/workflows/security-scanning.yml` `pull_request.paths` covers all centralized Trivy shared/component watch paths.
- **2026-03-11 – `scim-bridge` artifact contract and Trivy image coverage added:** `tools/scim-bridge` now has a packaged image build/publish path under `shared/images/scim-bridge`, the package index includes a canonical source ref plus Proxmox mirror rewrite, and the centralized `keycloak` fragment now scans the bridge image through the same package-index-driven contract used for local mirror validation.
- **2026-03-11 – Runtime-artifact scanning now follows curated distribution refs:** centralized Trivy CI now resolves `platform/gitops/artifacts/runtime-artifact-index.yaml` via `distribution_ref` instead of `source_ref`, so scans run against the curated shipped artifact path. The remaining blocked Dex and Kyverno images were moved onto `registry.example.internal/...` distribution refs, and `shared/scripts/registry-sync.sh` now mirrors `source_ref -> distribution_ref` for darksite-curated runtime artifacts.
- **2026-03-11 – Platform services coverage expanded:** added centralized Trivy fragments for `argocd`, `forgejo`, and `keycloak`, introduced the `platform-services` aggregate profile, and updated the workflow default aggregate set so push/schedule scans cover both `platform-core` and `platform-services`.
- **2026-03-11 – Component-fragment inventory and scoped PR scanning implemented:** refactored the centralized Trivy CI inventory into component-owned fragments under `tests/trivy/components/`, added changed-component resolution in `tests/scripts/resolve-trivy-ci-targets.sh`, and updated `.github/workflows/security-scanning.yml` so PRs scan only affected covered components while push/schedule/manual runs keep using aggregate profiles.
- **2026-03-11 – Centralized CI scanning baseline implemented:** added the repo-owned Trivy inventory `tests/trivy/central-ci-inventory.yaml`, generic runner `tests/scripts/scan-trivy-ci.sh`, Mimir metric publisher `tests/scripts/publish-trivy-ci-metrics.sh`, self-hosted workflow `.github/workflows/security-scanning.yml`, Grafana/Mimir alerting assets for freshness/failure, and a fast contract validator `tests/scripts/validate-security-scanning-contract.sh`.
- **2026-03-06 – Tactical cert-manager precursor shipped:** added a component-scoped Trivy image review wrapper plus evidence-backed scan process for cert-manager in `tests/scripts/scan-cert-manager-images.sh`. This proves the tool path works but does not yet constitute the central CI scanning plane.
