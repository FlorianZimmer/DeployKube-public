# Cyberattack Resilience (DDoS, MITM, etc.) Prompt

```text
You are reviewing DeployKube for topic: resilience against active cyberattacks (DDoS, MITM, replay, abuse patterns).

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>   # tracker file stem for component scope (often the catalog issue_slug) OR NA for project scope
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope & evidence rules (must follow):
- Use only evidence from RUNTIME_CONTEXT. Do not cite or rely on files/knowledge outside this input.
- Do not assume controls exist outside the repo (e.g., managed DDoS protection) unless the context explicitly documents them.
- If the topic is not applicable for this target OR the provided context lacks enough evidence to assess it without guessing, output the NA format exactly (Reason must be specific).
- Never claim a control is enabled unless you can point to concrete evidence (file path + exact setting or excerpt).

Task:
Assess prevention, detection, and response posture against common active attacks.

Check at minimum (capture implementation AND operational readiness):
- DDoS / rate-limit / resource exhaustion:
  - Edge throttling (ingress/API gateway), WAF, connection/request caps, request body limits, timeouts
  - Backpressure (queues, circuit breakers) where relevant
  - Kubernetes resource isolation (requests/limits, autoscaling, quotas)
- MITM resistance:
  - TLS enforcement at ingress and internal boundaries; avoid plaintext fallbacks
  - mTLS boundaries/service mesh policy (where used) and cert rotation expectations
  - Outbound TLS: certificate validation (avoid insecure flags like `insecureSkipVerify`, `--insecure`, `skipTLSVerify`)
- Replay / session hijack mitigation (where applicable):
  - Nonce/jti + exp/iat validation, one-time tokens, session rotation
  - Secure cookie/session settings if HTTP is involved
- Abuse throttling & anomaly detection:
  - Per-identity throttling (IP/user/token), brute-force/credential stuffing defenses
  - Audit logging, metrics, alerting thresholds, and runbooks/on-call signals
- Blast-radius containment & recovery:
  - Isolation boundaries (RBAC, namespaces, network policies), least privilege defaults
  - Incident response / DDoS playbooks, rollback and recovery steps
- Verification evidence:
  - Tests, runbooks, dashboards/alerts, or explicit validation steps proving defenses are configured and monitored
  - Do not claim “verified at runtime” unless the context contains proof of such verification.

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
Topic: Cyberattack Resilience
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Cyberattack Resilience
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
