# Evidence: 2026-03-08 - component-assessment validation-jobs prompt

## Scope

- Added a first-class component-assessment prompt for validation jobs and smoke coverage.
- Added a first-class component-assessment prompt for operations/runbooks/usability, using the docs allowlist because it includes both implementation files and matched docs.
- Updated the execution-framework prompt-set description so `code` no longer implies only operational prompts 01-09.
- Clarified prompt boundaries so assessments distinguish:
  - pre-merge CI structural checks
  - workflow-driven runtime E2E / mode-matrix coverage
  - in-cluster smoke/validation Jobs and CronJobs

## Files changed

- `docs/ai/prompt-templates/component-assessment/operational/07-ci-checks-thoroughness.md`
- `docs/ai/prompt-templates/component-assessment/operational/12-validation-jobs-and-smoke-coverage.md`
- `docs/ai/prompt-templates/component-assessment/operational/13-operations-runbooks-and-usability.md`
- `docs/ai/prompt-templates/component-assessment/operational/10-documentation-coverage-and-freshness.md`
- `docs/ai/prompt-templates/component-assessment/operational/05-monitoring-alarming-observability.md`
- `docs/ai/prompt-templates/component-assessment/execution-framework.md`
- `scripts/dev/component-assessment-workpack.sh`

## Validation commands

```bash
bash -n./scripts/dev/component-assessment-workpack.sh./scripts/dev/component-assessment-catalog-check.sh./scripts/dev/component-assessment-workpack.sh \
  --component certificates-smoke-tests \
  --prompt-set code \
  --run-id validation-jobs-prompt-smoke./scripts/dev/component-assessment-workpack.sh \
  --component certificates-smoke-tests \
  --prompt-set docs \
  --run-id ops-usability-prompt-smoke
```

## Results

- `bash -n./scripts/dev/component-assessment-workpack.sh`
  - exited successfully
- `./scripts/dev/component-assessment-catalog-check.sh`
  - `Rows: 42 (enabled: 42, disabled: 0)`
  - `Validation: OK`
- `./scripts/dev/component-assessment-workpack.sh --component certificates-smoke-tests --prompt-set code --run-id validation-jobs-prompt-smoke`
  - `Generated components: 1`
  - `Templates per component: 26`
  - `Index: tmp/component-assessment/validation-jobs-prompt-smoke/index.tsv`
- Generated prompt present at:
  - `tmp/component-assessment/validation-jobs-prompt-smoke/certificates-smoke-tests/prompts/operational-12-validation-jobs-and-smoke-coverage.md`
- `./scripts/dev/component-assessment-workpack.sh --component certificates-smoke-tests --prompt-set docs --run-id ops-usability-prompt-smoke`
  - `Generated components: 1`
  - `Templates per component: 3`
  - `Index: tmp/component-assessment/ops-usability-prompt-smoke/index.tsv`
- Generated docs/ops prompt present at:
  - `tmp/component-assessment/ops-usability-prompt-smoke/certificates-smoke-tests/prompts/operational-13-operations-runbooks-and-usability.md`
- Verified docs/ops prompt uses:
  - `tmp/component-assessment/ops-usability-prompt-smoke/certificates-smoke-tests/context/file-list.docs.txt`
  - this allowlist includes both implementation files under `platform/gitops/components/**` and matched docs such as `docs/runbooks/**` and `docs/design/**`
