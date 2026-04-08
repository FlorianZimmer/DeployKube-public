# Component Issues Schema (v1)

This repo treats each `docs/component-issues/<component>.md` as the single canonical artifact for that component's open items.

To enable deterministic automation (promotion, dedupe, suppression), each component issues file may include a machine-readable findings block.

## Machine-Readable Findings Block

Each component tracker can contain exactly one findings block delimited by these markers:

- `<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->`
- `<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->`

The block content is a fenced code block containing **JSONL** (one JSON object per line).

Example:

```md
## Component Assessment Findings (v1)

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"id":"dk.ca.finding.v1:observability:...","status":"open","class":"actionable","severity":"high","title":"Add PDBs for Loki/Tempo/Mimir","topic":"high-availability","template_id":"operational-01-high-availability.md","evidence":[{"path":"platform/gitops/.../loki/README.md","resource":"README","key":"PodDisruptionBudgets"}],"recommendation":"Add PDBs via values/patches and validate vs replicas.","first_seen_at":"2026-02-25","last_seen_at":"2026-02-25"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->
```

### Finding Object Fields (minimal)

Required:
- `id`: stable identifier (string)
- `status`: `open` | `suppressed` | `resolved`
- `class`: `actionable` | `architectural`
- `severity`: `critical` | `high` | `medium` | `low`
- `title`: short human title
- `topic`: stable topic slug (e.g. `auth-flow`, `high-availability`)
- `template_id`: assessment template identifier (usually the rendered prompt filename)
- `recommendation`: concise fix/refactor direction (string)
- `first_seen_at`: `YYYY-MM-DD`
- `last_seen_at`: `YYYY-MM-DD`

Optional:
- `evidence`: list of objects `{ "path": "...", "resource": "...", "key": "..." }`
- `details`: longer description
- `risk`: for architectural items
- `suppression`: `{ "reason": "...", "review_by": "YYYY-MM-DD" }`
- `links`: list of strings (e.g. evidence doc paths)

## Suppression Workflow

To explicitly ignore a finding without re-adding it on every promotion:
1. Keep the finding in the findings block.
2. Set `status` to `suppressed`.
3. Add `suppression.reason` (and optionally `suppression.review_by`).

The promotion script treats an existing finding id as already tracked regardless of status and will not create duplicates.

## Rendered Open Backlog (optional)

For a human-friendly backlog that stays in sync with the findings block, a component tracker may contain an additional
marker-delimited section under `## Open`:

- `<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->`
- `<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->`

This block is intended to be auto-written (LLM-rendered) from the findings JSONL block so humans can work from a
deduped list without editing JSONL directly.

Helper:
- `./scripts/dev/component-assessment-render-open.sh --run-dir <tmp/component-assessment/...>`

## Assessment Result Schema (v1)

Component assessment templates emit findings in a parseable format to support automated promotion.

Applicable format uses raw JSONL lines under `Findings (JSONL):` (no markdown fences; this avoids nested-fence issues in prompt templates):

```text
Topic: <topic>
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
```

Notes:
- Each JSON object represents one finding (either `actionable` or `architectural`).
- `evidence` should be stable and specific (file path + resource id + key path) to support stable IDs.
- `track_in` must be a concrete repo-relative path.
