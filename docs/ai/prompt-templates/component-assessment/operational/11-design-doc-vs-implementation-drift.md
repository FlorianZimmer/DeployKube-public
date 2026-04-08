# Design Doc vs Implementation Drift Prompt

```text
You are reviewing DeployKube for topic: Design doc vs implementation drift (design intent vs repo reality).

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue slug for docs/component-issues/* (or NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- Do NOT assume the design doc is authoritative runtime truth; in DeployKube, implementation (code/manifests/scripts) is runtime truth.
- Your job is to detect drift and classify it precisely, not to invent missing design intent.
- This prompt focuses exclusively on design docs (typically docs/design/** and any design markdown included in RUNTIME_CONTEXT).
  Do not assess guides/runbooks/toils/API reference docs here.
- If no design doc(s) are included in RUNTIME_CONTEXT, output NA (Reason must state that design docs are missing from context).

Definitions:
- "Design doc" means architecture intent and component relationship context (e.g., docs/design/**).
- "Drift" means a mismatch between what the design doc claims/assumes and what the implementation evidence shows.

Task:
Assess whether the design doc(s) in scope are up to date with the actual implementation evidenced in RUNTIME_CONTEXT.
Identify:
- Features/behaviors/resources that exist in implementation but are not described in the design doc.
- Design doc claims that are no longer true in implementation.
- New constraints/interfaces (CRDs, labels/annotations, RBAC, admission, Argo policies) added in implementation but not described.

Method:
1) Identify the design doc(s) in RUNTIME_CONTEXT that apply to this target and extract the key assertions:
   - component boundaries, responsibilities, data flows, authn/authz expectations, secrets custody, upgrade/migration model
   - contracts/interfaces: CRDs, labels/annotations, RBAC rules, admission/webhooks, Argo allowlists
2) Identify the corresponding implementation evidence in RUNTIME_CONTEXT (manifests/scripts/controller code/config) and build a short inventory:
   - primary resources, entrypoints, dependencies, interfaces and externally visible contracts
3) Compare design assertions vs implementation inventory:
   - For each mismatch, record both sides of the evidence (design cite + implementation cite).
4) Classify each mismatch:
   - Doc drift (likely): design doc should be updated to reflect implemented behavior
   - Implementation divergence (possible): implementation may violate a stated safety/security invariant in the design doc
   - Undocumented addition: implementation introduced a new behavior/contract that should be documented (even if acceptable)

Evidence rules (strict):
- Every finding must cite BOTH:
  - Design evidence: <design doc path + relevant section/snippet>
  - Implementation evidence: <path + resource/kind/name or code identifier + snippet>
- If you cannot cite both sides from RUNTIME_CONTEXT, output NA (insufficient evidence) rather than guessing.

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
Topic: Design Doc vs Implementation Drift
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Design Doc vs Implementation Drift
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```

