# Supply Chain & Provenance Prompt

```text
You are reviewing DeployKube for topic: Supply Chain and Provenance (images, charts, and external dependencies).

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>  # component | project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope and evidence rules (strict):
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any referenced workpack scoping docs included in it).
- Do NOT assume external controls (registry policies, CI pipelines, or admission policies) unless explicitly shown.
- If the topic is relevant but the RUNTIME_CONTEXT does not contain enough evidence to assess it, output NA (Reason: Insufficient evidence in provided context).

Task:
Assess whether the supply chain is pinned, verified, and traceable for this TARGET_SCOPE.

Check at minimum (tailor to what exists in context):
- Container images:
  - Immutable references (digest pinning via @sha256) or strict version tags; avoid floating tags like latest.
  - imagePullPolicy behavior relative to tag immutability.
  - Registry boundaries and allowlists if configured.
- Helm/Kustomize sources:
  - Helm dependencies are pinned in Chart.yaml/Chart.lock; avoid loose version ranges.
  - Chart sources are trusted and explicit; vendored charts are referenced locally.
  - Kustomize remote bases or git:: references include immutable refs (tag/commit), not default branches.
- Integrity verification:
  - Signature verification (cosign/notation) or admission policies that verify images, if present.
  - Checksums/provenance artifacts referenced and enforced (if the context provides them).
- Upgrade control path:
  - Evidence that dependency updates are reviewed and constrained (GitOps commits, pinned versions, or explicit policy).

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
Topic: Supply Chain and Provenance
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Supply Chain and Provenance
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
