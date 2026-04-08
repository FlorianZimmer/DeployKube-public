# Evidence: Trivy CI repo-owned image catalog enforcement

EvidenceFormat: v1
Date: 2026-03-11
Environment: repo-only

## Scope / ground truth

- Ground truth for the new enforcement lives in `tests/scripts/validate-trivy-repo-owned-image-coverage.sh`.
- Ground truth for the curated package boundary lives in `platform/gitops/artifacts/package-index.yaml`.
- Ground truth for explicit exceptions lives in `tests/fixtures/trivy-repo-owned-image-exemptions.txt`.
- Ground truth for deployment-contract suite wiring lives in `tests/scripts/ci.sh`.

## What changed

- Added `validate-trivy-repo-owned-image-coverage.sh` to scan deployable `platform/gitops/**` YAML for `image:` and `repository:` refs under `registry.darksite.cloud/florianzimmer/deploykube/*`.
- Wired the validator into the `deployment-contracts` CI suite so repo-owned image coverage now fails in the same contract lane as the existing centralized Trivy validators.
- Added an explicit exemption file for repo-owned images that are intentionally outside the centralized package-index contract today.
- Updated contributor/design/tracker docs so new deployable repo-owned images must either enter `platform/gitops/artifacts/package-index.yaml` or be called out in the exemption file.

## Validation commands

```bash
./tests/scripts/validate-trivy-repo-owned-image-coverage.sh
./tests/scripts/validate-security-scanning-contract.sh
./tests/scripts/ci.sh deployment-contracts
git diff --check
```

Result:

```text
validate-trivy-repo-owned-image-coverage.sh passed
validate-security-scanning-contract.sh passed
./tests/scripts/ci.sh deployment-contracts passed with the new validator included
git diff --check passed
```
