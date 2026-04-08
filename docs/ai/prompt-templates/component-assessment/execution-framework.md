# Component Assessment Execution Framework

This framework is optimized for **analysis quality and accuracy**, not token minimization.

It prepares deterministic per-component workpacks so each assessment thread stays scoped to one component while still covering all categories.

## Threading model (recommended)

1. One thread per component.
2. Run all categories for that component in that same thread.
3. Consolidate/dedupe category findings before updating `docs/component-issues/*.md`.

Do not run all components in a single thread.  
Do not split one component into many category threads unless you must (it increases contradiction/merge risk).

## Inputs

- Templates:
  - `docs/ai/prompt-templates/component-assessment/operational/*.md`
  - `docs/ai/prompt-templates/component-assessment/security/*.md`
- Component catalog:
  - `docs/ai/prompt-templates/component-assessment/component-catalog.tsv`

Catalog columns:

1. `component_id`
2. `enabled` (`true|false`)
3. `issue_slug` (maps to `docs/component-issues/<issue_slug>.md`; this is the value templates expect as `<COMPONENT_NAME>` when emitting `Track in:` paths)
4. `primary_path` (file or directory)
5. `context_paths_csv` (comma-separated file and/or directory paths)
6. `notes`
7. `target_scope` (`component|project`; defaults to `component`)
8. `version_lock_mode` (`direct|shared|none|gap`)
9. `version_lock_refs_csv` (comma-separated `versions.lock.yaml` component ids; required for `direct|shared`, empty for `none`, optional for `gap`)

Note: The catalog column `issue_slug` maps to `docs/component-issues/<issue_slug>.md`. Workpacks populate `<COMPONENT_NAME>` from this value so tracker references resolve correctly. For `target_scope=project`, prompts should still route findings to `docs/component-issues/cloud-productization-roadmap.md`.

Version-lock coverage note:
- `direct`: this component owns one or more curated `versions.lock.yaml` entries.
- `shared`: this component is fully covered by shared curated lock entries owned elsewhere.
- `none`: this component has no component-local versioned surface that belongs in `versions.lock.yaml`.
- `gap`: version-lock coverage is still incomplete and should remain an open item in the component tracker.

## Setup commands

1. Validate catalog integrity:
```bash./scripts/dev/component-assessment-catalog-check.sh
```

2. Generate workpacks for all enabled components:
```bash./scripts/dev/component-assessment-workpack.sh --all
```

## Prompt Sets (Code vs Docs)

Some prompts are code/security-focused, others are docs-focused. To avoid wasting context tokens, you can run them separately:

- `--prompt-set code`: security prompts + all operational prompts except the docs-only prompts 10-11
  - includes the validation/smoke coverage prompt (`operational/12-validation-jobs-and-smoke-coverage.md`)
- `--prompt-set docs`: operational prompts 10-11, 13, and 14
  - docs coverage/freshness + design drift + operations/runbooks/usability + runtime E2E matrix/release gating
- `--prompt-set all`: everything (default)

Topic boundary note:
- `operational/07-ci-checks-thoroughness.md` assesses pre-merge CI and workflow-driven runtime E2E (including mode/flavor matrices).
- `operational/12-validation-jobs-and-smoke-coverage.md` assesses in-cluster validation `Job`/`CronJob`/Argo hook coverage and must not collapse that into "CI".
- `operational/10-documentation-coverage-and-freshness.md` assesses whether needed docs exist and match implementation.
- `operational/13-operations-runbooks-and-usability.md` assesses whether operators can actually execute the important workflows from those docs plus repo truth.
- `operational/14-runtime-e2e-matrix-and-release-gating.md` assesses cross-cutting workflow-driven mode/flavor matrices and release-tag gates that block shipment.

## Non-Interactive Automation (Codex CLI)

If you want a single command that generates workpacks and runs the evaluation non-interactively via Codex CLI (parallelized), use:

```bash./scripts/dev/component-assessment-codex-exec.sh --model <model> --mode full
```

This produces per-prompt results under:
- `tmp/component-assessment/<run-id>-code/<component>/outputs/category-results/*.md`
- `tmp/component-assessment/<run-id>-docs/<component>/outputs/category-results/*.md`

Promotion (optional):
- You can generate promotion candidates (net-new findings) without editing trackers:
  - `./scripts/dev/component-assessment-codex-exec.sh --model <model> --mode changed --execute --promote candidates`
- Or apply promotion automatically into `docs/component-issues/<component>.md` (machine-owned findings block):
  - `./scripts/dev/component-assessment-codex-exec.sh --model <model> --mode changed --promote apply`
  - Optional: also render a human-friendly Open backlog snippet (LLM-deduped) under `## Open`:
    - `./scripts/dev/component-assessment-codex-exec.sh --model <model> --mode changed --promote apply --render-open`

