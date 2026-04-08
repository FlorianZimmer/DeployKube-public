# Idea: Infrastructure Rate Limiting and DDoS Resilience (External + Hostile Tenants)

Date: 2026-01-16  
Status: Draft

## Problem statement

DeployKube exposes:
- platform endpoints (Keycloak, Argo CD, Forgejo, Vault, Grafana, etc.), and
- tenant workloads,
through shared ingress infrastructure (Istio + Gateway API).

Today, there is no systematic, GitOps-owned **rate limiting / connection limiting** layer at the edge. This is a gap for:
- brute-force protection on authentication endpoints,
- resilience when a tenant workload is under attack (shared gateway contention),
- and “hostile tenant” scenarios (noisy neighbor attempts to exhaust shared infrastructure).

Goal: define a defense-in-depth rate limiting and DDoS-resilience posture that:
- works for self-hosted environments (no cloud DDoS service assumed),
- is GitOps-first (auditable, reviewable, reversible),
- and has a clear separation between “tenant budgets” and “platform/edge safety rails”.

## Why now / drivers

- Keycloak explicitly calls out missing Gateway-level rate limiting on authentication endpoints (`platform/gitops/components/platform/keycloak/README.md`).
- Multitenancy plans include hostile/noisy tenant scenarios; edge protections and control-plane protections are prerequisites before scaling tenant onboarding.
- Several subsystems already have “native” limit knobs (observability ingestion/query limits), but there is no consistent edge enforcement story and no shared runbook.

## Proposed approach (high-level)

### Layer 0 — Upstream network / perimeter (out-of-cluster)

Assume a real volumetric DDoS can saturate the WAN link before in-cluster controls help. Document an operator posture (deployment-specific, but contractually required):
- upstream firewall/router protections (SYN flood handling, conntrack tuning, basic rate limiting),
- optional scrubbing/CDN/WAF in front of public endpoints (when acceptable),
- optional BGP RTBH / emergency “drop public traffic” mode for severe events.

This layer is operational rather than purely Kubernetes, but it must be documented because it dominates worst-case outcomes.

### Layer 1 — Cluster edge (Istio ingress gateway)

Implement GitOps-owned controls at the Istio gateway:
- per-hostname/per-route rate limits for platform endpoints (especially auth flows),
- per-tenant budgets so one tenant under attack does not starve the shared gateway,
- connection limits + request concurrency limits,
- request size limits + sane timeouts (slowloris / oversized bodies defense).

Implementation candidates in Istio/Envoy:
- `local_ratelimit` (token bucket per gateway pod; simple, but not globally consistent across replicas)
- global/distributed HTTP rate limiting with an in-cluster rate limit service
- circuit breakers + outlier detection to prevent cascading failures when backends degrade

### Layer 2 — Internal shared infrastructure planes

Protect shared internal planes that tenants can reach by design:

- **DNS**
  - CoreDNS rate limiting and/or max concurrency per client
  - optionally NodeLocalDNS to reduce central pressure

- **Kubernetes API server**
  - API Priority & Fairness (APF) for tenant user groups to cap blast radius from noisy neighbors
  - request-size and watch protections where feasible

- **Shared egress gateway/proxy (future)**
  - per-tenant concurrency/rate limits and optional bandwidth budgets
  - explicit allowlists and authentication (so the proxy becomes a controlled choke point)

### Layer 3 — Backend-native rate limits (last-line safety)

Use backend-native limits as a last line of defense:
- Loki/Mimir/Tempo per-tenant ingestion/query limits (noisy neighbor control)
- Keycloak brute-force protections (realm-level) plus gateway-level enforcement
- Forgejo/Argo/Grafana throttles where supported

### Visibility + operability

Make edge protections observable and operable:
- dashboards for 429/503 rates, gateway saturation, and (if used) rate-limit-service health/latency
- alerts for “edge is rate limiting” and “attack mode”
- a documented workflow to raise/lower limits via Git PRs with evidence

## What is already implemented (repo reality)

- Istio + Gateway API is the ingress path for platform services and workloads (`target-stack.md`).
- Tenant gateways exist (`Gateway/istio-system/tenant-<orgId>-gateway`) and restrict route attachments via labels (`docs/design/multitenancy-networking.md`).
- Tenant namespaces are default-deny for egress except DNS and same-namespace, reducing some hostile-tenant attack surfaces (`docs/design/policy-engine-and-baseline-constraints.md`).
- Gaps are documented: Keycloak has “No rate limiting” at the gateway layer (`platform/gitops/components/platform/keycloak/README.md`).

## What is missing / required to make this real

- Define the required “edge protection contract”:
  - which endpoints must be protected,
  - baseline limit defaults,
  - and an exception workflow.
- Decide local vs global rate limiting strategy at the Istio gateway (and whether global state on the request path is acceptable).
- Implement a first thin slice:
  - rate limiting for Keycloak auth/token endpoints,
  - basic connection limits on the public gateway,
  - dashboards/alerts for edge saturation,
  - smoke tests proving deterministic 429 behavior (and that normal login still works).
- Extend to tenant gateways with per-tenant budgets tied to tenant identity and/or quota profiles (related idea: `docs/ideas/2026-01-16-tenant-quota-profiles.md`).
- Add APF configuration for tenant user groups once tenant kube access is introduced at scale.

## Risks / weaknesses

- False positives: overly aggressive limits can lock out legitimate users or automation.
- Complexity: distributed rate limiting introduces a new critical dependency on the request path.
- Layer mismatch: volumetric DDoS may overwhelm the network before in-cluster limits help; requires honest operational runbooks.
- Bypass risk: internal traffic paths may bypass edge limits unless explicitly addressed.

## Alternatives considered

- Dedicated external edge proxy/WAF (Envoy/HAProxy/Nginx) in front of the cluster:
  - stronger separation and can absorb more, but adds another HA system to operate.
- CDN/WAF provider in front of public endpoints:
  - best for internet exposure, but may not be acceptable in offline/regulated environments.
- Rely on backend protections only:
  - insufficient; shared gateways and control plane remain vulnerable.

## Open questions

- Which DeployKube installations are truly internet-exposed vs “private only”? Do we need two rate-limit profiles?
- What is the identity key for per-tenant limits at the edge (hostname, SNI, gateway name, or labels)?
- How do we handle bursty-but-legitimate behaviors (login flows, Git clones) without making limits too loose?
- What is the breakglass flow for raising limits during incidents (and how is evidence captured)?

## Promotion criteria (to `docs/design/**`)

Promote once:
- The desired protection layers and baseline limits are specified (including what is deployment-specific).
- A working Istio gateway rate limiting prototype exists for at least one critical endpoint (Keycloak auth), with monitoring and a runbook.
- The tenant “fair share” story at the edge is defined and linked to tenant identity/quota profiles.

