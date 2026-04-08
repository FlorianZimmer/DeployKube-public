# Platform-managed tenant egress proxy (Tier S)

This component provides **platform-managed** HTTP(S) egress for Tier S tenants via a forward proxy.

Goals:
- Tenant namespaces remain **deny-by-default** for internet egress (only DNS is allowed by baseline).
- Tenants get internet egress **only** via a platform-managed proxy, with PR-authored allowlists and auditable logs.
- Egress capacity is **budgeted per org** (resource quotas), so one tenant cannot exhaust cluster egress by default.

## Contract (v1)

- **Proxy type**: HTTP forward proxy + HTTPS CONNECT.
- **Tenant request surface** (platform-owned; PR-reviewed; opt-in):
  - Allowlist intent: `tenancy.darksite.cloud/v1alpha1 TenantProject.spec.egress.httpProxy.allow[]`
    - Absence of `spec.egress.httpProxy` means “no internet egress requested” (no proxy is created for the project).
  - Tenant NetPol allow (workload-plane): a `NetworkPolicy` in the tenant namespace allowing egress to the proxy (`:3128`).
- **Naming**:
  - Org egress namespace: `egress-<orgId>`
  - Project proxy Service: `egress-proxy-p-<projectId>` (port `3128`)
- **Allowlist semantics**: domain allowlist enforced at the proxy (no tenant `ipBlock`/direct egress).

## Reconciliation (controller-owned)

This component is **controller-owned** and reconciled by the tenant provisioner controller from `Tenant`/`TenantProject` CRs.
There is no repo-side “render then commit” workflow.

## Auditing

- Each project has a dedicated proxy Deployment; access logs are therefore naturally scoped to `{orgId, projectId}`:
  - `kubectl -n egress-<orgId> logs deploy/egress-proxy-p-<projectId>`
- For full attribution (source namespace/pod), correlate with Cilium/Hubble flows if needed.

## HA posture

- Proxies run with 2 replicas and a PDB (`minAvailable: 1`) by default.
- Anti-affinity is preferred where possible.

## Security notes

- Tenants cannot reach the proxy unless they explicitly allow it via NetworkPolicy (and guardrails restrict which peers are legal).
- The proxy itself runs in platform-managed namespaces and is not in the tenant trust boundary.
- The rendered Squid config keeps `cache_effective_user` as `root` to avoid privilege-dropping behavior that can fail under `capabilities.drop: ["ALL"]` in Kubernetes.

Guardrails + smoke coverage:
- Tenant `NetworkPolicy` guardrails allow egress to `egress-<orgId>` only for proxy pods with matching `darksite.cloud/project-id`:
  - `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-networkpolicy-guardrails.yaml`
- The baseline smoke suite proves:
  - direct internet egress is denied by default,
  - egress via the proxy succeeds only for allowlisted domains:
  - `platform/gitops/components/shared/policy-kyverno/smoke-tests/base/cronjob-policy-kyverno-smoke-baseline.yaml`
