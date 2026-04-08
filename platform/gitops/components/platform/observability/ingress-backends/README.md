# Observability Ingress (Backend APIs) — stubs (disabled by default)

This component provides **disabled-by-default** stubs for exposing Loki/Tempo/Mimir read APIs via Gateway API + Istio `AuthorizationPolicy`.

Why stubs exist:
- Some operator workflows benefit from direct API access (curl/promtool/amtool) without going through Grafana.
- These APIs are high-risk to expose incorrectly (tenant boundary and auth). Keeping the stubs in-repo makes later enablement explicit and reviewable.

## Current security reality (important)

Today, backend APIs (Loki/Tempo/Mimir) are treated as **mesh-internal** and rely primarily on:
- namespace default-deny `NetworkPolicy` boundaries, and
- per-tenant `X-Scope-OrgID` headers for multi-tenancy.

There is **no hardened external auth** story for these APIs in v1 (JWT validation + claim→tenant mapping) shipped by default.

## How this is intended to be used (future)

1. Decide the API hostnames and Gateway listener names per deployment.
2. Render deployment overlays (similar to Grafana ingress) to set `hostnames` and `parentRefs.sectionName`.
3. Add/enable JWT validation + tenant mapping at the gateway before enabling these routes for real users.

Until the above is complete, keep this component **not referenced** by `platform-apps` (opt-in only).

