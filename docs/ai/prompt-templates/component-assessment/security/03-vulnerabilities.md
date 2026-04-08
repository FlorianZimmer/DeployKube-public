# Vulnerability Risk Prompt

```text
You are reviewing DeployKube for topic: potential vulnerabilities.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>              # component | project
- COMPONENT_NAME: <COMPONENT_NAME>          # tracker slug for component scope; NA for project scope
- COMPONENT_PATH: <COMPONENT_PATH>          # repo-relative path or NA
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Task:
Identify likely exploitable weaknesses and practical remediation priority for the given TARGET_SCOPE.

Hard constraints (must follow):
- Use ONLY the provided RUNTIME_CONTEXT as your source of truth. Do not assume files, behavior, versions, ports, or endpoints that are not present.
- Do not invent CVE IDs, package versions, image tags/digests, or configuration settings.
  - Only reference a specific CVE/version if it is directly supported by evidence in RUNTIME_CONTEXT.
  - If version data is missing, describe the risk generically and recommend verification (e.g., run an image/dependency scan) without naming specific CVEs.
- Every non-NA finding MUST cite concrete evidence from RUNTIME_CONTEXT (prefer file path + key snippet/setting/value).
- If the topic is relevant but the provided RUNTIME_CONTEXT is insufficient to ground findings, output NA using the NA format exactly.

Check at minimum (when evidence exists):
- Known vulnerable images/packages (ONLY if explicit version/tag/digest data is available)
- Unpinned images/tags (e.g., `:latest`) and missing supply-chain controls (SBOM/signing/verification)
- Misconfiguration-based exploit paths (public exposure, missing authn/z, weak TLS, unsafe CORS, etc.)
- Weak defaults and insecure fallbacks
- Injection, deserialization, and command execution exposure (only with code/config evidence)
- Privilege escalation and lateral movement opportunities (securityContext, privileged/host mounts, RBAC, service account token usage)
- Secrets exposure (plaintext secrets in manifests/docs, broad secret mounts, env var leakage) when evidenced
- Missing hardening in data plane/control plane boundaries (network policies, namespace isolation, Pod Security/admission)

Issue class boundary:
- Actionable Improvements: fixes that fit the current architecture (config hardening, patching, least-privilege tweaks).
- Architectural Problems: systemic issues requiring redesign/cross-cutting changes (trust boundaries, multi-tenancy model, authn/z architecture).

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
Topic: Vulnerabilities
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Vulnerabilities
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
