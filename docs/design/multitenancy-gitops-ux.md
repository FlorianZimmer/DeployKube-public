# DeployKube Multitenancy — GitOps UX Model (Future UI)

Last updated: 2026-01-06  
Status: **Design (future; UI is not a control plane)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy.md`

---

## 1) Core posture

The UI is not a control plane. It is:
- a **Git authoring client** + **validation runner** + **status dashboard**

This doc exists to keep `docs/design/multitenancy.md` focused on the tenancy contracts.

---

## 2) UI actions (examples)

- “Create Org” → generates folder + namespace templates + PR
- “Create Project” → adds namespaces, RBAC labels, optional VPC attachments
- “Request firewall allow” → adds a reviewed allow policy manifest
- “Expose service” → creates HTTPRoute + DNS records (still via Git) and runs validation gates

---

## 3) Validation gates (must be first-class)

Before merge, UI/CI runs:
- render (kustomize/helm)
- schema checks
- policy checks (Kyverno/OPA-style checks if added; baseline lint at minimum)
- dry-run apply (server-side validation where possible)
- ownership checks (org/project boundaries)
- tenancy safety checks (recommended):
  - namespace/name/id constraints (length/charset)
  - route attachment + hostname ownership constraints
  - disallow direct exposure `Service` types in tenant namespaces (unless explicitly approved)
  - reject expired “SupportSession” exceptions

---

## 4) Convergence and status model

UI shows states aligned to GitOps reality:
- Draft → PR open → Approved → Merged
- Argo: OutOfSync → Syncing → Synced/Healthy (or failed)
- Smoke checks: pass/fail, with links to evidence entries

