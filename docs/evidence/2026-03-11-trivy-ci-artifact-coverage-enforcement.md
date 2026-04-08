# Evidence: Trivy CI artifact coverage enforcement

EvidenceFormat: v1
Date: 2026-03-11
Environment: repo-only

## Scope / ground truth

- Ground truth for the new enforcement lives in `tests/scripts/validate-security-scanning-contract.sh`.
- Ground truth for PR alarm coverage lives in `.github/workflows/security-scanning.yml`.
- Ground truth for the curated artifact boundary lives in `platform/gitops/artifacts/package-index.yaml`.

## What changed

- Extended `validate-security-scanning-contract.sh` to fail when:
  - a `PackageIndex` image is not covered by the default centralized Trivy aggregate set
  - a declared centralized Trivy `watch_path` is not covered by `.github/workflows/security-scanning.yml` `pull_request.paths`
- Extended `.github/workflows/security-scanning.yml` `pull_request.paths` to include the new `scim-bridge` image/build/publish paths so PRs touching that artifact now trigger the scanning workflow.
- Updated contributor/design/tracker docs to record the new CI contract.

## Validation commands

```bash
./tests/scripts/validate-security-scanning-contract.sh
git diff --check
```

Result:

```text
validate-security-scanning-contract.sh passed

New enforcement confirmed:
- shared and component Trivy watch paths are covered by workflow pull_request.paths
- every image in platform/gitops/artifacts/package-index.yaml is covered by the default aggregate profile set

git diff --check passed
```
