# Key Lengths and Cryptographic Algorithms Prompt

```text
You are reviewing DeployKube for topic: key lengths and cryptographic algorithms.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>            # component | project
- COMPONENT_NAME: <COMPONENT_NAME>        # tracker slug (issue_slug) or NA (for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>        # repo-relative path or NA
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Task:
Assess whether the cryptographic primitives, protocol versions, and key sizes used/configured by the target are current, safe, and consistently enforced.

Scope / evidence rules (mandatory):
- Treat RUNTIME_CONTEXT as the full evidence set for this assessment. Do not assume anything not shown there.
- Every finding MUST cite specific evidence from RUNTIME_CONTEXT (file path + excerpt/setting/value).
- If crypto key/algorithm analysis is not relevant to the target OR the provided context does not contain enough evidence to evaluate safely, output NA.

Check (when evidence exists):
- TLS protocol versions and cipher suites (ingress / gateway / mesh / service-to-service)
- Certificate public-key types and sizes (RSA bits; ECDSA curve; EdDSA)
- Certificate signature algorithms (e.g., SHA-256+), avoid SHA-1/MD5
- Token/JWT signing algorithms and key/secret strength (RSA/ECDSA/EdDSA bits/curves; HMAC secret lengths)
- Deprecated/weak primitives (examples: SSLv3, TLS1.0/1.1, RC4, 3DES, RSA<2048, SHA-1/MD5, ECB; non-AEAD encryption for new designs)
- Key/cert rotation and expiry automation (cert-manager, Vault PKI, external issuers), plus alerting/renewal behavior
- Guardrails to prevent regressions (CI lint/policy checks, admission controls, unit/integration tests)

Baselines (heuristics to reduce ambiguity; defer to any stricter in-repo policy if present in RUNTIME_CONTEXT):
- TLS: TLS 1.2+ recommended; TLS 1.3 preferred where supported; disable TLS 1.0/1.1.
- RSA: >= 2048 bits minimum (flag <2048); consider stronger for long-lived keys/certs.
- ECC: prefer modern curves (e.g., P-256+ / Ed25519); flag obsolete/small curves.
- Symmetric crypto: prefer AEAD modes (AES-GCM, ChaCha20-Poly1305) for new designs; avoid ECB; avoid unauthenticated encryption patterns.

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
Topic: Key Lengths and Algorithms
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Key Lengths and Algorithms
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
