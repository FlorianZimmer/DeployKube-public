# Kubernetes Best Practices Prompt

```text
You are reviewing DeployKube for topic: Kubernetes Best Practices.

Runtime input:
- TARGET_SCOPE: <TARGET_SCOPE>
- COMPONENT_NAME: <COMPONENT_NAME>
- COMPONENT_PATH: <COMPONENT_PATH>
- RUNTIME_CONTEXT:
<RUNTIME_CONTEXT>

Task:
Assess Kubernetes implementation quality (manifests/charts/overlays/deployment docs in context) for correctness, operability, and maintainability.

Relevance test (decide first):
- Applicable if RUNTIME_CONTEXT includes Kubernetes resources (raw YAML, Helm templates/values, Kustomize overlays) or docs that clearly describe Kubernetes deployment behavior for this target.
- Otherwise output NA format exactly (do not infer missing manifests).

Check at minimum:
- Resource requests/limits and scheduling realism
- Probe correctness and rollout safety
- API version/kind correctness and deprecation risk (removed/obsolete APIs, mismatched fields for the apiVersion)
- Termination and rollout safety settings (terminationGracePeriodSeconds, preStop hooks, updateStrategy, progressDeadlineSeconds, minReadySeconds when present)
- Namespace and label/annotation hygiene
- Service and ingress/gateway consistency (only if those resources exist in context)
- NetworkPolicy consistency (only if NetworkPolicy resources exist OR docs/policies in context state they are required)
- StatefulSet/Deployment/Job/CronJob usage correctness
- Storage class/PVC behavior and lifecycle assumptions
- Argo CD sync wave/hook usage for dependency order (only if Argo CD resources/annotations/docs appear in context)

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
Topic: Kubernetes Best Practices
Relevance: NA
Reason: <one clear reason: Not applicable | Insufficient evidence in provided context>
Findings: NA

Applicable format:
Topic: Kubernetes Best Practices
Relevance: Applicable
Findings (JSONL):
{"class":"actionable","severity":"medium","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}
{"class":"architectural","severity":"high","title":"...","evidence":[{"path":"...","resource":"...","key":"..."}],"risk":"...","recommendation":"...","track_in":"docs/component-issues/<COMPONENT_NAME>.md"}

```
