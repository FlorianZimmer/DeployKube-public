# Master delivery queue (repo-wide)

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
- (none)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

This is the **single ordering doc** for “what to implement next” across DeployKube.

Non-goal: duplicate tracking. Completion status lives in the canonical component trackers under `docs/component-issues/*.md`.

How to use:
1) Pick the next queue item below.
2) Implement via GitOps (`platform/gitops/**`) + docs/evidence.
3) Close the corresponding items in the linked tracker(s).

---

## Queue (best-order, refactor-minimizing)

Legend:
- “Close open items” means: complete whatever is currently listed under that tracker’s **Open** section.
- Multitenancy has its own PR-by-PR sub-queue; this master queue **links** to it (no duplication).

| Order | Workstream | Why this comes next | Canonical tracking |
|---:|---|---|---|
| 1 | Repo hygiene + guardrails | Cheap upfront guardrails reduce later rework (evidence format consistency, bootstrap contract checks, DeploymentConfig hygiene). | `docs/component-issues/gitops-operating-model.md`, `docs/component-issues/deployment-config-contract.md` |
| 2 | Secrets custody / DSB hardening | Prevent “can’t rebootstrap safely” failures before broadening surface area. | `docs/component-issues/deployment-secrets-bundle.md` |
| 3 | Platform access-plane readiness | Prove OIDC runtime, breakglass readiness, and alerting hooks before depending on them for ops/tenants. | `docs/component-issues/access-guardrails.md`, `docs/component-issues/keycloak.md` |
| 4 | GitOps control-plane smoke + isolation | Argo/Forgejo are the platform’s control plane; lock in smokes and minimum isolation early. | `docs/component-issues/argocd.md`, `docs/component-issues/forgejo.md`, `docs/component-issues/shared-rbac.md`, `docs/component-issues/shared-rbac-secrets.md` |
| 5 | DNS + PKI “always works” | DNS/TLS are transitive dependencies of almost everything; make failures loud and eliminate ambiguous mesh-injection postures. | `docs/component-issues/coredns.md`, `docs/component-issues/powerdns.md`, `docs/component-issues/external-sync.md`, `docs/component-issues/cert-manager.md`, `docs/component-issues/step-ca.md`, `docs/component-issues/certificates-ingress.md` |
| 6 | L4/L7 ingress plumbing reliability | Stabilize the ingress substrate before tightening tenancy boundaries (smokes, reachability, exposure posture). | `docs/component-issues/metallb.md`, `docs/component-issues/gateway-api.md`, `docs/component-issues/istio.md`, `docs/component-issues/kiali.md`, `docs/component-issues/cilium.md`, `docs/component-issues/hubble.md` |
| 7 | OpenBao + ESO hardening | OpenBao/ESO are the primary secret plane (implemented via the `secrets/vault` component path for compatibility); harden before tenants/service catalog expand usage. | `docs/component-issues/vault.md`, `docs/component-issues/external-secrets.md`, `docs/design/openbao-secret-plane-kms-shim.md` |
| 8 | Storage baseline hardening (incl. review feedback closure) | Storage is a major blast radius; settle default StorageClass posture, backup-plane confidentiality baseline, and backend reachability boundaries before widening the service catalog. | `docs/component-issues/shared-rwo-storageclass.md`, `docs/component-issues/garage.md`, `docs/component-issues/storage-single-node.md`, `docs/component-issues/storage-multi-node-ha.md`, `docs/component-issues/backup-system.md`, `docs/component-issues/multitenancy-storage.md`, `docs/component-issues/local-path-provisioner.md` |
| 9 | Data services foundations | Ensure Postgres/Valkey patterns have smokes/backups/security before exposing them as primitives. | `docs/component-issues/cnpg-operator.md`, `docs/component-issues/data-services-patterns.md`, `docs/component-issues/postgres-keycloak.md`, `docs/component-issues/postgres-powerdns.md`, `docs/component-issues/valkey.md` |
| 10 | Observability product completeness | Observability unlocks alerting/staleness gates for everything else; finish smokes + security + HA posture. | `docs/component-issues/observability.md`, `docs/component-issues/resource-contract.md`, `docs/component-issues/policy-kyverno.md`, `docs/component-issues/platform-ops.md` |
| 11 | Multitenancy as a product (Tier S) | Execute the detailed PR-by-PR sequence once foundations above are stable; avoid big refactors. Scope is **Tier S only** (shared-cluster logical isolation); do not implement dedicated-cluster/hardware work here, but keep Tier S contracts portable for later D/H. | `docs/component-issues/multitenancy-pr-queue.md`, `docs/component-issues/multitenancy-implementation.md` |
| 12 | Backup/DR baseline completion | DR is cross-cutting and easier once the service catalog and policies stabilize. | `docs/component-issues/backup-system.md` |
| 13 | Dev→prod promotion doctrine | Lock in evidence/guardrails for promotion once components have real smokes to cite. | `docs/component-issues/dev-to-prod-promotion.md` |
| 14 | Design coverage cleanup | Close “missing design docs” once component shapes settle; avoid thrash from docs rewrites during refactors. | `docs/component-issues/design-docs-missing.md` |
| 15 | Distribution bundles + cloud roadmap follow-ups | Productization work that benefits from a stabilized, smoke-tested platform. | `docs/component-issues/distribution-bundles.md`, `docs/component-issues/cloud-productization-roadmap.md` |
| 16 | Example apps (opt-in) | Keep these last: they should not block platform/tenant claims. | `docs/component-issues/factorio.md`, `docs/component-issues/minecraft-monifactory.md` |

---

## Notes on “don’t track twice”

- The queue above is ordering-only.
- Each row is “done” when the linked tracker(s) have no relevant open items left for that row’s scope, and evidence exists for the shipped changes.

### Queue #8 implementation order (risk-minimizing sub-order)

This sub-order is informational only; the canonical completion status remains in the linked trackers.

1) **P0-1** Contract correctness: canonical backup layout + backup-system existence.
2) **P0-2** Garage reachability truth: align Garage `NetworkPolicy` repo reality + docs.
3) **P0-3** Backup confidentiality baseline: encrypt tier-0 artifacts at rest on the backup target + restore procedure.
4) **P0-4** Tenant S2/S4 guardrails (scoped): enforce backend reachability + secret projection denies for tenant-labeled namespaces + negative tests.
5) **P1-5** local-path README baseline posture: fill in Security/HA/Backup expectations.
6) **P1-4** Garage docs hygiene: align prod overlay wording + backup story across docs/READMEs.
7) **P1-6** NFS standard profile posture: make SPOF/unencrypted tradeoffs explicit + document mitigations/exit ramp.
8) **P1-3** Add cheap “data plane” validation: `shared-rwo` latency smoke (small write+fsync loop; low frequency).
9) **P1-1** Remove backup-system config drift: single source of truth for DeploymentConfig consumption.
10) **P1-2** Remove runtime installs: stop `apk add rclone` in backup jobs (may require publishing an updated tools image).
11) **P2** Roadmap hardening: Ceph threat model + decision gates; backup path unification; small version/label consistency fixes.

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->
