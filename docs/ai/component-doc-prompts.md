# Component documentation prompts (DeployKube)

These prompts are intended for repo-first documentation work: validate only against what is implemented in this repo (no cluster-state checks).

## Prompt 1 (Docs parity + README restructure; repo-only validation)

```text
Please work on component path: <COMPONENT_PATH> (relative to platform/gitops/components/, e.g. platform/argocd or secrets/vault).

Scope/ground truth:

- Validate documentation ONLY against what is implemented in-repo: platform/gitops/ (manifests/values/kustomize) + anything it references under shared/.
- Ignore live cluster-state (no kubectl / argocd validation).

Docs to check/update (only if relevant to this component):

- target-stack.md
- agents.md
- Authoritative component doc: platform/gitops/components/<COMPONENT_PATH>/README.md
- docs/component-issues/<COMPONENT_NAME>.md (open items live here; keep it consistent)
- docs/design/** (component design docs for complex implementations; add/update only if warranted)
- docs/guides/** (end-user guides; add/update links from the component README as needed)

Rules for this pass:

- Do NOT analyze or fill: Smoke jobs/Test coverage, HA posture, Security, Backup and restore. Leave these sections empty except for a single one-liner like “Not assessed in Pass 1.”
- Do NOT put TODO/Open Points lists into the component README. Instead add a single line in the README pointing to docs/component-issues/<COMPONENT_NAME>.md.

README restructure requirement:

- Restructure platform/gitops/components/<COMPONENT_PATH>/README.md to exactly include these chapters (keep content accurate to implementation; add “Not assessed in Pass 1.” where required):
  - # Introduction
  - ## Architecture
  - ## Subfolders
  - ## Container Images / Artefacts (mention specific versions of charts/images)
  - ## Dependencies
  - ## Communications With Other Services
    - Kubernetes Service → Service calls
    - External dependencies (Vault, Keycloak, PowerDNS)
    - Mesh-level concerns (DestinationRules, mTLS exceptions)
  - ## Initialization / Hydration
  - ## Argo CD / Sync Order
    - The sync wave annotation value
    - Pre/PostSync hooks used
    - Sync dependencies (which apps must be healthy before this one syncs)
  - ## Operations (Toils, Runbooks) (link to relevant docs/guides/** and docs/toils/**)
  - ## Customisation Knobs
  - ## Oddities / Quirks
  - ## TLS, Access & Credentials
  - ## Dev → Prod
  - ## Smoke Jobs / Test Coverage (one-liner: “Not assessed in Pass 1.”)
  - ## HA Posture (one-liner: “Not assessed in Pass 1.”)
  - ## Security (one-liner: “Not assessed in Pass 1.”)
  - ## Backup and Restore (one-liner: “Not assessed in Pass 1.”)

Give me feedback if any chapter is missing in your opinion for this component and tell me so I can add it to the master template.
You are allowed to leave chapters empty (with a one liner explaining why) if they dont apply for this service.

Workflow:

- Work component-by-component.
- After finishing <COMPONENT_NAME>, summarize what changed (files + high-level), and STOP for confirmation before moving to the next component.
```

## Prompt 2 (Quality attributes + smoke/HA/backup planning)

```text
Please work on component path: <COMPONENT_PATH> (relative to platform/gitops/components/, e.g. platform/argocd or secrets/vault).

Scope/ground truth:

- Validate and reason from repo-only implementation: platform/gitops/ + referenced shared/ (no cluster-state checks).

Goals:

- Analyze and fully document these README sections for this component:
  - Smoke Jobs / Test Coverage
  - HA Posture
  - Security
  - Backup and Restore

Missing implementation handling:

- If any required capability is missing/not implemented (e.g., no smoke job, no TLS wiring where expected, no backup/restore mechanism, no HA/failover story), record it as an actionable item in docs/component-issues/<COMPONENT_NAME>.md (not in the README).

Smoke-test doctrine for this pass:

- Plan smoke jobs/tests for everything that matters.
- Verify external reachability if the service is supposed to be reachable from outside (document expected ingress/hostname and how to test).
- Ensure functional correctness (not just “pod is running”): propose concrete checks that prove the service works and is healthy (no warnings/errors).
- If there is no smoke job that tests real functionality, treat it as “not working” and track it in component-issues.

Planning requirements:

- Provide a concrete smoke-job/test plan including:
  - Basic health + functional checks
  - Dependency checks (what must be up first)
  - Failover/HA validation steps (where HA is claimed/required)
  - Backup + restore validation steps (include a real restore test plan)

Repo conventions:

- When proposing Kubernetes Jobs in Istio-injected namespaces, follow the repo’s standard pattern: Istio native sidecars + istio-native-exit.sh helper.

Workflow:

- Update platform/gitops/components/<COMPONENT_PATH>/README.md with the analysis and plans.
- Update docs/component-issues/<COMPONENT_NAME>.md with missing/uncertain items.
- Summarize changes and STOP for confirmation before moving to the next component.
```
