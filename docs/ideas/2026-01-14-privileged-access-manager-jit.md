# Idea: Privileged Access Management (PAM) for JIT + Audited Privileged Operations

Date: 2026-01-14  
Status: Draft

## Problem statement

DeployKube’s access posture is intentionally GitOps-first:
- authorization state changes (RBAC, AppProjects, Vault policy mappings, etc.) go through PR review (“four-eyes”) and are applied by Argo CD
- breakglass exists as an offline/exception path

This is a strong baseline, but it does not fully address common regulated/enterprise requirements for **privileged human access**:
- **Just-in-time (JIT) elevation** without repeatedly editing Git for short-lived incident work.
- **Strong auditability** beyond “RBAC changed in Git”: who requested access, who approved, why, for how long, and what was done during the session.
- **Session logging/recording** for interactive privileged operations (e.g., `kubectl exec`, shell sessions on infra hosts, breakglass-like remediation) with centralized retention and exportability (SIEM-ready).

In other words: DeployKube needs a credible “privileged access plane” that complements the existing “authorization-as-code” model without weakening it.

Related docs:
- Access contract (current foundations + guardrails): `docs/design/cluster-access-contract.md`
- Access model idea (mentions “JIT via Git” and external PAM/JIT products): `docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`
- Tracker for access guardrails: `docs/component-issues/access-guardrails.md`

## Why now / drivers

- **Multi-tenant / hosted direction** increases blast radius: privileged access must be a productized workflow, not an ad-hoc practice.
- **Support readiness**: a future “support session” needs time-bound elevated access with strong audit trails.
- **Breakglass hygiene**: a usable PAM reduces pressure to rely on offline kubeconfigs for anything other than true emergencies.
- **Compliance posture**: many environments require provable JIT access controls + audit logging + retention guarantees.

## Proposed approach (high-level)

Introduce a **Privileged Access Manager (PAM)** as DeployKube’s “human privileged access plane”:

1) **Keep GitOps as the authority for *what privileges may ever be granted***  
   Git continues to define:
   - which privileged roles exist (“breakglass-equivalent”, “platform-debug”, “tenant-support”, etc.)
   - their maximum scope (clusters, namespaces, AppProjects, Vault paths, infra targets)
   - the guardrails preventing manual RBAC mutation bypass

2) **Use PAM for *time-bound acquisition* of those privileges**  
   PAM provides runtime workflows:
   - request → approve (four-eyes, reason required) → grant for TTL → auto-revoke
   - optional “incident binding”: every privileged session attaches to a ticket/incident ID

3) **Session-level auditability as a first-class feature**  
   PAM must emit centrally collected logs/records:
   - request/approval events (who/when/why/scope/ttl)
   - access token issuance events (what was issued; TTL)
   - session activity logs (commands, exec/pty streams, file transfers if applicable)
   - immutable retention + export (object storage / SIEM forwarder)

4) **Prefer brokering/gatewaying over distributing long-lived credentials**  
   The ideal is “no privileged credential leaves the PAM boundary”, e.g.:
   - Kubernetes access through a PAM Kubernetes proxy/gateway (auditable `exec`, port-forward, etc.)
   - infra access through a PAM SSH/HTTP gateway with session recording

5) **Do not let PAM become a bypass of the GitOps access contract**  
   PAM must not enable granting privileges that are not pre-authorized by Git:
   - PAM configuration is GitOps-managed (like other platform components)
   - PAM roles map to a controlled allowlist of K8s roles / Vault policies / infra targets
   - the cluster’s admission guardrails still prevent “kubectl bypass” RBAC mutations

### Scope (phased)

Phase 0 (minimum viable PAM):
- Kubernetes privileged access (platform cluster) through a brokered path with TTL + audit trail.
- Support for “elevated troubleshooting” roles that are narrower than `cluster-admin`.

Phase 1:
- Extend to “infrastructure access” targets (e.g., Proxmox host SSH, out-of-band tooling) with session recording.
- Integrate with “support session” concepts (tenant-scoped, time-boxed).

