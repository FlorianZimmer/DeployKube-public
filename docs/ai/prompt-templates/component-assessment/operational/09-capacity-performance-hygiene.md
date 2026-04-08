# Capacity & Performance Hygiene Prompt

```text
You are reviewing DeployKube for topic: Capacity and Performance Hygiene.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue slug for docs/component-issues/* (or NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- Do NOT assume cluster sizing, autoscaling, or SLOs unless explicitly shown.
- If you cannot find enough capacity/performance evidence in RUNTIME_CONTEXT to assess, output NA (Reason must say evidence is missing).

Task:
Evaluate whether this target has adequate resource hygiene and performance safeguards.

Check at minimum (cite concrete evidence for each finding):
- Resource requests/limits on workloads (CPU, memory, and ephemeral storage where relevant).
- Autoscaling configuration (HPA/VPA/KEDA) or explicit reasoning for fixed sizing.
- Namespace-level limits and quotas (LimitRange/ResourceQuota) for multi-tenant safety.
- Performance-sensitive knobs (connection pools, timeouts, caches, JVM/Go runtime flags) when surfaced in manifests or configs.
- Evidence of performance validation or load testing (only if in scope).

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
Topic: Capacity and Performance Hygiene
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Capacity and Performance Hygiene
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
