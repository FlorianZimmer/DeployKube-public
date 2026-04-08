# Idea: EU Market Analysis & Go-To-Market (Sovereign Private Cloud-in-a-Box)

Date: 2025-12-26
Status: Draft

## Problem statement

We want to productize DeployKube into a sellable **EU-targeted private cloud offering** for environments where public cloud is not acceptable (regulation, sovereignty, “paranoia”), while remaining GitOps-first and operationally repeatable.

Constraints from the vision:
- Deployment can be **small** (single tenant, single zone, few servers) yet must not block scaling up to multi-tenant/multi-customer and three-zone architectures.
- Hardware bundling is **optional** (software-only or appliance bundle).
- SLA target is **99%** long-term; initial commercial posture can start at **95%** while hardening and operational maturity land.

This document is intentionally **not a design doc**. It is an “ideas” market view used to guide product sequencing and differentiation.

Related vision docs:
- Roadmap (repo-grounded): `docs/design/cloud-productization-roadmap.md`
- Private cloud-in-a-box vision: `docs/ideas/2025-12-25-managed-private-cloud-multitenant-hardware.md`
- Three-zone anycast+BGP: `docs/ideas/2025-12-25-multi-zone-anycast-bgp.md`
- Single-YAML provisioning: `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`
- 4-eyes access + breakglass: `docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`
- Marketplace (managed services vs curated deployments): `docs/ideas/2025-12-26-marketplace-managed-services.md`
- KRM-first Cloud UI: `docs/ideas/2025-12-25-krm-gitops-cloud-ui.md`

## Executive summary

The competitive field in the EU spans:
- sovereign cloud providers (hosted), and
- enterprise on-prem stacks (Kubernetes platforms, IaaS stacks, and hyperscaler-on-prem appliances).

DeployKube can differentiate if it becomes:
- **Kubernetes/GitOps-first**, audit-friendly, and operator-simple,
- capable of **very small deployments** (a wedge many private cloud products ignore),
- with clear tiers up to **hard isolation** (dedicated hardware) and true **three-zone** designs,
- with a **clean self-service contract** (single YAML / KRM) that later supports a UI and a marketplace.

The biggest risk is not “features”: it is **operational clarity** (responsibilities, SLO/SLA boundaries, upgrades, backups, breakglass), and a credible **supply-chain/offline** story for regulated deployments.

## Competitive landscape (high-level)

This is a representative map (not exhaustive).

### 1) Open-source private cloud stacks (IaaS-first)

Examples: OpenStack and similar.

Typical strengths:
- mature VM/network/storage primitives for private clouds
- large ecosystem and long history

Typical weaknesses (for our target wedge):
- broad and complex surface area; high operational burden
- often VM-first vs Kubernetes-first
- self-service often focuses on IaaS primitives rather than “secure platform + managed services” with GitOps governance

### 2) Enterprise Kubernetes platforms

Examples: OpenShift, Rancher-based stacks, VMware Tanzu/VCF-adjacent “Kubernetes on enterprise infra”.

Typical strengths:
- strong enterprise support story and ecosystem
- mature day-2 operational tooling

Typical weaknesses (for our target wedge):
- expensive and heavy for “small installs”
- opinionated; can be hard to make “sovereign/air-gapped” and “audit-by-GitOps” the default product story
- physical tenant isolation and “three-zone anycast+BGP” are not normally shipped as a cohesive product contract

### 3) Hyperscaler on-prem offerings (appliance model)

Examples: AWS/Azure/GCP on-prem appliances.

Typical strengths:
- strong product maturity and support organizations
- familiar UX for teams already using hyperscalers

Typical weaknesses (for our target wedge):
- perceived or real lock-in; identity/operations often align to the vendor ecosystem
- cost and procurement complexity
- air-gapped and long-term disconnected operations can be difficult or have constraints

### 4) EU “sovereign cloud” providers (hosted)

Examples: EU providers offering hosted sovereign cloud services.

Typical strengths:
- “sovereign hosting” positioning and managed operations

Typical weaknesses (for our target wedge):
- does not solve the cases that require **customer-premises deployment** (strict on-prem, disconnected, “no shared provider DC”)

## Differentiation: what can make DeployKube defensibly different

### Differentiators we can credibly build (and measure)

1) **Small-install-first without sacrificing the end-state**
- “Doctor’s office” installs that follow the same contracts as “defense” installs.
- The differentiator is not “runs on small hardware” but “is operable, secure, and upgradable with low toil”.

2) **Audit-by-default operations**
- GitOps-first reconciliation, evidence discipline, and PR-based approvals.
- KRM-first UI later that authors Git/CRs and surfaces reconciliation (not direct mutations).

3) **Hard multitenancy with optional physical isolation**
- Dedicated physical servers per tenant/customer in regulated tiers (explicit side-channel posture).
- Tenants can run multiple of their own workload clusters for internal separation.

4) **Three-zone posture as a real product contract**
- Explicit constraints and drills: not “marketing multi-zone”, but “three-zone reference architecture + anycast/BGP + storage/quorum story + drills”.

