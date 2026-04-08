# Validation Jobs and Smoke Coverage Prompt

```text
You are reviewing DeployKube for topic: validation jobs and smoke coverage.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component|project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope + doctrine rules (must follow):
- Use only evidence contained in RUNTIME_CONTEXT (including any workpack allowlist text embedded in it). Do not infer missing files from outside the provided context.
- Assess against the repo contract in `docs/design/validation-jobs-doctrine.md` only when that doctrine file (or equivalent component docs/manifests that evidence the same contract) is included in RUNTIME_CONTEXT.
- If RUNTIME_CONTEXT does not contain enough validation-job/smoke evidence to assess this topic for this target, output NA (Reason must describe the evidence gap).
- Keep the three validation planes separate:
  - in-cluster validation Jobs/CronJobs/Argo hook Jobs are the primary subject of this prompt
  - pre-merge CI static checks belong to the CI prompt
  - workflow-driven runtime E2E / mode-matrix tests belong to the CI prompt except where they are explicitly referenced as complements to smoke coverage

Task:
Assess whether this target has sufficient validation-job and smoke coverage to prove real functionality continuously and safely.

Relevance test (choose one):
- Applicable if the target is a deployable/runtime component, exposes a user or operator-facing capability, owns validation `Job`/`CronJob`/Argo hook resources, or claims runtime assurance elsewhere in the provided context.
- NA if the target is documentation-only/build-only, or the provided context is too incomplete to determine whether validation jobs/smokes exist or are required.

Check at minimum (only when evidence exists in context):
- Whether meaningful runtime validation exists for the important capability boundaries (not just readiness/"pod is running")
- Whether the chosen execution modes fit the doctrine:
  - manual `Job` bundle for operator/developer loops
  - Argo hook `Job` only for true sync-gates
  - scheduled `CronJob` for ongoing assurance in prod
- Whether the component cleanly separates:
  - ongoing in-cluster smoke assurance
  - pre-merge CI structural checks
  - workflow-driven runtime E2E for broader mode/flavor matrices
- Coverage depth:
  - core happy-path functionality
  - dependency/path checks
  - negative/failure-path checks where important
  - restore/upgrade/failover validation where the target claims those properties
- Structural quality of validation resources:
  - required Job/CronJob safety fields
  - idempotency/cleanup behavior
  - bounded runtime/timeouts
  - useful diagnostics on failure
- Mesh/runtime behavior for Jobs in injected namespaces (disable injection by default, or use the repo’s native-sidecar exit pattern when injection is required)
- Security/RBAC quality of validation bundles (least privilege, dedicated ServiceAccount, no secret leakage in logs/output)
- Ongoing assurance signals:
  - staleness/failure alerting or equivalent observability for CronJob-based checks
  - clear operator signal when coverage fails
- CI boundary clarity:
  - whether the provided context makes clear which guarantees come from in-cluster smokes versus CI
  - whether missing smoke coverage is incorrectly delegated to CI-only E2E, or vice versa
- Runtime E2E complement quality when referenced in context:
  - whether broader mode/flavor/config permutations are intentionally covered by workflow-driven E2E because a single CronJob cannot cover them cleanly
  - whether smoke jobs still exist for the canonical ongoing health signal

Severity rubric:
- High: no meaningful functional validation for a production-critical capability; ongoing assurance required but absent; or the only checks are misleading/non-actionable
- Medium: partial coverage, weak assertions, missing doctrine-required safety/diagnostic fields, or no staleness/failure signal for continuous smokes
- Low: documentation/readability gaps or incremental hardening opportunities

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
Topic: Validation Jobs and Smoke Coverage
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Validation Jobs and Smoke Coverage
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
