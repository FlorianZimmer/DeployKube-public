# Secrets Handling Prompt

```text
You are reviewing DeployKube for topic: Secrets Handling.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>  # component | project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope + safety rules (mandatory):
- Use ONLY RUNTIME_CONTEXT as evidence. Do not rely on repo knowledge outside of it; do not guess.
- If the workpack includes a context allowlist (e.g., context/file-list.txt), treat anything outside it as out of scope.
- NEVER reproduce secret material in your output (tokens, passwords, private keys, cert private keys, kubeconfig contents, etc).
  - In Evidence, keep the file path/resource name/key name, but redact values as ***REDACTED***.

Relevance test:
- Mark Relevance: Applicable if RUNTIME_CONTEXT contains ANY secret-related artifacts, such as:
  - Kubernetes Secret manifests (including Helm/Kustomize outputs) or secret references (secretRef, envFrom, imagePullSecrets, volume mounts)
  - ExternalSecret/SecretStore (External Secrets Operator), SealedSecret, SecretProviderClass (CSI driver), Vault Agent/Injector annotations
  - Scripts/CI configs that fetch, decrypt, template, or export secrets
- Otherwise, output NA (Reason must be one sentence, e.g., "No secret-related artifacts present in provided context").

Task:
Assess whether the secret lifecycle for this target is secure and operationally robust.

Check at minimum (only when evidenced):
- Secret source of truth and custody boundaries (Kubernetes Secrets vs external manager such as Vault, External Secrets Operator, SOPS-encrypted files, cloud secret managers/KMS)
- Plaintext exposure risk in repo artifacts (manifests, Helm values, scripts, CI). NOTE: base64 in Kubernetes Secret is plaintext encoding, not encryption.
- Runtime materialization paths in pods (env vars vs mounted files vs CSI), file permissions, and avoidance of writing secrets to logs/metrics
- Rotation, revocation, and expiry (TTL, automation, and documented cadence)
- Access scoping and audit trail quality (Kubernetes RBAC/service accounts, secret store policies, audit logs)
- Recovery/DR path for secret systems and encryption keys (backup/restore, key management, unseal/restore procedures when applicable)

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
Topic: Secrets Handling
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Secrets Handling
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
