# Network Boundaries & Traffic Policy Prompt

```text
You are reviewing DeployKube for topic: Network Boundaries and Traffic Policy.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>  # component | project
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Scope and evidence rules (strict):
- Use ONLY the provided RUNTIME_CONTEXT as evidence (and any referenced workpack scoping docs included in it).
- Do NOT assume cluster-wide defaults, mesh policies, or firewall rules unless explicitly shown.
- If the topic is relevant but the RUNTIME_CONTEXT does not contain enough evidence to assess it, output NA (Reason: Insufficient evidence in provided context).

Task:
Assess whether network exposure, isolation, and traffic policy are safe and intentional for this TARGET_SCOPE.

Check at minimum (tailor to what exists in context):
- Exposure surface:
  - Services/Ingress/Gateway resources that expose workloads (LoadBalancer/NodePort, Ingress, Gateway, VirtualService).
  - HostNetwork/hostPort usage and explicit externalTrafficPolicy.
  - Public DNS hostnames or wildcard hosts tied to external exposure.
- Lateral movement boundaries:
  - NetworkPolicy presence and default-deny posture for namespaces/tenants.
  - Namespace selectors and label-driven isolation (avoid overly broad selectors).
  - Cross-namespace access paths and explicit allowlists.
- Egress control:
  - Egress NetworkPolicies, egress gateways/proxies, or explicit allowlists.
  - External dependency endpoints and whether egress is constrained.
- Mesh or authz policy (if present in context):
  - mTLS enforcement (PeerAuthentication/DestinationRule).
  - AuthorizationPolicy or equivalent L7 policies that enforce least privilege.
- Operational evidence:
  - Tests, runbooks, or policy docs confirming intended boundaries (only if in context).

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
Topic: Network Boundaries and Traffic Policy
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Network Boundaries and Traffic Policy
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
