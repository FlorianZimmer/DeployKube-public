# DeployKube Multitenancy — Contracts & Enforcement Checklist

Last updated: 2026-01-21  
Status: **Checklist (Phase 0 enforced + Phase 1 partially implemented)**

This document is the “single page” summary of what multitenancy **claims** and where it is **enforced** (or not yet enforced).

MVP scope reminder:
- Queue #11 implements **Tier S (shared-cluster)** multitenancy first (S0 → S1 promotion gates).
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for the MVP and will require additional, separate contracts (cluster lifecycle + scheduling/hardware binding).

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy.md`
- Implementation tracker: `docs/component-issues/multitenancy-implementation.md`
- Related trackers:
  - Networking: `docs/component-issues/multitenancy-networking.md`
  - Storage: `docs/component-issues/multitenancy-storage.md`
  - Secrets/Vault: `docs/component-issues/multitenancy-secrets-and-vault.md`
  - Argo: `docs/component-issues/multitenancy-gitops-and-argo.md`

Goals:
- prevent contradictions between design docs and repo reality,
- make “implemented vs planned” obvious at review time,
- reduce ambiguity about *who* enforces a given tenant boundary (VAP vs Kyverno vs Argo vs RBAC).

Related:
- Tenancy model + truth table: `docs/design/multitenancy.md`
- Canonical label meanings + enforcement status: `docs/design/multitenancy-label-registry.md`
- Policy engine baseline and VAP/Kyverno split: `docs/design/policy-engine-and-baseline-constraints.md`
- GitOps/Argo boundaries: `docs/design/multitenancy-gitops-and-argo.md`
- Secrets + ESO guardrails: `docs/design/multitenancy-secrets-and-vault.md`
- Networking + ingress posture: `docs/design/multitenancy-networking.md`

---

## 1) Checklist (by enforcement surface)

| Contract | Scope | Enforced by | Status | Source / pointer |
|---|---|---|---|---|
| Tenant namespace label invariant: `tenant-id == observability.grafana.com/tenant` when `rbac-profile=tenant` | Namespace | VAP (CEL) | **Implemented** | `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-label-contract.yaml` |
| Tenant baseline resources exist + are drift-resistant (default-deny NetPol + DNS allow + same-ns allow + quota/limitrange) | Tenant namespaces | Kyverno generate | **Implemented** | `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml` |
| Tenant namespace identity is complete (`project-id` required) and identity labels are immutable (“set once”) | Namespace | VAP (CEL w/ `oldObject`) | **Implemented** | `platform/gitops/components/shared/policy-kyverno/vap/vap-tenant-namespace-identity-contract.yaml` |
| Tenant RBAC propagation: `rbac-profile=tenant` namespaces get label-derived RoleBindings (org + project groups); reconciliation is scale-safe (hash-annotated, skips unchanged) | Tenant namespaces | `rbac-namespace-sync` CronJob + admission guardrails + RBAC | **Implemented** | `platform/gitops/components/shared/rbac/base/namespace-sync/configmap.yaml` |
| Tenant NetworkPolicy guardrails: deny `ipBlock`, deny empty selectors, require identity scoping for cross-namespace allows | Tenant namespaces | Kyverno validate + CI gate | **Implemented (Phase 0)** | `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-deny-networkpolicy-ipblock.yaml`, `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-networkpolicy-guardrails.yaml`, `shared/scripts/tenant/validate-policy-aware-lint.sh` |
| Tenant ingress hijack prevention: no attachment to `public-gateway`, org-scoped hostname space, no cross-namespace backends by default, no NodePort/LoadBalancer exposure | Tenant namespaces + istio gateway | Gateway config + Argo AppProject allow/deny + Kyverno validate + RBAC | **Partially implemented (P0; DNS+Argo repo gates pending)** | `docs/design/multitenancy-networking.md#dk-mtn-ingress` |
| Tenants cannot create ESO CRDs while ESO uses broad `vault-core` store | Tenant namespaces | Kyverno validate (deny) (+ Argo/RBAC defense-in-depth) | **Implemented (Phase 1)** | `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-deny-external-secrets.yaml` |
| PVC guardrails: StorageClass allowlist + RWX restrictions in Tier S | Tenant namespaces | Kyverno validate | **Implemented (Phase 0)** | `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-pvc-storageclass-allowlist.yaml`, `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-pvc-deny-rwx.yaml` |
| Mesh posture decision for tenant ingress: remove global `*.local` `ISTIO_MUTUAL` default (or adopt “tenant in-mesh” instead) | istio mesh | Component change + smokes | **Implemented (P0)** | `docs/design/multitenancy-networking.md#dk-mtn-tenant-workloads-vs-mesh`, `platform/gitops/components/networking/istio/mesh-security/README.md` |
| “Hard GitOps boundaries in Argo” require repo-level separation | Argo | AppProject `sourceRepos` (repo-per-project) | **Planned (P0 for hostile tenants)** | `docs/design/multitenancy-gitops-and-argo.md#5-3-source-repos-repo-restrictions` |
| Support session TTL enforcement is Git-driven (no in-cluster-only cleanup) | Support session objects | CI gate + scheduled Git cleanup PR (+ alert-only in-cluster loop) | **Planned (P1)** | `docs/design/multitenancy-lifecycle-and-data-deletion.md#9-3-ttl-enforcement-required-before-we-productize` |

---

## 2) “No surprises” rules (review checklist)

- If a doc claims “required”, it must state whether it is **enforced by admission**, **enforced by Argo**, or is only a **GitOps convention**.
- Anything that relies on “tenants don’t have RBAC for it” should still have admission/policy guardrails if a platform/breakglass mistake would create cross-tenant blast radius.
- If two docs disagree, this checklist is updated first, then the detailed docs are reconciled.
