# Operations, Runbooks, and Usability Prompt

```text
You are reviewing DeployKube for topic: operations, runbooks, and operator usability.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- This prompt intentionally needs both implementation truth and operator-facing docs:
  - implementation truth from code/manifests/scripts/READMEs
  - operator docs from guides/runbooks/toils/API references when present
- In the component-assessment framework, use the docs allowlist for this prompt because it includes both component implementation files and matched docs.
- Do NOT treat design docs as runtime truth here; design drift belongs to the design-drift prompt.
- Do NOT focus on whether docs merely exist; documentation presence/freshness belongs primarily to the documentation-coverage prompt.
- If RUNTIME_CONTEXT does not contain enough implementation-plus-ops-doc evidence to evaluate this topic, output NA.

Task:
Assess whether an operator can safely execute the important day-2 workflows for this target using the available docs and repo truth, without needing tribal knowledge.

Relevance test (choose one):
- Applicable if the target is a deployable/runtime component, controller, platform service, validation bundle, or any surface operators may need to configure, debug, recover, rotate, or re-run.
- NA if the target is documentation-only/build-only, or there is insufficient implementation and ops-doc evidence in the provided context.

Check at minimum (only when justified by evidence in context):
- Operational entrypoint quality:
  - does the README or linked ops doc clearly tell an operator where to start
  - are the canonical docs obvious, or is responsibility fragmented across multiple files
- Procedure usability for the workflows this target implies:
  - verification/health checks
  - manual intervention or re-run paths
  - routine maintenance/rotation operations
  - failure triage/breakglass paths
  - restore/recovery or rollback entrypoints where the target owns them
- Repo-truth alignment:
  - commands, paths, resource names, flags, overlays/deploymentIds, secrets/ConfigMap names, and URLs in docs match the implementation evidence
  - prerequisites and dependencies are stated clearly enough to execute the procedure in the right order
- Actionability quality:
  - steps are concrete, bounded, and specific enough to follow
  - expected success/failure signals are stated
  - follow-up diagnostics are clear when a step fails
- Safety quality:
  - dangerous or mutating steps are called out explicitly
  - breakglass or config-mutating flows mention acknowledgements/rollback/custody constraints when those requirements exist in the implementation/docs
- Duplication and fragmentation risk:
  - multiple docs competing as canonical for the same operational workflow
  - split procedures that require hopping between files without a clear entrypoint
  - stale cross-links or missing links from the component README
- Boundary discipline:
  - operational docs do not invent behavior that is not implemented
  - critical operator workflows are not left implicit with "read the manifests" as the only path

Severity rubric:
- High: operators likely cannot perform a critical day-2 workflow safely or correctly from the documented material and implementation evidence in context
- Medium: workflow exists but is incomplete, fragile, misleading, too implicit, or spread across docs in a way likely to cause mistakes
- Low: discoverability, clarity, linkage, or incremental usability improvements

Evidence rules (strict):
- Every finding must cite both sides when possible:
  - operator-doc evidence (README/guides/runbooks/toils/API docs)
  - implementation evidence (code/manifests/scripts/resources/flags/paths)
- If the procedure usability cannot be judged because one side is missing from RUNTIME_CONTEXT, output NA rather than guessing.

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
Topic: Operations, Runbooks, and Usability
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Operations, Runbooks, and Usability
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
