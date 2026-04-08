# NIST, DISA, and BSI Alignment Prompt

```text
You are reviewing DeployKube for topic: alignment with NIST, DISA, and BSI security guidance.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>        # component | project
- COMPONENT_NAME: <COMPONENT_NAME>    # tracker slug (issue_slug). Use NA for project scope.
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Task:
Assess practical alignment to baseline security controls and identify major compliance/hardening gaps for this target.

Scope and evidence rules (strict):
- Use ONLY evidence from RUNTIME_CONTEXT (and any included allowlist such as context/file-list.txt).
- Do NOT assume configurations, policies, or controls exist unless you can cite them with file path + snippet/key values.
- If you cannot find enough evidence in the provided context to evaluate this topic, output NA exactly.

Standards/baselines for mapping (avoid over-precision):
- NIST: prefer SP 800-53 control families for mapping (e.g., AC, AU, CM, IA, SC, SI).
- DISA: reference the most relevant STIG/SRG class for the component type (avoid guessing exact IDs).
- BSI: reference IT-Grundschutz / C5 at the level you can do confidently.
- Never invent control identifiers. If unsure, use "Control mapping: NA (uncertain)" and/or name only the family/area.

Check at minimum (prioritize highest impact):
- Access control + identity/authn/authz boundaries
- Secrets handling + encryption in transit/at rest
- Audit logging + monitoring/alerting + evidence for retention
- Secure configuration defaults + hardening guidance
- Documentation/evidence gaps that would block an audit

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
Topic: NIST/DISA/BSI Alignment
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: NIST/DISA/BSI Alignment
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
