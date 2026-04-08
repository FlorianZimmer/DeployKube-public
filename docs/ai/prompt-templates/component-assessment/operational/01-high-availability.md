# High Availability (Service Interruption) Prompt

```text
You are reviewing DeployKube for topic: High Availability and interruption resistance.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>   # component | project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue slug for docs/component-issues/* (or NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope guardrails:
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any explicit allowlist included within it).
- Do NOT assume cluster features, replica counts, SLOs, or resources that are not shown in the context.
- If you cannot find enough HA-relevant evidence in RUNTIME_CONTEXT to assess (e.g., no workload manifests, no rollout strategy, no PDB/probes/scheduling info, no HA tests), output NA (Reason must say evidence is missing).

Task:
Evaluate whether this target can tolerate node/pod/service interruptions (voluntary and involuntary) without unacceptable outage.
- If no explicit SLO is provided, treat "unacceptable outage" as: a single routine interruption or rollout can cause user-visible downtime, loss of control-plane function, or prolonged unavailability (more than a few minutes) for this target.

Check at minimum (cite concrete evidence for each finding):
- Replica strategy, leader election safety (if controller/operator), and single points of failure
- Workload update strategy (Deployment/StatefulSet/DaemonSet), maxUnavailable/maxSurge/partition, and disruption behavior during rollout
- PodDisruptionBudget presence/coverage and interaction with replicas and node drains
- Readiness/liveness/startup probes and readiness gating during failure/rollout
- Graceful termination: terminationGracePeriodSeconds, preStop hooks, and shutdown behavior
- Scheduling resilience: podAntiAffinity/topologySpreadConstraints, node affinity/taints/tolerations, and zone assumptions
- Stateful failover behavior (if stateful): storage access mode, quorum/leader election, data consistency assumptions
- Dependency blast radius and degraded-mode behavior (what happens if dependencies are down)
- Explicit HA validation coverage in CI/validation jobs (e.g., disruption tests, rollout tests)

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
Topic: High Availability
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: High Availability
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
