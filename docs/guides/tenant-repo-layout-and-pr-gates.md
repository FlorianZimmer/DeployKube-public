# Tenant repo layout + PR validation gates (product mode)

This guide defines the **standard tenant workload repo layout** and the **required static PR gates** for repo-per-project (“product mode”) tenants.

Goals:
- predictable “happy path” for tenant delivery
- consistent enforcement surface before Argo sync
- fast feedback (static checks) without cluster access

## Tenant repo layout (Kustomize)

Tenant repos follow the same base/overlay layout contract as platform components:

```
base/
  kustomization.yaml
  *.yaml
overlays/
  mac-orbstack/
    kustomization.yaml
  mac-orbstack-single/
    kustomization.yaml
  proxmox-talos/
    kustomization.yaml
```

Notes:
- `base/` contains shared manifests (workloads, Services, NetworkPolicies, HTTPRoutes, PVCs, etc.).
- each `overlays/<deploymentId>/` references `../../base` and applies only deployment-specific deltas.
- supported `deploymentId`s are the DeployKube allowlist (no `dev`/`prod` overlays).

## Required static PR gates

These gates are required for any tenant repo that Argo can reconcile:

1. **Renderability**: `kustomize build` succeeds for every overlay.
2. **Prohibited kinds**: deny cluster-scoped and access-plane resources (RBAC, admission, Argo primitives, ESO, etc.).
3. **Namespace boundary**: forbid explicit namespace targeting outside `t-<orgId>-p-<projectId>-*`.
4. **Policy-aware lint**: fail early on known constraints (e.g., NetworkPolicy `ipBlock`, Service types, HTTPRoute parentRefs must target the tenant gateway).
5. **Secret scanning**: credentials must not be committed to Git (gitleaks-like).

Certificate/TLS contract:
- Tenant repos must not author `cert-manager.io` or `acme.cert-manager.io` resources.
- Public tenant endpoint TLS is platform-owned and reconciled from tenant intent; tenants attach `HTTPRoute`s to the tenant gateway and the platform supplies the certificate.

### Common NetworkPolicy pattern: allow tenant-gateway ingress

Tenant namespaces are default-deny. If you expose a Service through the **tenant Gateway API gateway**, add an explicit ingress allow for the gateway pods:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-tenant-gateway
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: your-app
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              gateway.networking.k8s.io/gateway-name: tenant-<orgId>-gateway
      ports:
        - protocol: TCP
          port: 8080
```

## Reference implementation (scripts)

DeployKube ships reusable scripts under:
- `shared/scripts/tenant/`
- `shared/contracts/tenant-prohibited-kinds.yaml`

The standard entrypoint is:

```bash./shared/scripts/tenant/run-tenant-pr-gates.sh \
  --org-id <orgId> \
  --project-id <projectId> \
  --repo-root.
```

These scripts are designed to be vendored into tenant repos (or consumed via a sub-tree copy) and executed in CI.

### CI integration (required)

Tenant repos must run the gate suite as a **required PR check**.

DeployKube ships a ready-to-copy workflow template:
- `shared/templates/tenant-repo/.forgejo/workflows/tenant-pr-gates.yaml`
- `shared/templates/tenant-repo/.github/workflows/tenant-pr-gates.yaml`

The workflow publishes a stable status check name: `tenant-pr-gates`.

In Forgejo product mode, DeployKube enforces this via protected branches:
- `rbac-system/CronJob/forgejo-tenant-pr-gate-enforcer` converges branch protection for `tenant-<orgId>/apps-<projectId>` repos from the tenant registry.
