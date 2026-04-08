# Backup and Recovery Prompt

```text
You are reviewing DeployKube for topic: Backup and Recovery.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>  # component|project
- COMPONENT_NAME: <COMPONENT_NAME>  # tracker slug (issue_slug) for docs/component-issues/* (use NA for project scope)
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope + evidence rules (must follow):
- Use only evidence contained in RUNTIME_CONTEXT (including any workpack allowlist text embedded in it). Do not use outside knowledge.
- Do not infer that something is missing from the repo just because it is missing from RUNTIME_CONTEXT.
- If RUNTIME_CONTEXT does not contain enough backup/restore material to assess this topic for this target, output NA (Reason must describe the evidence gap).

Task:
Assess whether backup and recovery are defined, testable, and suitable for production/market-ready operation for this target.

Check at minimum (only when evidence exists in context):
- Declared backup scope and exclusions (what is backed up vs intentionally not backed up)
- RPO/RTO targets (if stated) and evidence they are feasible or tested
- Backup implementation details: schedule/frequency, retention, where backups are stored (off-cluster/offsite), encryption/access controls
- Restore runbooks and restore automation maturity
- Dependency ordering and preconditions during restore (including “restore into a fresh environment” if applicable)
- Secret/credential recovery path (KMS keys, external secret stores, token/credential re-issuance)
- Post-restore verification steps (smoke tests, data integrity checks)
- Evidence of restore drills/game days (not just backup success)
- Monitoring/alerting and CI/validation coverage for backup + restore behavior (when applicable)

Severity rubric:
- High: likely data loss, inability to restore, unknown/untested recovery, or RPO/RTO clearly unmet
- Medium: restore is possible but too manual/fragile; partial coverage; weak monitoring/testing
- Low: documentation clarity, minor gaps, or incremental hardening

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
Topic: Backup and Recovery
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Backup and Recovery
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
