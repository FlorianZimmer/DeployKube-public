# Ideas Docs

Purpose: capture **pre-implementation** ideas that are promising but not yet ready to become an executable design and GitOps change.

An ideas-doc is intentionally lighter-weight than `docs/design/**`:
- It can contain uncertainty, open questions, and competing approaches.
- It must still be **grounded**: clearly state assumptions, constraints, and what is already implemented vs. missing.
- It is not a backlog. Track actionable work items either by promoting the idea to a design doc or by creating component issues once scope is concrete.

## When to write an ideas-doc

Write an ideas-doc when an idea:
- affects multiple components, workflows, or environments (dev/prod/air-gapped), and
- needs structured thinking (risks, requirements, trade-offs) before implementation.

## Naming & location

- Location: `docs/ideas/`
- Filename: `YYYY-MM-DD-<slug>.md`
- Title: `Idea: <short name>`

## Promotion path

An ideas-doc should end with **promotion criteria**:
- What must be true for this idea to be promoted to `docs/design/**`?
- What evidence/prototype is required?
- Which repository changes would be expected (high-level)?

When promoted:
- Create a design doc in `docs/design/**`.
- Link back to the original ideas-doc.
- Close or archive the ideas-doc by setting its status to `Promoted` and referencing the design doc path.

## Suggested template

Copy/paste and fill:

```md
# Idea: <Title>

Date: YYYY-MM-DD
Status: Draft | Parked | Active Exploration | Promoted
Owner: <optional>

## Problem statement

## Why now / drivers

## Proposed approach (high-level)

## What is already implemented (repo reality)

## What is missing / required to make this real

## Risks / weaknesses

## Alternatives considered

## Open questions

## Promotion criteria (to `docs/design/**`)
```

## Current ideas (index)

- Private cloud-in-a-box + multi-tenant/multi-customer + hardware lifecycle: `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
- Three-zone + anycast/BGP “regional” resilience: `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`
- Declarative provisioning from a single YAML (deployment + tenant): `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`
- Cluster access model (four-eyes RBAC, GitOps escalation, breakglass): `docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`
- Marketplace (fully managed services vs curated deployments): `docs/ideas/2025-12-26-marketplace-managed-services.md`
- EU market analysis & go-to-market (Sovereign private cloud): `docs/ideas/2025-12-26-eu-market-analysis-go-to-market.md`
- KRM-first Cloud UI that authors GitOps CRs: `docs/ideas/2025-12-25-krm-gitops-cloud-ui.md`
- LLM as a Service (LLMaaS) marketplace addon: `docs/ideas/2025-12-30-llm-as-a-service-marketplace-addon.md`
- llm-d + Higress inference gateway layering: `docs/ideas/2026-03-26-llm-d-higress-inference-gateway-layering.md`
- Curated package ingress to Harbor (scan + approval gate): `docs/ideas/2026-01-07-curated-package-ingress-to-harbor.md`
- Vault/ESO secret plane re-architecture (OpenBao + better root of trust): `docs/ideas/2026-01-08-vault-secret-plane-rearchitecture.md`
- Privileged Access Management (PAM) for JIT + audited privileged operations: `docs/ideas/2026-01-14-privileged-access-manager-jit.md`
- Tenant quota profiles (resources + rate limits): `docs/ideas/2026-01-16-tenant-quota-profiles.md`
- Infrastructure rate limiting and DDoS resilience (external + hostile tenants): `docs/ideas/2026-01-16-infrastructure-rate-limiting-and-ddos-resilience.md`
- Crypto agility control plane (algorithms, key lengths, TLS posture): `docs/ideas/2026-03-09-crypto-agility-control-plane.md`
- Release upgrade support policy (supported upgrade paths, proof, rollback classes): `docs/ideas/2026-03-14-release-upgrade-support-policy.md`
