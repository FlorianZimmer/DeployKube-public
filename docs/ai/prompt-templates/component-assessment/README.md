# Component Assessment Prompt Templates

These templates are designed for repeated, topic-specific assessments of DeployKube components or project-wide scope.

## Usage

1. Pick one topic prompt file.
2. Replace the runtime placeholders in that prompt:
- `<TARGET_SCOPE>`: `component` or `project`
- `<COMPONENT_NAME>`: tracker file stem used for `docs/component-issues/<...>.md` (often the `issue_slug` from `component-catalog.tsv`; may match the component slug) or `NA` for project-wide reviews
- `<COMPONENT_PATH>`: repo-relative path or `NA`
- `<RUNTIME_CONTEXT>`: the manifests/docs/logs/outputs being assessed
3. Run one prompt per topic to keep the review focused.

## Execution Framework (project-wide runs)

For high-accuracy project-wide execution with strict component isolation, use:

- Runbook: `docs/ai/prompt-templates/component-assessment/execution-framework.md`
- Catalog (assessment units): `docs/ai/prompt-templates/component-assessment/component-catalog.tsv`
- Catalog validator: `./scripts/dev/component-assessment-catalog-check.sh`
- Workpack generator: `./scripts/dev/component-assessment-workpack.sh`

The framework generates per-component workpacks with:
- all topic prompts rendered for that component
- component-scoped context manifests (`context/file-list.txt`)
- result/consolidation skeletons

It does **not** auto-analyze components or update issue trackers by itself.

## Mandatory Output Contract (applies to every prompt)

- Emit only two issue classes: `actionable` and `architectural` (as JSON fields in the `Findings` block).
- If the topic is not relevant for the target **or** cannot be assessed without guessing due to insufficient evidence in the provided context (e.g., excluded by workpack allowlists), output `NA` using the NA format in the prompt (Reason must state why).
- Output must be exactly the topic prompt’s required format (no extra preamble, explanations, or additional sections).
- The NA Reason must be one clear sentence (e.g., "Not applicable" or "Insufficient evidence in provided context").
- Evidence must be grounded in the provided context; include file path + resource (kind/name) + YAML key path.
  For “missing config” findings, explicitly state “field not present” tied to a specific resource.
- Evidence for each finding should include repo-relative file path(s) and pinpoint details (config keys, routes, flags, or line references) so it can be verified quickly.
- Do not emit any third issue category/class beyond `actionable` and `architectural`.
- Every non-NA finding must include concrete evidence from the provided context (or be marked incomplete by leaving evidence empty, which will be treated as low-confidence during promotion).
- Do not include secret values or credential material in outputs or evidence excerpts; redact as `***REDACTED***` while still citing file paths and key/resource names.
- `track_in` must be a concrete repo path (do not output `NA` or unresolved placeholders).
- If `<TARGET_SCOPE>=project`, do not use `<COMPONENT_NAME>` for tracker paths; use the project-wide tracker:
  - `docs/component-issues/cloud-productization-roadmap.md`
- For component scope, use the single canonical tracker:
  - `docs/component-issues/<COMPONENT_NAME>.md`
- Output must not include any extra preamble or additional categories beyond the template’s NA/Applicable formats (including no extra markdown).
- Note: `<COMPONENT_NAME>` refers to the tracker slug used in `docs/component-issues/` filenames (workpacks should populate it from the catalog `issue_slug`), not necessarily the human-facing component id.

## Findings Format (v1)

When `Relevance: Applicable`, prompts emit findings as JSONL under the line `Findings (JSONL):`:

- One JSON object per line.
- Use `class: actionable|architectural`, `severity: critical|high|medium|low`, and include stable evidence anchors (`path`, `resource`, `key`) when possible.

This format is designed so `./scripts/dev/component-assessment-promote.sh` can auto-promote findings into `docs/component-issues/*` deterministically.
