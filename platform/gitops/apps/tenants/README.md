# Tenant registry (platform-owned)

This folder is the **platform-owned tenant registry** for DeployKube multitenancy.

It is the Git-managed source of truth for tenant **access-plane state**, including:

1) Tenant **Argo CD access-plane objects**:
- `AppProject` objects that define tenant boundaries (repos, destinations, allowed kinds)
- tenant root `Application` objects (one per tenant project recommended) that point Argo at the tenant repo

2) Tenant registry inputs consumed by platform automation:
- Keycloak groups (human auth inputs)
- Vault tenant policies + group-alias mapping (human authZ inputs)
- Tier S ingress: per-org tenant Gateways reconciled by the tenant provisioner controller (platform-managed attach points)

Tenants do **not** edit this registry in v1. Tenant-delivered workloads live in tenant repos and are reconciled by the tenant root `Application`.

## Related: tenant intent surface (platform-owned)

DeployKube also standardizes a canonical “tenant intent” folder contract under:
- `platform/gitops/tenants/<orgId>/...`

This is where platform operators declare:
- required tenant lifecycle metadata (`metadata.yaml`)
- per-project namespace intent per `overlayMode` (`dev|prod`)

The registry (`base/tenant-registry.yaml`) remains the canonical **org/project index** consumed by platform automation (Keycloak/Vault) and is validated for coherence against the tenant intent folders and tenant intent `Application` objects.

## Layout

- `base/`: deployable tenant registry manifests (and tenant registry data inputs)
- `_templates/`: copy/paste templates (disabled by default)

## Wiring

Environment bundles include the tenant registry via:
- `platform/gitops/apps/environments/*/kustomization.yaml`

Current rule:
- Active env bundles include `../../tenants/overlays/<overlayMode>` so tenant intent `Application`s can select `dev|prod` paths.
- Staging (placeholder) includes `../../tenants/base` only.

## Argo projects (v1)

Tenant-related Argo CD objects are split into two project types:

1) **Tenant intent (platform-owned; monorepo fallback)**
- `AppProject`: `tenant-intent-<orgId>-p-<projectId>`
- `Application`: `tenant-intent-<orgId>-<projectId>` (one per project; lives under `overlays/{dev,prod}`)
- Source repo: `platform/cluster-config.git` (this repo’s `platform/gitops/` mirror)
- Allowed surface is intentionally narrow: `Namespace` + a small namespaced allowlist (see `base/appproject-tenant-intent-*.yaml`)

2) **Tenant workloads (repo-per-project; product mode)**
- `AppProject` (org): `tenant-<orgId>`
- `AppProject` (project): `tenant-<orgId>-p-<projectId>`
- Source repo: `tenant-<orgId>/apps-<projectId>.git`
- Deny-by-default for cluster-scoped and access-plane resources (see templates under `_templates/`)
- Argo UI access is tenant-scoped and expressed via `AppProject.spec.roles[].groups` (no per-tenant edits to `argocd-rbac-cm`).
- Tenant repos must run the tenant PR gate suite as a required PR check (see `docs/guides/tenant-repo-layout-and-pr-gates.md`).

## Tenant registry data (v1)

- Git source of truth: `platform/gitops/apps/tenants/base/tenant-registry.yaml`
- In-cluster distribution (for consumers which run inside the cluster):
  - `ConfigMap/keycloak/deploykube-tenant-registry`
  - `ConfigMap/vault-system/deploykube-tenant-registry`
  - `ConfigMap/garage/deploykube-tenant-registry`
  - `ConfigMap/backup-system/deploykube-tenant-registry`

## Tier S ingress wiring (tenant gateway pattern)

Tier S multitenancy uses **platform-managed** per-org tenant Gateways as the default ingress attach point:
- `Gateway/istio-system/tenant-<orgId>-gateway`
- `allowedRoutes.namespaces.from: Selector` keyed by `darksite.cloud/tenant-id=<orgId>`
- Listener hostnames are tenant-scoped: `*.<orgId>.workloads.<baseDomain>` (TLS terminated via wildcard cert).

Provisioning model (transition):
- Source of truth (Gateways): `tenancy.darksite.cloud/v1alpha1 Tenant` (platform-authored; reconciled by tenant provisioner)
- Source of truth (wildcard certs): `tenancy.darksite.cloud/v1alpha1 Tenant` (controller-owned `Certificate/istio-system/tenant-<orgId>-workloads-wildcard-tls`)
- Source of truth (tenant wildcard DNS): `tenancy.darksite.cloud/v1alpha1 Tenant` (auto-discovered by `dns/external-sync`; no per-tenant overlay rendering)
- Admission enforcement: tenant `HTTPRoute` parentRefs are restricted to the tenant gateway (see `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-ingress-gateway-api-guardrails.yaml`).

Future direction:
- Replace the wildcard cert/DNS model with controller-owned **exact-host** records and certificates.
- Keep the ownership boundary unchanged: tenants publish `HTTPRoute`s and higher-level intent, while platform controllers reconcile the DNS and cert-manager resources.

Workflow when onboarding a new org:
1. Add the tenant API manifest (multi-doc YAML): `platform/gitops/apps/tenant-api/base/tenant-<orgId>-darksite.yaml`.
2. Add the org to `platform/gitops/apps/tenants/base/tenant-registry.yaml` (legacy consumers: Keycloak/Vault/etc.).
3. (Optional) If enabling tenant internet egress for a project, set the allowlist intent on the project:
   - `tenancy.darksite.cloud/v1alpha1 TenantProject.spec.egress.httpProxy.allow[]`
4. Validate:
   - `./tests/scripts/validate-istio-gateway.sh`
   - `./tests/scripts/validate-certificates-ingress-controller-cutover.sh`
   - `./tests/scripts/validate-dns-wiring-controller-cutover.sh`
