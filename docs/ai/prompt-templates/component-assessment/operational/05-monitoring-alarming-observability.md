# Monitoring, Alerting, and Observability Prompt

```text
You are reviewing DeployKube for topic: monitoring, alerting, and observability (metrics/logs/traces) and operator response during failures.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component|project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Hard scope + evidence rules (do not violate):
- Use only evidence present in RUNTIME_CONTEXT. Do not assume files/config exist outside the provided context.
- If this prompt was rendered from a component workpack, you must stay within the workpack allowlist (context/file-list.txt). Do not cite files outside it.
- If the provided context is insufficient to evaluate this topic, output NA (do not guess).
- Keep scope tight: assess runbook linkage/actionability for alerts, not general operator workflow usability across the component. Broader ops-doc usability belongs to the operations/runbooks/usability prompt.

Task:
Determine whether failures are detectable early, diagnosable quickly, and actionable for operators.

Validate the end-to-end signal chains using static evidence (repo/config/docs), not runtime testing:
- Alerting chain: signal -> alert rule -> routing (Alertmanager or equivalent) -> receiver/on-call destination
- Logging chain: log emission -> collection -> storage/retention -> queryability -> operator actionability

Relevance test (choose one):
- Applicable if the target is a deployable/runtime component (controller/API/agent/job) OR produces operational signals operators must respond to.
- NA if the target is documentation-only, build tooling only, or there is insufficient evidence in RUNTIME_CONTEXT to evaluate monitoring/alerting/logging/tracing for this target.

When Applicable, assess at minimum (every bullet below must be addressed; if a bullet is intentionally not used, explicitly justify with evidence):
- SLI/SLO definitions (or equivalent success criteria) and alert threshold quality (avoid flappy/noisy alerts)
- Metrics coverage for critical failure modes (availability, error rate, latency, saturation, dependency failures, certificate/credential expiry where relevant)
- Trace coverage for request/transaction flows IF tracing is present in the provided context (do not assume tracing exists)
- Log coverage for critical failure modes (errors include enough context to debug)
- Dashboards for critical workflows and failure diagnosis (clear entry points, ownership, and drill-down)
- Alert rule coverage for critical failure modes (e.g., PrometheusRule or equivalent) with severity + ownership/team labels and stable naming
- Alert routing is explicit and traceable (routes, receivers, grouping/inhibition, escalation/on-call destination)
- Dead-man / watchdog alerts and silent failure detection (“monitoring of monitoring”)
- Logging pipeline is explicit and traceable (agent/collector, backend, retention policy, and access/query UX)
- Logs are actionable: structured fields (timestamp/level/component), correlation IDs/request IDs where applicable
- Log-derived failures are either alerted on OR explicitly documented as non-alerting with compensating controls
- Runbook linkage from alerts (e.g., annotations/labels to runbooks) and runbooks contain concrete operator steps
- CI/validation checks that prevent observability regressions (schema/linters/tests; or explicit "none" with rationale)

Evidence requirements for every finding:
- Cite concrete file paths + object names (e.g., Kubernetes resource kind/name, dashboard UID, alert name) and include a short snippet where helpful.
- For “missing” findings, include the negative evidence you relied on (e.g., “no PrometheusRule objects found in provided context”) AND only make that claim if the provided context appears complete enough to support it; otherwise output NA.

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
Topic: Monitoring, Alerting, and Observability
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Monitoring, Alerting, and Observability
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