Phase 2:
- Optional secret checkout workflows (Vault breakglass material) with approvals and audit trails, without leaking long-lived tokens.

## What is already implemented (repo reality)

- A GitOps-first access model and guardrails exist (OIDC for humans, RBAC via Git, admission guardrails, breakglass SOP): `docs/design/cluster-access-contract.md`.
- Access-guardrails are tracked and operated as a component: `docs/component-issues/access-guardrails.md`.
- Keycloak is the identity foundation for human auth (OIDC) across platform services (`target-stack.md` and component READMEs).

## What is missing / required to make this real

### 1) Define the “privileged access inventory”

Explicitly list privileged targets and operations, and assign them to PAM-controlled roles:
- Kubernetes clusters (platform + tenant clusters)
- Argo CD admin actions (if any are permitted outside Git)
- Vault admin/breakglass operations
- infra hosts (Proxmox), bootstrap endpoints, and “last-resort” recovery paths

This inventory is needed to keep PAM role definitions tight and avoid a generic “super-admin” bucket.

### 2) Choose a PAM implementation path

Candidate patterns (not exhaustive):
- **Dedicated PAM product (self-hosted)** that supports OIDC login + approvals + session recording + K8s/SSH gateways.
- **“JIT via Git” controller (in-cluster)** (e.g., an `AccessGrant` CRD that creates temporary RoleBindings) paired with strong Kubernetes audit logging.
- **Vault-centric JIT** (dynamic creds + audit logs) combined with separate session logging tooling.

The selection should be driven by: session recording requirements, operational burden, offline/air-gapped constraints, and how well it preserves the GitOps access boundary.

### 3) Central audit logging + retention contract

Define (and implement) a consistent contract for privileged access logs:
- where logs live (cluster-local vs centralized)
- retention periods and immutability expectations
- export formats and SIEM forwarding
- how to correlate events across systems (request ID / incident ID)

### 4) Workflow integration points

Document and standardize:
- Keycloak integration (AuthN, group/claim mapping)
- approval model (who can approve what; four-eyes policy)
- breakglass interplay (when PAM is unavailable, what’s the fallback)
- environment parity (mac-orbstack vs proxmox-talos) and what “good enough” looks like in dev

## Risks / weaknesses

- **Tier-0 dependency risk**: PAM becomes operationally critical during incidents; HA and clear failure modes are required.
- **Boundary erosion**: if PAM can grant broad privileges without Git review, it undermines the access contract; strict role allowlists are mandatory.
- **Logging sensitivity**: session recording can capture secrets and personal data; redaction strategy and access controls for audit logs are required.
- **Complexity vs value**: a full PAM product may be heavy for “small install” scenarios; phase 0 must deliver value with minimal operational cost.

## Alternatives considered

- **Only “JIT via Git”** (temporary RBAC bindings via PR): strongest Git audit trail, but slow for incidents and lacks session recording.
- **Rely purely on Kubernetes audit logs**: good for API events, weak for interactive context and non-Kubernetes targets.
- **Breakglass as the default incident tool**: operationally convenient, but fails compliance expectations and increases uncontrolled privileged use.

## Open questions

- What is the required granularity of “session recording” for Kubernetes?
  - API-audit-only vs command-level logs vs full TTY recording for `exec`
- What are the initial “must-cover” privileged targets for DeployKube v1?
- What is the expected approval SLA (minutes) for production incidents, and how does that shape four-eyes workflows?
- How do we ensure logs are immutable and accessible to auditors without exposing sensitive session contents broadly?
- What is the minimum acceptable behavior when PAM is down (breakglass, read-only mode, etc.)?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A concrete PAM architecture choice (product/pattern) with a clear “Git defines max privilege; PAM grants JIT within it” boundary.
- A minimal prototype that demonstrates:
  - request → approval → TTL grant → auto-revoke
  - centralized audit events + retention plan
  - a Kubernetes privileged access path with meaningful session logs
- A failure-mode story (PAM down, Keycloak down, partial network failure) that fits the existing breakglass contract.
- A high-level GitOps change plan (new component(s) under `platform/gitops/components/**`, plus required docs/runbooks).

