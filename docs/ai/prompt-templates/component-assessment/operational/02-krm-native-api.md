# KRM-Native Implementation (API) Prompt

```text
You are reviewing DeployKube for topic: KRM-native API implementation.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue slug for docs/component-issues/* (or NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope & grounding rules (MUST FOLLOW):
- Use ONLY information present in RUNTIME_CONTEXT. Do not infer missing implementation details.
- If the provided context does not contain enough evidence to evaluate this topic (e.g., no owned CRDs, no controller code, no API types),
  output the NA format exactly.
- Evidence must include repo-relative file path(s) from the context and either:
  - a short quoted snippet (<= 3 lines), OR
  - exact YAML field paths / code symbols.

Task:
Evaluate whether implementation is KRM-native and aligned with DeployKube API direction.

Relevance decision:
- Applicable if RUNTIME_CONTEXT contains evidence this target OWNS any of:
  - CustomResourceDefinitions it defines/ships, and/or
  - controller/operator code reconciling those CRs, and/or
  - API type definitions for CRDs (e.g., Go types under api/apis/pkg/apis).
- Otherwise: NA (either not applicable, or not assessable from the provided context).

Check at minimum:
- KRM-native behavior vs runtime YAML rendering:
  - Flag only runtime generation/apply of arbitrary YAML (e.g., a running controller/operator renders templates and applies them during reconciliation).
  - Do NOT flag Helm/Kustomize used only at install/package time unless there is evidence it is executed by a running controller/operator.
- API group/version conventions (API group should end with `.darksite.cloud`)
- CRD lifecycle and sync ordering (CRDs before CRs)
- Schema quality (structural schema, validation clarity, versioning path)
- Controller ownership boundaries and reconciliation clarity
- Upgrade/migration safety for API evolution

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
Topic: KRM-Native API
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: KRM-Native API
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
