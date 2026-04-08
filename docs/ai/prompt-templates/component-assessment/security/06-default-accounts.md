# Default User/Admin Account Disablement Prompt

```text
You are reviewing DeployKube for topic: default user/admin account disablement.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Goal:
Determine whether any default, bootstrap, vendor, or sample accounts/credentials exist, and if so whether they are disabled,
forced to rotate, or otherwise made unusable for real deployments.

Definitions (use these to decide relevance):
- "Default account/credential" includes:
  - hard-coded usernames/passwords (e.g., admin/admin, changeme)
  - vendor/Helm chart defaults for admin users
  - bootstrap tokens/initial admin passwords that are predictable, shared, or long-lived
  - test/demo accounts enabled outside tests
  - default API keys, client secrets, signing keys, or certificates shipped in-repo
- This topic is relevant if the component (or bundled/managed third-party app) exposes an auth surface (UI/API/CLI)
  OR ships credentials/secrets used for initialization/bootstrap.

Scope + evidence rules (strict):
- Use ONLY evidence present in RUNTIME_CONTEXT (respect workpack allowlists).
- If you cannot find sufficient relevant evidence in RUNTIME_CONTEXT to assess this topic, output NA.
- Do NOT assume the presence or absence of default accounts without evidence.
- Evidence must cite file paths and exact keys/values/snippets (include line numbers if available).

What to check (only where evidence exists in-scope):
1) Presence of default/bootstrap users or credentials
   - search for known defaults: admin/admin, root, kubeadmin, test/demo, "changeme", "password", "default"
2) Secure bootstrap and rotation
   - are initial credentials unique per deployment (randomly generated) and/or one-time?
   - is first-use password change / key rotation enforced?
3) Ability to disable vendor defaults
   - is there an implemented + documented path to disable/remove default accounts?
4) Secrets handling
   - are default creds stored in plain text (manifests/examples/docs)?
   - are generated secrets stored and rotated appropriately (K8s Secret, external secret store, etc.)?
5) Guardrails (optional; only if CI/policy config is in RUNTIME_CONTEXT)
   - are there CI/policy checks preventing reintroduction of default credentials?
6) Breakglass / emergency access (only if such a mechanism exists)
   - custody controls, audit logging, time-limited access, rotate after use

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
Topic: Default Accounts
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Default Accounts
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
