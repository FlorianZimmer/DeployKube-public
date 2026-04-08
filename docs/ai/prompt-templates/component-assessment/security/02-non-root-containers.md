# Non-Root Container Enforcement Prompt

```text
You are reviewing DeployKube for topic: non-root container enforcement.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope & evidence rules (must follow):
- Use ONLY evidence present in RUNTIME_CONTEXT (and, if a workpack is used, obey its context contract / file allowlist).
- Do not assume cluster defaults, admission settings, image behavior, or runtime configuration that is not shown in evidence.
- If RUNTIME_CONTEXT does not contain enough evidence to assess this topic for the given target (e.g., no workload specs/templates/policies in scope), output NA.

Task:
Assess whether workloads are configured and/or enforced to run without root privileges and with least privilege defaults.

Relevance guidance:
- Applicable if the target ships or templates Kubernetes workloads (Pod/Deployment/StatefulSet/DaemonSet/Job/CronJob)
  OR ships admission/policy resources that enforce pod security (PSA labels, Kyverno, Gatekeeper, etc.).
- Otherwise NA.

Check at minimum (evaluate both Pod-level and container-level securityContext; include init/sidecar parity):
- Pod securityContext vs container securityContext inheritance/overrides (ensure container overrides do not negate Pod defaults)
- runAsNonRoot=true and runAsUser is explicitly non-zero where possible (flag runAsUser=0)
- If runAsNonRoot=true but runAsUser is unset, look for image user evidence (e.g., Dockerfile/Containerfile USER):
  - If USER is root/0 or non-numeric/unknown, call out the mismatch risk and recommend setting an explicit non-zero runAsUser
- runAsGroup / fsGroup / supplementalGroups where needed for volume permissions (avoid fsGroup=0 unless explicitly justified)
- allowPrivilegeEscalation=false
- capabilities: drop ["ALL"] (or equivalent) and add back only required (call out missing drops or risky added capabilities)
- readOnlyRootFilesystem=true where feasible (if not set, only flag when there is no evidence it must be writable)
- privileged=true or host-level escapes (hostPID/hostIPC/hostNetwork) and any documented exceptions
- Admission/policy enforcement coverage, exemptions, and bypass risk (namespaces excluded, policies disabled, permissive overrides)
- Init/sidecar/container parity (not just main container)

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
Topic: Non-Root Containers
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Non-Root Containers
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
