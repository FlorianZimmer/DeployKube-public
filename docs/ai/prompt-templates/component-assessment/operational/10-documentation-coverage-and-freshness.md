# Documentation Coverage and Freshness Prompt

```text
You are reviewing DeployKube for topic: Documentation coverage and freshness (docs vs implementation).

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue slug for docs/component-issues/* (or NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- Do NOT assume documentation exists or does not exist unless RUNTIME_CONTEXT includes enough repo evidence to support that claim.
- This prompt focuses on operational/user-facing documentation (guides/runbooks/toils/API docs). Do not evaluate design docs here.
- This prompt focuses on documentation presence, scope, linkage, and freshness. Deep assessment of procedural usability/runbook executability belongs to the operations/runbooks/usability prompt.
- If you cannot determine documentation presence or currency from RUNTIME_CONTEXT (e.g., docs paths are not included), output NA.

Definitions:
- "Coverage" means the minimum docs needed to safely use/operate/modify this target (not exhaustive docs).
- "Freshness" means docs match the current implementation evidenced in RUNTIME_CONTEXT (paths, resource names, flags, flows, versions).
- "Necessary docs" depend on what the component does; only require what is justified by evidence in RUNTIME_CONTEXT.

Task:
Assess whether necessary docs exist and are up to date with the implementation.

Method:
1) Identify the documentation entrypoints present in RUNTIME_CONTEXT:
   - Component-level README(s) (often under COMPONENT_PATH), and any repo docs explicitly referenced from those READMEs.
2) Determine which doc categories are necessary for this target based on evidence in RUNTIME_CONTEXT:
   - Guides: docs/guides/** (operator playbooks, bootstrap flows, day-1/day-2)
   - Runbooks: docs/runbooks/** (alerts/incidents/breakglass; runbook_url targets)
   - Toils: docs/toils/** (operational how-tos that are not alerts/incidents)
   - API docs: docs/apis/** (CRD/API reference for product-owned APIs)
3) For each necessary doc category:
   - Check whether the doc exists (only if RUNTIME_CONTEXT includes enough repo coverage to make that claim).
   - Spot-check freshness: ensure the doc describes the current resources, paths, labels/annotations, flags, and procedures actually present in RUNTIME_CONTEXT.
   - Flag drift: renamed resources, outdated commands, missing prerequisites, moved paths, incompatible version assumptions.
4) Identify duplication/fragmentation that creates drift risk:
   - Multiple docs claiming to be canonical for the same procedure, or docs that contradict each other in RUNTIME_CONTEXT.

Evidence rules (strict):
- Every finding must cite concrete evidence in RUNTIME_CONTEXT:
  - For "missing docs": cite the file listing evidence you relied on OR state NA if RUNTIME_CONTEXT is not complete enough.
  - For "stale docs": cite the doc snippet and the implementation snippet that contradicts it (file paths + specific identifiers).
- If RUNTIME_CONTEXT does not include any docs-related evidence (no READMEs, no docs/*, no references), output NA with Reason stating the gap.

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
Topic: Documentation Coverage and Freshness
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Documentation Coverage and Freshness
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
