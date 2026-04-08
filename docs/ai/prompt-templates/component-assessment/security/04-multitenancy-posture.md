# Multitenancy Security Posture Prompt

```text
You are reviewing DeployKube for topic: multitenancy security posture, risks, and mitigations.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>  # component|project
- COMPONENT_NAME: <COMPONENT_NAME>  # issue_slug (tracker basename) or NA for project scope
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Task:
Assess isolation strength between tenants and identify cross-tenant risk.

Evidence + scoping rules:
- Use ONLY evidence present in RUNTIME_CONTEXT (and only from allowed paths if a context contract / file allowlist is included).
- Do not assume defaults or infer missing configuration.
- If you cannot find enough concrete evidence to assess multitenancy posture for this target, output NA.

Check at minimum:
- Tenant boundary definition and enforcement mechanism (namespace-per-tenant, cluster-per-tenant, AppProject/Project, etc.)
- Namespace isolation and admission policies/label contracts (Pod Security Admission, Gatekeeper/Kyverno, etc.)
- Cluster-scoped resources and escalation surfaces (CRDs, Validating/MutatingWebhookConfigurations, ClusterRoles/ClusterRoleBindings)
- RBAC boundaries and escalation paths (aggregated roles, impersonation, service account tokens, wildcard verbs/resources)
- Network isolation and egress control (NetworkPolicies, ingress controllers, DNS/service discovery, shared gateways/LBs)
- Secret and config isolation per tenant (Secrets/ConfigMaps, external secret stores, secret access patterns, encryption-at-rest expectations)
- Storage and node isolation (PVC/StorageClass boundaries, hostPath/privileged workloads, node pools/taints if used)
- Resource isolation and noisy-neighbor controls (ResourceQuotas, LimitRanges, PriorityClasses)
- Shared service blast radius (shared controllers, shared databases/brokers, shared observability) and tenant-to-tenant data paths
- Breakglass controls and auditability for tenant-impacting actions (who can override; logging/audit trails)

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
Topic: Multitenancy Posture
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Multitenancy Posture
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
