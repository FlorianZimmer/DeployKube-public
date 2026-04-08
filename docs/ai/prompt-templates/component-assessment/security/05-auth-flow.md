# Authentication and Authorization Flow Prompt

```text
You are reviewing DeployKube for topic: Auth Flow (authentication, authorization, and identity controls).

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>  # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # tracker slug; "NA" for project-wide runs
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope and evidence rules (strict):
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any referenced workpack scoping docs included in it).
- Do NOT assume how DeployKube works; do NOT invent missing flows.
- If the topic is relevant but the RUNTIME_CONTEXT does not contain enough evidence to assess it, output NA (Reason: Insufficient evidence in provided context).

Task:
Assess whether authentication/authorization flows are secure, complete, and operationally safe for this TARGET_SCOPE.

Check at minimum (tailor to what exists in context):
- Human login / SSO flows (OIDC/OAuth2/SAML/LDAP/etc), redirect/PKCE handling, and where credentials are stored/used
- Token/session lifecycle: issuance, storage, refresh/rotation, expiry, logout, and revocation
- Token validation at every hop: signature verification, issuer/audience/alg checks, key rotation, clock skew handling
- Service-to-service auth: service accounts/workload identity/mTLS, trust chaining, and prevention of token forwarding/impersonation
- Authorization model: RBAC/ABAC, role mapping from identity claims/groups, default-deny, least privilege, and privileged endpoints
- Failure behavior: fail-closed vs fail-open when IdP/auth service is degraded; safe fallbacks; caching
- Auditability: logs/audit events for login, token mint/refresh/revoke, role changes, and other privileged auth operations

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
Topic: Auth Flow
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Auth Flow
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
