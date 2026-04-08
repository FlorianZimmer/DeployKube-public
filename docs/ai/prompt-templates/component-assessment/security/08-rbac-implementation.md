# RBAC Implementation Prompt

```text
You are reviewing DeployKube for topic: RBAC Implementation.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>           # component | project
- COMPONENT_NAME: <COMPONENT_NAME>       # issue slug used for tracker filenames, or NA
- COMPONENT_PATH: <COMPONENT_PATH>       # repo-relative path, or NA
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scoping rules (must follow):
- Use only evidence present in RUNTIME_CONTEXT (and any included allowlists such as context/file-list.txt).
  Do not assume files/config that are not shown.
- If RBAC is relevant but not assessable from the provided RUNTIME_CONTEXT (e.g., no Role/ClusterRole/Binding/ServiceAccount
  manifests or docs describing required permissions), output NA using the NA format below with a clear Reason.
- Do not invent Kubernetes objects, namespaces, or file paths.

Task:
Assess whether Kubernetes RBAC follows least privilege and avoids privilege-escalation paths.

What to inspect (minimum checklist):
1) RBAC objects present/used
- Role, ClusterRole, RoleBinding, ClusterRoleBinding, ServiceAccount (including any use of the default ServiceAccount)
- Aggregated ClusterRoles (labels: rbac.authorization.k8s.io/aggregate-to-*)
2) Scope correctness
- Namespaced permissions use Role/RoleBinding unless cluster-scoped resources are required
- ClusterRole/ClusterRoleBinding usage is justified and tightly scoped
3) Privilege-escalation risks (high priority)
- Permissions to create/update/patch/delete: roles, rolebindings, clusterroles, clusterrolebindings, serviceaccounts
- Verbs/resources enabling escalation: bind, escalate, impersonate, subjectaccessreviews, tokenreviews
- Broad write access to secrets, pods/exec, pods/portforward, nodes, namespaces
- Wildcards in apiGroups/resources/verbs or nonResourceURLs
4) Binding precision
- Bindings target specific ServiceAccounts (name + namespace); avoid broad groups (system:authenticated, system:serviceaccounts, etc.)
- Prefer RoleBinding over ClusterRoleBinding when possible
5) Tenant vs platform separation
- Tenant-facing roles cannot mutate platform namespaces or cluster-scoped resources
- Platform operators/controllers use separate SAs/roles from tenant workloads
6) Controls around RBAC changes (only if evidence exists in context)
- Admission policies (e.g., Kyverno/Gatekeeper) or GitOps protections limiting RBAC mutation
- Audit log visibility and reviewability for RBAC changes
7) Breakglass
- Privileged roles are documented, time-bound, and auditable; no standing wide-open bindings

Severity guidance:
- Critical: direct path to cluster-admin / full namespace takeover (e.g., RBAC mutation perms + bind/escalate/impersonate, wildcard ClusterRoleBinding)
- High: broad secret access or pod exec/portforward across many namespaces; excessive cluster-scoped access
- Medium: overbroad verbs/resources within a single namespace; missing justification/documentation
- Low: hygiene/consistency issues that do not materially increase access

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
Topic: RBAC Implementation
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: RBAC Implementation
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
