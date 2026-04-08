# multitenancy-networking design issues

Canonical issue tracker for:
- `docs/design/multitenancy-networking.md`

Related trackers:
- Multi-tenancy core: `docs/component-issues/multitenancy.md`
- Istio: `docs/component-issues/istio.md`
- Cilium: `docs/component-issues/cilium.md`
- certificates/ingress: `docs/component-issues/certificates-ingress.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### Medium

#### renderer-retirement-tier-s
- Eliminate TenantRegistry as a networking input: (ids: `dk.ca.finding.v1:multitenancy-networking:2814ff8ad894776b9537720ea7369452336ff90198775365e737d4d096364985`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- **Eliminate `TenantRegistry` as a networking input**:\n  - Stop reading `platform/gitops/apps/tenants/base/tenant-registry.yaml` for anything networking-related.\n  - Source of truth becomes the Tenant API (`Tenant`/`TenantProject`) so the same API drives gateways, DNS/TLS, and egress.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-networking:2814ff8ad894776b9537720ea7369452336ff90198775365e737d4d096364985", "last_seen_at": "2026-02-25", "recommendation": "Eliminate TenantRegistry as a networking input:", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Eliminate TenantRegistry as a networking input:", "topic": "renderer-retirement-tier-s"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

### 2026-01-29 — Egress proxy is controller-owned (renderer retired)
- Tenant egress proxy moved from repo-side renderer outputs to controller-owned reconciliation from the Tenant API (`TenantProject.spec.egress.httpProxy.allow[]`).
-

### 2026-01-21 — Networking productization: tenant DNS/TLS + platform egress proxy + budgets
- Finalized Tier S tenant DNS/TLS contract (`<app>.<orgId>.workloads.<baseDomain>`) and wired it end-to-end: tenant gateways, per-org wildcard certificates, and DNS wildcard records.
- Implemented a platform-managed egress proxy (Squid forward proxy) with:
  - PR-authored per-project allowlist intent (minimal tenant request surface),
  - HA by default (2 replicas + PDB),
  - per-org budgets via ResourceQuota.
- Filled the budgets section with concrete numbers and explicit switch thresholds.
- Extended the Kyverno smoke suite to prove:
  - direct internet egress is denied by default for tenants,
  - internet egress via the proxy works for allowlisted domains only.
-

### 2026-01-20 — Tenant NetworkPolicy guardrails + ingress→tenant backend smoke
- Enforced tenant NetworkPolicy guardrails (Kyverno): deny `ipBlock`, deny empty peers / unbounded selectors, require tenant-scoped `namespaceSelector`s, and restrict platform destinations via allowlists (DNS/kube-dns, Istio ingressgateway, Garage S3).
- Extended the Kyverno smoke suite to prove tenant gateway → tenant backend connectivity end-to-end (in-mesh gateway → out-of-mesh backend), in addition to existing ingress guardrails.
-

### 2026-01-16 — Tenant gateway pattern (Tier S default ingress model)
- Implemented per-org tenant Gateway attach points (`Gateway/istio-system/tenant-<orgId>-gateway`) with `allowedRoutes.namespaces.from: Selector` keyed by `darksite.cloud/tenant-id=<orgId>`.
- Tightened route-hijack prevention: tenant `HTTPRoute` parentRefs are now limited to the tenant gateway (and still forbidden from `public-gateway`).
-

### 2026-01-14 — Mesh posture (auto-mTLS; avoid global `*.local` client-side forcing)
- Removed the mesh-wide `DestinationRule` that forced `ISTIO_MUTUAL` for `*.local` (rely on Istio auto-mTLS).
- Added `Job/istio-mesh-posture-smoke` to continuously prove:
  - in-mesh ↔ in-mesh succeeds,
  - out-of-mesh → in-mesh fails (STRICT is real),
  - in-mesh → out-of-mesh succeeds (no per-service exception sprawl required).
-

### 2026-01-14 — Ingress hardening (route hijack prevention)
- Platform `Gateway/public-gateway` route attachment restricted to namespaces labeled `deploykube.gitops/public-gateway=allowed` (no tenant attachments by default).
- Tenant Gateway API guardrails (Kyverno): deny `Gateway`/`ReferenceGrant`, forbid `HTTPRoute` attachment to `public-gateway`, deny cross-namespace `backendRefs`, require hostname ownership.
- Evidence:

### 2026-01-06
- Normalized the VPC folder contract example and clarified the tenant `NetworkPolicy` `ipBlock` stance (all egress via a platform-managed gateway/proxy).
- Recorded the Tier S default ingress model (per-org Gateway) and the mesh posture decision (auto-mTLS; avoid `*.local` client-side forcing).
