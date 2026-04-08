# Evidence: 2026-02-21 — component assessment execution framework setup

EvidenceFormat: v1

Date: 2026-02-21
Environment: repo-only

Scope / ground truth:
- setup of a concrete execution framework for component-assessment prompt templates
- no component analysis execution
- no changes to `docs/component-issues/*.md` findings content

Git:
- Commit: 0bafb20f000091b9ea1220a8a2f341367f312d97

Argo:
- Root app: platform-apps
- Sync/Health: N/A
- Revision: N/A

## What changed

- Added catalog of assessment units:
  - `docs/ai/prompt-templates/component-assessment/component-catalog.tsv`
- Added execution runbook:
  - `docs/ai/prompt-templates/component-assessment/execution-framework.md`
- Added catalog validator script:
  - `scripts/dev/component-assessment-catalog-check.sh`
- Added workpack generator script:
  - `scripts/dev/component-assessment-workpack.sh`
- Updated prompt-template README with framework entrypoints:
  - `docs/ai/prompt-templates/component-assessment/README.md`
- Updated scripts index with framework helpers:
  - `scripts/README.md`

## Commands / outputs

```bash
bash -n scripts/dev/component-assessment-catalog-check.sh scripts/dev/component-assessment-workpack.sh./scripts/dev/component-assessment-catalog-check.sh./scripts/dev/component-assessment-workpack.sh --component argocd --run-id framework-smoke-one./scripts/dev/component-assessment-workpack.sh --all --run-id framework-smoke-all
```

Output:

```text
Catalog: docs/ai/prompt-templates/component-assessment/component-catalog.tsv
Rows: 42 (enabled: 35, disabled: 7)
Validation: OK

Workpack run id: framework-smoke-one
Output root: tmp/component-assessment/framework-smoke-one
Generated components: 1
Skipped (disabled in catalog): 0
Skipped (not selected): 41
Templates per component: 19
Index: tmp/component-assessment/framework-smoke-one/index.tsv

Workpack run id: framework-smoke-all
Output root: tmp/component-assessment/framework-smoke-all
Generated components: 35
Skipped (disabled in catalog): 7
Skipped (not selected): 0
Templates per component: 19
Index: tmp/component-assessment/framework-smoke-all/index.tsv
```

## Notes

- Disabled catalog rows are intentional and represent units without a canonical issue tracker mapping yet.
- Workpack generation only prepares prompts/context contracts and result skeletons under `tmp/component-assessment/`; it does not perform analysis.
