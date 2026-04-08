# Runtime E2E Matrix and Release Gating Prompt

```text
You are reviewing DeployKube for topic: runtime E2E matrix coverage and release gating.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- This prompt is intended primarily for project-scope or cross-cutting assessment units that own workflow-driven runtime E2E and release gating.
- Use this prompt to assess workflow-driven E2E against real clusters, especially when the stack has multiple runtime modes/flavors/config matrices.
- Do NOT collapse in-cluster smoke CronJobs into this topic; those belong to the validation-jobs/smoke prompt.
- Do NOT assess generic doc freshness here; only use docs as supporting evidence for how the gate is supposed to operate.
- If RUNTIME_CONTEXT does not include enough workflow/script/release-gate evidence to evaluate this topic, output NA.

Task:
Assess whether DeployKube has sufficient workflow-driven runtime E2E coverage for its important modes/flavors, and whether release-tag creation is actually blocked on the required gates.

Relevance test (choose one):
- Applicable if the target includes runtime E2E workflows/scripts, release-gate workflows/scripts, tag/release entrypoints, or docs describing multi-mode runtime validation.
- NA if the target is component-local without any workflow-driven runtime E2E or release-gating evidence in context.

Check at minimum (only when justified by evidence in context):
- Mode/flavor matrix coverage:
  - which modes/flavors/config permutations are covered by dedicated runtime E2E
  - whether quick PR profiles and full nightly/manual profiles are intentionally split
  - whether important flavors are missing, under-tested, or only implicitly covered
- Triggering and scope:
  - whether relevant PR path filters, schedules, and manual dispatch flows exist
  - whether the workflows are wired to the surfaces that actually change the behavior under test
- Runtime safety for matrix E2E:
  - explicit mutation acknowledgement for workflows that patch live config
  - rollback/restore of original state on exit
  - concurrency/serialization controls when singleton config is mutated
  - dedicated runner/cluster assumptions are explicit
- Evidence of real release gating:
  - release-tag or release-entrypoint scripts refuse to ship when the release E2E gate fails
  - tag creation is blocked on the exact target commit, not a stale branch head
  - any breakglass paths are explicit and bounded
- Relationship to the other validation planes:
  - pre-merge static CI is not pretending to prove runtime mode behavior
  - runtime E2E is not pretending to replace ongoing in-cluster smoke coverage
  - the split between quick/full/runtime smoke is intentional and understandable
- Growth readiness:
  - whether the current workflow/script layout can scale as more flavors are added
  - whether new flavor additions are likely to be forgotten because the gate surface is fragmented or undocumented
- Operator/contributor usability:
  - where a contributor/operator should look to understand which flavors are covered
  - whether runbooks/toils/release docs explain how to run or interpret the gate

Severity rubric:
- High: a release can be tagged without the required runtime gate, or important runtime flavors can regress without any dedicated E2E coverage
- Medium: matrix coverage exists but is incomplete, poorly targeted, unsafe, weakly gated, or likely to drift as flavors grow
- Low: clarity, maintainability, or discoverability improvements around an otherwise sound gate

Evidence rules (strict):
- Every finding must cite concrete workflow/script/release-entrypoint evidence from RUNTIME_CONTEXT.
- For “missing flavor coverage” findings, cite the matrix evidence you do have and explain which flavor/mode appears uncovered from the provided context.
- If you cannot support a “missing” claim from the provided context, output NA rather than guessing.

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
Topic: Runtime E2E Matrix and Release Gating
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Runtime E2E Matrix and Release Gating
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
