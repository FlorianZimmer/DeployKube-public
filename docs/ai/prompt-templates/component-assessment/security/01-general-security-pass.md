# General Security Pass Prompt

```text
You are reviewing DeployKube for topic: General Security Pass (broad security posture).

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>          # "component" or "project"
- COMPONENT_NAME: <COMPONENT_NAME>      # tracker slug (matches docs/component-issues/<slug>.md) or "NA" if TARGET_SCOPE=project
- COMPONENT_PATH: <COMPONENT_PATH>      # repo-relative path or "NA" if TARGET_SCOPE=project
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope and evidence rules (mandatory):
- Use ONLY information contained in RUNTIME_CONTEXT. Treat anything not shown as unknown.
- Do not assume defaults or “typical” DeployKube/Kubernetes behavior. No speculation.
- Only emit findings that include concrete evidence from RUNTIME_CONTEXT (prefer file path + relevant snippet/setting).
- If the provided context is insufficient to assess this topic for this target (or the topic truly does not apply), output the NA format exactly.

Task:
Perform a practical security pass focused on risk reduction for a market-ready product.

Check at minimum (as applicable to the provided context):
- Attack surface: exposed endpoints/ports/ingress, public exposure, unsafe defaults
- Trust boundaries and data flows between components and external systems
- Transport security: TLS/mTLS use, certificate management/rotation, insecure protocols
- Identity/authn/authz: RBAC/service accounts, least privilege, default admin endpoints/creds
- Secrets/keys: plaintext storage, secret distribution, rotation, leakage in logs/manifests
- Input handling & injection: command execution, templating, SSRF, path traversal (where relevant in code/config)
- Supply chain: dependency pinning, image tag/digest hygiene, provenance/signing signals, vulnerability scanning signals
- Operational hardening: pod/container securityContext, seccomp/capabilities, network policies, audit logging, breakglass procedures

Classification guidance:
- Actionable Improvements = localized fixes within the current architecture (config/code changes).
- Architectural Problems = systemic security design flaws (trust boundary/privilege model/multi-tenancy/secret distribution) requiring redesign or refactor across modules.

Severity guidance (choose one):
- Critical: likely compromise with low effort (e.g., auth bypass, exposed admin, reachable plaintext secrets)
- High: meaningful compromise requiring some preconditions
- Medium: defense-in-depth gaps or risky operational defaults
- Low: minor hardening/hygiene

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
Topic: General Security Pass
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: General Security Pass
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
