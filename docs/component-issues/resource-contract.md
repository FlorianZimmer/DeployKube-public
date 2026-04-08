# resource-contract design issues

Canonical issue tracker for the cross-cutting **resource contract** design (`docs/design/resource-requests-and-limits-enforcement.md`).

This file tracks what is still missing to consider the design “fully implemented”, across components (policy, observability, tenants).

Design:
- `docs/design/resource-requests-and-limits-enforcement.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### coverage-expansion-platform-namespaces
- Expand darksite.cloud/resource-contract=strict beyond observability namespaces (phase-by-phase), keeping each namespace clean before opt-in. (ids: `dk.ca.finding.v1:resource-contract:c93a475b0e6118479e06649d7b72d50414f5ddd6d8aaef83c954121aee409ba3`)

#### operator-created-pods-crd-aware-validation-phase-2
- Add CI checks for selected CRDs that create Pods (e.g., CNPG Cluster.spec.resources) so we don’t rely only on admission/runtime for those. (ids: `dk.ca.finding.v1:resource-contract:6be8ebfead8031e5404d0b84689f9cdbd352e4aa29e048de2b428bcc04514970`)

#### tenant-policy-phase-3
- Decide tenant enforcement approach (CI-only vs Kyverno validate vs VAP), given tenant LimitRange defaults. (ids: `dk.ca.finding.v1:resource-contract:afa900104789145bb2a009d304eefeb541817b13b4897fba0b1a2936ad0bcb47`)

- If enforcing, define the exception mechanism (Kyverno PolicyException + expiry). (ids: `dk.ca.finding.v1:resource-contract:165100d390ad4490a5109e0ec7ff7aee3a5c4b4fc72bc2e4554ead4bd0e0a48f`)

### Medium

#### coverage-expansion-platform-namespaces
- Expand CI validation discovery beyond components/platform/observability/** when new strict namespaces are introduced elsewhere. (ids: `dk.ca.finding.v1:resource-contract:909a622a146569d9fecb6466e2947511be4abb3a9a420a5fa13a1ab2a1817f55`)

#### post-stability-sizing-backport-platform-wide
- Any remaining CPU limits are either removed (preferred) or intentionally kept with an explicit justification. (ids: `dk.ca.finding.v1:resource-contract:82824abc1570d5a5553bc9d43d32f7dae68d96a0fa03f87581354709334fbc68`)

- Apply CPU requests from VPA to infrastructure services and backport into GitOps (use scripts/toils/vpa-apply-recommendations.py --backport-gitops). (ids: `dk.ca.finding.v1:resource-contract:3538d6a7b3998260a98296b8b36a9901fbbb85c1b55771ba24e23b6ffb27b65e`)

- Apply memory requests from VPA to infrastructure services and backport into GitOps. (ids: `dk.ca.finding.v1:resource-contract:2ca136d603a517888a2c9b6c88a77f33540f7cacf3e0f67bcee7cde9b1ca30ee`)

- For apps: do not enforce requests=limits by default; only backport if/when needed (explicit per-app decision + evidence). (ids: `dk.ca.finding.v1:resource-contract:5df123ad72780bc9d9bb7c34b04020de9d72fc5d7d29cd806a45342a44849e04`)

- For infrastructure services where we enforce requests=limits for memory, decide the policy: target+floor vs per-workload exception (do not blindly apply upper bounds cluster-wide). (ids: `dk.ca.finding.v1:resource-contract:e6545dc3e844bfb75f82c9d83746ea9f23f4d6856469dfcd53e1bd3e2f1c495e`)

- For infrastructure services: set memory limits = memory requests (per component policy), but only after verifying no OOMKill regression and ensuring the chosen bound is appropriate. (ids: `dk.ca.finding.v1:resource-contract:0938d9d89ab3fc2e50a7da5b780a8fa72d8fd230f00aa00a7c9b9546002692e2`)

- Inventory baseline:. (ids: `dk.ca.finding.v1:resource-contract:f2b45e2a88375729469c37ccbb46c109ce5e3b93a6e15aa84452900aa8ec7926`)

- No ongoing/recent OOMKills or severe throttling hotspots in core platform namespaces (see inventory evidence). (ids: `dk.ca.finding.v1:resource-contract:86a2188909345c46d381ba32af487159b89af74132461b380c786f3abacc7f5d`)

- Proxmox backport (CPU requests + memory request/limit headroom):. (ids: `dk.ca.finding.v1:resource-contract:d50b8774b76870d64c8d62852c2f4cece93ef1b32713509e4af7e05d3c9498ee`)

- Temporary Tier-1 exemption (observability/alloy-metrics):. (ids: `dk.ca.finding.v1:resource-contract:406cfb1cafeff49fa365dae7ddd2cac00dbf6a58ff1af496cf9871fe156efe8d`)

- VPA recommender tuning (min + rounding):. (ids: `dk.ca.finding.v1:resource-contract:c97dcd07a1c847cd75e7c9603eb296fc784ed8bc0aa04414585525bdf8779e03`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- No ongoing/recent OOMKills or severe throttling hotspots in core platform namespaces (see inventory evidence).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:86a2188909345c46d381ba32af487159b89af74132461b380c786f3abacc7f5d", "last_seen_at": "2026-02-25", "recommendation": "No ongoing/recent OOMKills or severe throttling hotspots in core platform namespaces (see inventory evidence).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "No ongoing/recent OOMKills or severe throttling hotspots in core platform namespaces (see inventory evidence).", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Any remaining CPU limits are either removed (preferred) or intentionally kept with an explicit justification.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:82824abc1570d5a5553bc9d43d32f7dae68d96a0fa03f87581354709334fbc68", "last_seen_at": "2026-02-25", "recommendation": "Any remaining CPU limits are either removed (preferred) or intentionally kept with an explicit justification.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Any remaining CPU limits are either removed (preferred) or intentionally kept with an explicit justification.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- For infrastructure services where we enforce `requests=limits` for memory, decide the policy: target+floor vs per-workload exception (do not blindly apply upper bounds cluster-wide).\n\nTracking / evidence:", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:e6545dc3e844bfb75f82c9d83746ea9f23f4d6856469dfcd53e1bd3e2f1c495e", "last_seen_at": "2026-02-25", "recommendation": "For infrastructure services where we enforce requests=limits for memory, decide the policy: target+floor vs per-workload exception (do not blindly apply upper bounds cluster-wide).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "For infrastructure services where we enforce requests=limits for memory, decide the policy: target+floor vs per-workload exception (do not blindly apply upper bounds cluster-wide).", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Inventory baseline:.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:f2b45e2a88375729469c37ccbb46c109ce5e3b93a6e15aa84452900aa8ec7926", "last_seen_at": "2026-02-25", "links": [], "recommendation": "Inventory baseline:.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Inventory baseline:.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- VPA recommender tuning (min + rounding):.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:c97dcd07a1c847cd75e7c9603eb296fc784ed8bc0aa04414585525bdf8779e03", "last_seen_at": "2026-02-25", "links": [], "recommendation": "VPA recommender tuning (min + rounding):.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "VPA recommender tuning (min + rounding):.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Temporary Tier-1 exemption (observability/alloy-metrics):.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:406cfb1cafeff49fa365dae7ddd2cac00dbf6a58ff1af496cf9871fe156efe8d", "last_seen_at": "2026-02-25", "links": [], "recommendation": "Temporary Tier-1 exemption (observability/alloy-metrics):.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Temporary Tier-1 exemption (observability/alloy-metrics):.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Proxmox backport (CPU requests + memory request/limit headroom):.\n\nBackport plan (after stability window, e.g. 3\u20137 days of representative traffic):", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:d50b8774b76870d64c8d62852c2f4cece93ef1b32713509e4af7e05d3c9498ee", "last_seen_at": "2026-02-25", "links": [], "recommendation": "Proxmox backport (CPU requests + memory request/limit headroom):.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Proxmox backport (CPU requests + memory request/limit headroom):.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Apply **CPU requests** from VPA to infrastructure services and backport into GitOps (use `scripts/toils/vpa-apply-recommendations.py --backport-gitops`).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:3538d6a7b3998260a98296b8b36a9901fbbb85c1b55771ba24e23b6ffb27b65e", "last_seen_at": "2026-02-25", "recommendation": "Apply CPU requests from VPA to infrastructure services and backport into GitOps (use scripts/toils/vpa-apply-recommendations.py --backport-gitops).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Apply CPU requests from VPA to infrastructure services and backport into GitOps (use scripts/toils/vpa-apply-recommendations.py --backport-gitops).", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Apply **memory requests** from VPA to infrastructure services and backport into GitOps.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:2ca136d603a517888a2c9b6c88a77f33540f7cacf3e0f67bcee7cde9b1ca30ee", "last_seen_at": "2026-02-25", "recommendation": "Apply memory requests from VPA to infrastructure services and backport into GitOps.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Apply memory requests from VPA to infrastructure services and backport into GitOps.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- For infrastructure services: set **memory limits = memory requests** (per component policy), but only after verifying no OOMKill regression and ensuring the chosen bound is appropriate.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:0938d9d89ab3fc2e50a7da5b780a8fa72d8fd230f00aa00a7c9b9546002692e2", "last_seen_at": "2026-02-25", "recommendation": "For infrastructure services: set memory limits = memory requests (per component policy), but only after verifying no OOMKill regression and ensuring the chosen bound is appropriate.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "For infrastructure services: set memory limits = memory requests (per component policy), but only after verifying no OOMKill regression and ensuring the chosen bound is appropriate.", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- For apps: do not enforce `requests=limits` by default; only backport if/when needed (explicit per-app decision + evidence).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:5df123ad72780bc9d9bb7c34b04020de9d72fc5d7d29cd806a45342a44849e04", "last_seen_at": "2026-02-25", "recommendation": "For apps: do not enforce requests=limits by default; only backport if/when needed (explicit per-app decision + evidence).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "For apps: do not enforce requests=limits by default; only backport if/when needed (explicit per-app decision + evidence).", "topic": "post-stability-sizing-backport-platform-wide"}
{"class": "actionable", "details": "- Expand `darksite.cloud/resource-contract=strict` beyond observability namespaces (phase-by-phase), keeping each namespace clean before opt-in.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:c93a475b0e6118479e06649d7b72d50414f5ddd6d8aaef83c954121aee409ba3", "last_seen_at": "2026-02-25", "recommendation": "Expand darksite.cloud/resource-contract=strict beyond observability namespaces (phase-by-phase), keeping each namespace clean before opt-in.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Expand darksite.cloud/resource-contract=strict beyond observability namespaces (phase-by-phase), keeping each namespace clean before opt-in.", "topic": "coverage-expansion-platform-namespaces"}
{"class": "actionable", "details": "- Expand CI validation discovery beyond `components/platform/observability/**` when new strict namespaces are introduced elsewhere.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:909a622a146569d9fecb6466e2947511be4abb3a9a420a5fa13a1ab2a1817f55", "last_seen_at": "2026-02-25", "recommendation": "Expand CI validation discovery beyond components/platform/observability/** when new strict namespaces are introduced elsewhere.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Expand CI validation discovery beyond components/platform/observability/** when new strict namespaces are introduced elsewhere.", "topic": "coverage-expansion-platform-namespaces"}
{"class": "actionable", "details": "- Decide tenant enforcement approach (CI-only vs Kyverno validate vs VAP), given tenant LimitRange defaults.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:afa900104789145bb2a009d304eefeb541817b13b4897fba0b1a2936ad0bcb47", "last_seen_at": "2026-02-25", "recommendation": "Decide tenant enforcement approach (CI-only vs Kyverno validate vs VAP), given tenant LimitRange defaults.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide tenant enforcement approach (CI-only vs Kyverno validate vs VAP), given tenant LimitRange defaults.", "topic": "tenant-policy-phase-3"}
{"class": "actionable", "details": "- If enforcing, define the exception mechanism (Kyverno `PolicyException` + expiry).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:165100d390ad4490a5109e0ec7ff7aee3a5c4b4fc72bc2e4554ead4bd0e0a48f", "last_seen_at": "2026-02-25", "recommendation": "If enforcing, define the exception mechanism (Kyverno PolicyException + expiry).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "If enforcing, define the exception mechanism (Kyverno PolicyException + expiry).", "topic": "tenant-policy-phase-3"}
{"class": "actionable", "details": "- Add CI checks for selected CRDs that create Pods (e.g., CNPG `Cluster.spec.resources`) so we don\u2019t rely only on admission/runtime for those.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:resource-contract:6be8ebfead8031e5404d0b84689f9cdbd352e4aa29e048de2b428bcc04514970", "last_seen_at": "2026-02-25", "recommendation": "Add CI checks for selected CRDs that create Pods (e.g., CNPG Cluster.spec.resources) so we don\u2019t rely only on admission/runtime for those.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Add CI checks for selected CRDs that create Pods (e.g., CNPG Cluster.spec.resources) so we don\u2019t rely only on admission/runtime for those.", "topic": "operator-created-pods-crd-aware-validation-phase-2"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

### 2026-01-09 (Runtime detection rules)
- Added Mimir alert rules for strict namespaces:
  - Tier 1: missing required request/limit fields (critical)
-

### 2026-01-05 (Phase 1/2)
- Tier 1 admission enforcement enabled as `Deny` for strict namespaces.
- CI validation added to prevent regressions for observability workloads.
-

### 2026-01-05 (Sizing loop)
- VPA controllers installed + Mimir opted in for request right-sizing (bounded, requests-only).
-

### 2026-01-12 (Coverage expansion)
- Enabled recommendations-only VPA coverage for all long-lived workloads across namespaces via Kyverno generate.
-

### 2026-01-12 (CPU limits default removal)
- Removed CPU limits (`resources.limits.cpu`) as a default across GitOps-managed workloads.
- Dropped the “strict namespaces should set `limits.cpu`” warning-only posture (no Tier 2 enforcement/alerts).
-