See `docs/component-issues/SCHEMA.md` for the tracker schema.

## Incremental runs (token minimization)

If you want to avoid re-running assessments for components whose implementation/docs context has not changed:

1. Generate a baseline run (recommended: include per-file fingerprints so you can later see what changed):
```bash./scripts/dev/component-assessment-workpack.sh --all --prompt-set code --run-id baseline-code./scripts/dev/component-assessment-workpack.sh --all --prompt-set docs --run-id baseline-docs
```

2. On a later run, generate workpacks only for components whose content fingerprint changed since that baseline:
```bash./scripts/dev/component-assessment-workpack.sh \
  --all \
  --prompt-set code \
  --only-changed-since tmp/component-assessment/baseline-code/fingerprints.tsv \
  --run-id delta-code \
  # per-file fingerprints are default-on; disable via --no-per-file-fingerprints if needed
```

3. Optional: also emit per-component changed file lists (A/M/D) when the baseline run contains `fingerprints/<component_id>.tsv`:
```bash./scripts/dev/component-assessment-workpack.sh \
  --all \
  --prompt-set code \
  --only-changed-since tmp/component-assessment/baseline-code/fingerprints.tsv \
  --run-id delta-code \
  --write-changed-files
```

Default behavior:
- For `--all` runs, if `<output_root>/_state/last-fingerprints-<prompt-set>.tsv` exists, the workpack generator automatically treats it as the baseline and skips unchanged components (unless you pass `--no-incremental`).
- The baseline is updated for `--all` runs (even if the worktree is dirty) to support local incremental loops; when the worktree is clean the baseline is also archived under `<output_root>/_state/by-commit/<git_commit>/<prompt-set>/`.

Artifacts:
- `tmp/component-assessment/<run-id>/fingerprints.tsv`: per-component fingerprint index (includes `git_commit` and `worktree_clean` metadata).
- `tmp/component-assessment/<run-id>/fingerprints/<component_id>.tsv`: per-file sha256 manifest (default on; disable via `--no-per-file-fingerprints`).
- `tmp/component-assessment/<run-id>/changed-files/<component_id>.tsv`: per-file change list vs baseline (only with `--write-changed-files`).
- `tmp/component-assessment/<run-id>/changed-components.tsv`: summary counts per component (only with `--write-changed-files`).

3. Generate workpacks for selected components only:
```bash./scripts/dev/component-assessment-workpack.sh \
  --component argocd \
  --component vault \
  --run-id focused-run
```

## Workpack structure

Each component gets:

- `meta.env`: normalized runtime placeholders and tracker targets
- `context/paths.txt`: allowed context path roots
- `context/file-list.code.txt`: concrete evidence allowlist for code/security prompts
- `context/file-list.docs.txt`: concrete evidence allowlist for docs prompts (only when `--prompt-set` includes docs)
- `context/file-list.txt`: backward-compat (same as `context/file-list.code.txt`)
- `context/context-contract.md`: strict scoping rules
- `prompts/*.md`: all rendered category prompts for that component
- `outputs/category-results/*.md`: per-category result skeletons
- `outputs/merge-template.md`: consolidation template for deduping

Run index:

- `tmp/component-assessment/<run-id>/index.tsv`

## Scope controls for high accuracy

1. Use only files from the allowlist referenced by the prompt (code prompts use `context/file-list.code.txt`, docs prompts use `context/file-list.docs.txt`).
2. If the category is not applicable **or** evidence is missing in the provided workpack context, return `NA` exactly per template (and set `Reason` explicitly).
   - “Evidence is missing” means the allowed context contains no relevant artifacts to evaluate for that category
     (e.g., no schedulable Kubernetes workloads/manifests for placement topics).
   - It does NOT mean “the artifact exists but lacks best-practice settings” — missing/weak settings are findings.
3. Keep findings grounded in concrete file evidence.
4. Deduplicate repeated findings across categories before writing trackers.
5. Keep all findings (actionable + architectural) in the single canonical component tracker: `docs/component-issues/<issue_slug>.md`.
6. Never copy secret values into `outputs/*` or `docs/component-issues/*`; reference file paths and redact values as `***REDACTED***`.

## Parallel execution with worktrees (optional)

If running multiple conversations/terminals in parallel, use AGENTS Mode B:

1. Create one task branch/worktree per component batch:
```bash./scripts/dev/task-new.sh assess-argocd origin/main
```
2. Run assessment updates in that worktree.
3. Merge with helper:
```bash./scripts/dev/task-merge.sh task/assess-argocd main --delete-remote
```

## Notes on catalog governance

If a unit is set to `enabled=false`, treat it as intentionally excluded from automated workpack generation until ownership is clear.

Before re-enabling:

1. Define/confirm the canonical `docs/component-issues/<slug>.md`.
2. Update `issue_slug` and `enabled` in catalog.
3. Re-run catalog validation.
