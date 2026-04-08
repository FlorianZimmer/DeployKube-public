# CI Checks Thoroughness and Gap Analysis Prompt

```text
You are reviewing DeployKube for topic: CI validation thoroughness and missing checks.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>          # component | project
- COMPONENT_NAME: <COMPONENT_NAME>      # tracker slug (issue_slug) OR NA (for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>      # repo-relative path OR NA
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Definitions / scope:
- "CI checks" means only what is evidenced in RUNTIME_CONTEXT (e.g., workflow/pipeline config, CI scripts invoked by jobs,
  CI logs, and CI-related documentation included in the provided context). Do not assume tooling that is not shown.
- If TARGET_SCOPE=component: assess checks that would run (or should run) for changes under COMPONENT_PATH.
- If TARGET_SCOPE=project: assess repo-wide CI defaults/gates and gaps that impact multiple components.
- Keep the planes separate when reasoning:
  - Pre-merge CI checks: fast static/structural checks (lint/render/schema/contract/policy).
  - Runtime CI orchestrators: workflow-driven E2E that run against real clusters and may exercise mode/flavor matrices.
  - In-cluster smoke/validation Jobs/CronJobs are a different topic and should not be treated as "CI" unless the evidence explicitly shows CI triggering them as part of a workflow.
- Deep assessment of cross-cutting runtime mode/flavor matrix E2E and release-tag gates belongs to the dedicated runtime-E2E/release-gating prompt.

Task:
Assess whether CI checks are sufficient to prevent regressions and enforce contracts.

Method:
1) Inventory what CI jobs/checks exist (as evidenced in RUNTIME_CONTEXT), explicitly separating:
   - pre-merge static/structural CI
   - runtime CI orchestrators / E2E workflows
2) Identify gaps that could allow regressions or contract violations to merge/release.
3) Propose concrete, repo-specific fixes (new jobs, stronger gates, added tests, improved triggers).

Check at minimum (as applicable to the evidence you have):
- Coverage of linting, rendering/building (helm/kustomize/etc), schema validation, policy checks
- PR gating / required-check behavior (what blocks merges, what is optional)
- Functional validation depth in CI for behavior-affecting changes:
  - what is covered by pre-merge CI
  - what is deferred to runtime CI orchestrators / cluster-backed E2E
  - what is not covered at all
- Runtime CI orchestrator quality when present:
  - quick PR profile versus nightly/manual full profile
  - explicit mode/flavor/config matrix coverage where components have multiple operating modes
  - safety controls for workflows that mutate live config (ack flags, rollback, serialized execution where needed)
- Negative/failure-path testing coverage
- Upgrade/migration/regression test coverage (version bumps, chart upgrades, CRD changes, etc.)
- Drift detection / generated-artifact checks (e.g., "generate then git diff --exit-code") and docs/evidence gates
- Separation quality between CI and in-cluster smokes:
  - do not count CronJob-based continuous assurance as equivalent to PR CI
  - do not count workflow-driven runtime E2E as a replacement for ongoing smoke coverage
- Missing checks likely to allow production-impacting defects

Evidence rules (strict):
- Use only RUNTIME_CONTEXT as evidence.
- Every finding must cite concrete evidence with file paths (and preferably line numbers) or command/log excerpts from RUNTIME_CONTEXT.
- If RUNTIME_CONTEXT contains no CI-related evidence (no workflow/pipeline config, no CI scripts/targets, no CI logs/docs),
  output the NA format exactly (Reason should state that CI evidence is missing from the provided context).

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
Topic: CI Checks Thoroughness
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: CI Checks Thoroughness
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
