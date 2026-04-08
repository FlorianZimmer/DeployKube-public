# Upgrade & Rollback Strategy Prompt

```text
You are reviewing DeployKube for topic: Upgrade and Rollback Strategy.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue slug for docs/component-issues/* (or NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- Do NOT assume release processes, test coverage, or compatibility guarantees unless explicitly shown.
- If you cannot find enough upgrade/rollback evidence in RUNTIME_CONTEXT to assess, output NA (Reason must say evidence is missing).

Task:
Evaluate whether this target can be upgraded and rolled back safely without breaking the platform.

Check at minimum (cite concrete evidence for each finding):
- Version pinning and upgrade path:
  - Explicit versions for charts/images/operators and a documented upgrade path.
  - Compatibility or target-stack references in scope.
- CRD and schema migrations:
  - Evidence of conversion strategy, backward compatibility, or migration jobs.
  - Sync-wave ordering that prevents CRs before CRDs.
- Stateful data migrations:
  - Upgrade steps for stateful components and rollback behavior.
  - Backup or migration safety steps where required.
- Rollback strategy:
  - Evidence of rollback procedures, feature flags, or safe downgrade paths.
  - Handling of irreversible migrations.
- Validation:
  - Tests or runbooks that validate upgrades/rollbacks (only if in scope).

Output rules:
- Output MUST be either the NA format or the Applicable format below. Do not add extra sections.
- Only two finding classes are allowed: actionable and architectural.
- For Applicable output, emit findings as JSONL (one JSON object per line) under `Findings (JSONL):`.
- Each JSON object MUST include:
  - class: actionable | architectural
  - severity: critical | high | medium | low
  - title: <short>
  - evidence: [{"path":"...","resource":"...","key":"..."}]  (may be [] only if evidence cannot be represented without guessing)
  - recommendation: <concrete fix (actionable) or refactor direction (architectural)>
  - track_in: <tracking target path (see below)>
- For architectural findings, include `risk` when possible.
- Every non-NA finding must include concrete evidence from RUNTIME_CONTEXT (file paths + resource identifiers + key paths). If evidence is insufficient, output NA.
- Redact secret values as `***REDACTED***`.
- If Applicable but you find no findings, output `Findings (JSONL):` with zero JSONL lines following it.

Tracking targets (choose based on TARGET_SCOPE; set `track_in` accordingly):
- If TARGET_SCOPE=component: docs/component-issues/<COMPONENT_NAME>.md
- If TARGET_SCOPE=project: docs/component-issues/cloud-productization-roadmap.md
- Never output docs/component-issues/NA.md.

NA format:
Topic: Upgrade and Rollback Strategy
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Upgrade and Rollback Strategy
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
