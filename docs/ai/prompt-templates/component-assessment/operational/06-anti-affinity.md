# Anti-Affinity and Placement Resilience Prompt

```text
You are reviewing DeployKube for topic: anti-affinity and resilient workload placement.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>            # component|project
- COMPONENT_NAME: <COMPONENT_NAME>        # tracker slug (issue_slug) or NA (for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>        # repo-relative path or NA
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Goal:
Evaluate whether Kubernetes workload placement policies reduce correlated failure risk (node/zone) while remaining schedulable during disruptions and rollouts.

Scope & evidence rules (strict):
- Use ONLY the provided RUNTIME_CONTEXT (and only the files included there). Do not use outside repo knowledge or assume cluster topology.
- Return NA only if there are no schedulable Kubernetes workloads in context for this target
  (e.g., no Deployment/StatefulSet/DaemonSet/Job/CronJob/Rollout/Pod templates).
- Do NOT return NA simply because anti-affinity/spread constraints are missing; missing/weak policies are findings if workloads exist.
- Every finding MUST include concrete evidence:
  - File path(s)
  - Resource kind + name (+ namespace if present)
  - YAML key path(s) (e.g., spec.template.spec.affinity.podAntiAffinity)
  - A short excerpt OR an explicit “field not present” statement tied to a specific resource.

What to check (when applicable):
1) Workload inventory
- List each workload that schedules pods (kind/name) and replica count (or explain if it is a DaemonSet/Job).
- Flag quorum-sensitive/stateful workloads separately (StatefulSet, leader-election, etc.).

2) Anti-affinity and affinity correctness
- podAntiAffinity usage: requiredDuringSchedulingIgnoredDuringExecution vs preferredDuringSchedulingIgnoredDuringExecution.
- Topology keys used (kubernetes.io/hostname, topology.kubernetes.io/zone/region).
- labelSelector correctness: ensure it matches the intended peer pods (stable labels; not too broad/narrow).
- nodeAffinity / nodeSelector constraints that may concentrate pods into one nodegroup/zone.

3) Topology spread constraints effectiveness
- topologySpreadConstraints presence and whether they actually apply to the pod labels (labelSelector / matchLabelKeys).
- maxSkew quality, minDomains (if present), and whenUnsatisfiable choice (DoNotSchedule vs ScheduleAnyway).
- Ensure zone-level and hostname-level spreading is appropriate for expected failure domains.

4) Storage and failure-domain coupling (stateful especially)
- PV / CSI topology: volume node/zone affinity and StorageClass volumeBindingMode that can override desired spreading.
- Call out conflicts where anti-affinity/spread constraints fight storage locality and can deadlock scheduling.

5) Disruptions and evictions
- PodDisruptionBudget settings (minAvailable/maxUnavailable) vs replica count.
- Interaction between strict placement + PDB + node drains/cluster upgrades (risk of stuck evictions or unavailability).

6) Tradeoffs and operability
- Overly strict scheduling that risks unschedulable rollouts/scale-out.
- Recommend preferred constraints or autoscaler-compatible patterns where strict rules are impractical.

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
Topic: Anti-Affinity
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Anti-Affinity
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
