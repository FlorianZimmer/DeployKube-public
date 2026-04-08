# Secrets Initialization Prompt

```text
You are reviewing DeployKube for topic: secure secrets initialization / bootstrap.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # component tracker slug, or NA for project-wide reviews
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope & evidence rules (strict):
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any included allowlist such as context/file-list.txt).
- Do NOT assume files, defaults, or runtime behavior that is not explicitly evidenced.
- If the context is insufficient to assess secrets initialization/bootstrap for this target, output the NA format exactly.

Sensitive data handling:
- Do NOT reproduce secret material in your output (passwords, tokens, private keys, unseal keys, kubeconfigs, certificate/key PEM blocks, etc.).
- In Evidence, reference file paths, resource names, and key names; redact any values as ***REDACTED***.

Task:
Assess whether initial secret provisioning is secure, repeatable/idempotent, and auditable.

Check at minimum (as applicable to the target):
- Where bootstrap/initial secrets are created (init scripts, Helm hooks, Jobs, operators/controllers, docs)
- Secret generation quality (cryptographic RNG, length/entropy, no hardcoded defaults)
- Separation of one-time initialization vs recurring reconciliation/upgrade paths
- Idempotence / safe re-run behavior (state detection, concurrency/locking, no accidental regeneration)
- Custody and distribution of bootstrap artifacts (who gets them, how stored/transferred, encryption, split knowledge)
- Exposure risk during init (stdout/stderr, logs, shell tracing like `set -x`, CLI args, env vars, temp files, file permissions)
- Access controls during init (least privilege, short-lived bootstrap identities, restricted namespaces/RBAC)
- Post-init hardening (rotate/revoke, disable bootstrap creds, tighten policy/RBAC, remove init manifests)
- Audit trail (who/when initialized, evidence of completion) without leaking secret values
- Recovery path for interrupted/partial initialization (safe resume, rollback, incident response)

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
Topic: Secrets Initialization
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Secrets Initialization
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