5) **Marketplace split: curated deployments vs fully managed services**
- Clear responsibilities per service class (avoids “we installed it so we own it” confusion).

### Differentiators we cannot claim until implemented

- “True multi-zone resilience” without multi-zone storage and repeated drills.
- “Enterprise-grade multi-tenant self-service” without a policy engine, RBAC governance, and a provable access model.
- “Fully managed services” without on-call, upgrade pipelines, backup/restore tests, and clear SLOs.

## SLA posture (95% now, 99% target) and what it implies

Define SLAs precisely (otherwise they become legal and operational traps):
- **95% availability** allows ~18.25 days of downtime/year (averaged).
- **99% availability** allows ~3.65 days of downtime/year.

To sell 99% credibly, we need:
- clear scope: “control plane/API”, “ingress reachability”, “managed service endpoints”, etc.
- monitoring + alerting + on-call process (and evidence of drills)
- redundancy inside the promised failure domain (single-zone HA vs three-zone HA)

Practical productization approach:
- Start with **95%** for early small installs (single-zone, HA on node/switch level) while we harden access/policy/provisioning and reduce toil.
- Move to **99%** once:
  - access and change control are enforceable (four-eyes),
  - upgrades are repeatable,
  - backups/restores are tested,
  - incident response workflows are real (even if business-hours for initial tiers).

## Packaging and pricing model (EU-targeted)

Hardware bundling is optional, so we need a pricing model that works in both modes.

Suggested packaging to reduce complexity:

### 1) Software subscription (customer supplies hardware)

Base price axis:
- per physical server (or per “node pack”), plus support tier.

Add-ons:
- managed services packs (DBaaS/S3/Redis) with explicit SLO scope
- “regulated tier” controls (dedicated hardware enforcement, stricter policies, audit options)
- multi-cluster management (when implemented)

### 2) Appliance bundle (hardware included)

Commercial options:
- outright purchase + annual software/support
- lease/financing + multi-year contract

Benefit:
- simplifies procurement and reduces “works on my hardware” variability (important for small customers).

## Revenue model (EU niche) — scenario ranges (high uncertainty)

Because the niche is heterogeneous, estimate revenue bottom-up by segment and ACV.

### Segment ACV bands (software + support; excludes hardware resale and one-time PS)

These are *planning* bands, not commitments:
- **Micro regulated** (3–8 servers, single zone, single tenant): **€15k–€60k / year**
- **SMB/Regional** (10–40 servers, 1–5 tenants or multi-cluster per tenant): **€80k–€300k / year**
- **Enterprise/Defense/Critical infra** (50–300+ servers, many tenants, audits): **€300k–€2M+ / year**

One-time services (typical for on-prem):
- install + migration + training + security review: often **20%–100% of year-1 subscription**, depending on scope and air-gap requirements.

### 5-year SOM (Serviceable Obtainable Market) scenarios

Let:
- `M` = number of micro customers
- `S` = number of SMB customers
- `E` = number of enterprise customers
- `ACV` bands chosen per segment

Example midpoint ACVs for modeling:
- micro €30k, SMB €200k, enterprise €1.0M

Scenarios (illustrative):

1) **Conservative**
- Year 5: M=20, S=5, E=1
- ARR (midpoint): ~€2.6M

2) **Base case**
- Year 5: M=100, S=20, E=5
- ARR (midpoint): ~€12M

3) **Upside**
- Year 5: M=300, S=60, E=15
- ARR (midpoint): ~€36M

What drives the range:
- support scope (business-hours vs 24/7)
- managed services adoption (higher ACV)
- hardware bundling margin (optional upside, but operationally heavier)
- sales cycle length (enterprise is slow; micro can be faster via channel)

## Go-to-market sequencing (aligned to technical roadmap)

This should track the repo-grounded implementation order in `docs/design/cloud-productization-roadmap.md`.

Recommended wedge:
1) **Micro regulated** (single-zone, single tenant) with strong auditability and low toil.
2) Expand to **SMB** with multi-cluster per tenant and clearer managed services.
3) Expand to **multi-customer hosted** with hard isolation.
4) Only then sell “true three-zone” as a premium SKU once storage/quorum and drills exist.

Channel strategy (likely required for micro scale):
- MSPs / regional system integrators who already sell into medical/legal/industrial customers.

## Open questions (to turn this into a real business plan)

- What countries are in-scope first (Germany, Austria, Switzerland, Nordics, etc.) and what compliance expectations dominate?
- What support posture is realistic at each tier (business hours vs 24/7), and what does that imply for staffing?
- What is the first “must-have” managed service (DBaaS vs object storage vs identity)?
- Do we aim for formal certifications (e.g., ISO 27001) early, or treat them as an enterprise-phase milestone?

## Promotion criteria (to a more formal plan)

Promote this doc into an executable go-to-market plan once we have:
- A defined SKU matrix (single-zone 95%, single-zone 99%, three-zone 99%+, managed services add-ons).
- A pricing model and a partner/channel hypothesis.
- A reference BOM for small/medium/large installs and a documented upgrade policy.
- A draft support model and staffing plan consistent with the SLA target.

