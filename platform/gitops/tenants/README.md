# Tenants (platform-owned intent)

This folder is the canonical GitOps “tenant intent” surface for DeployKube multitenancy.

## Contract (v1)

Tenant identity is folder-shaped:

```
platform/gitops/tenants/<orgId>/
  metadata.yaml                         # required (tenant lifecycle contract; non-PII)
  README.md                             # optional (contacts/runbook)
  support-sessions/<sessionId>/         # optional (time-bound troubleshooting access)
    metadata.yaml                       # required when folder exists (TTL + reason; non-PII)
    kustomization.yaml                  # required when folder exists (deployable RBAC/policy deltas)
  projects/<projectId>/
    egress/                              # optional (Tier S; platform-managed internet egress)
      allowlist.yaml                     # optional (opt-in request surface; not a Kubernetes object)
    namespaces/<env>/                   # <env> == overlayMode (dev|prod), not deploymentId
      kustomization.yaml
      namespace-*.yaml                  # Namespace objects with required tenant identity labels
```

### `metadata.yaml` (required)

`metadata.yaml` is a DeployKube-internal input (not a Kubernetes object). It records the tenant’s lifecycle contract:
- tier (`S|D`)
- retention mode (`immediate|grace|legal-hold`)
- backup deletion semantics (`retention-only|tenant-scoped|strict-sla`)

See: `docs/design/multitenancy-lifecycle-and-data-deletion.md` and tracker `docs/component-issues/multitenancy-lifecycle-and-data-deletion.md`.

### `support-sessions/` (optional)

Support sessions are the preferred “temporary troubleshooting access” mechanism:
- Git-authored + reviewed (PR), like all access changes.
- Time-bound and **enforced** (CI TTL gate + Git cleanup flow).
- Narrow scope (namespaced RBAC; workload-plane only).
- Git history remains the audit trail after cleanup.

Folder contract:

```
platform/gitops/tenants/<orgId>/support-sessions/<sessionId>/
  metadata.yaml
  kustomization.yaml
  rbac/rolebinding-*.yaml
  # netpol/*.yaml                        # optional
```

Wiring (v1): a session is “active” only if referenced from a project env kustomization:
- `platform/gitops/tenants/<orgId>/projects/<projectId>/namespaces/<env>/kustomization.yaml`

Pre-merge enforcement:
- `./tests/scripts/validate-support-sessions.sh` (TTL + schema + renderability)

Expiry cleanup (Git-driven):
- `./scripts/toils/support-sessions/cleanup-expired.sh`

### `<env>` placeholder meaning (non-negotiable)

Any folder placeholder named `<env>` refers to **`overlayMode`**:
- `dev`
- `prod`

It does **not** refer to `deploymentId` (e.g. `mac-orbstack`, `proxmox-talos`).

## Safety rails

- Do not commit secrets anywhere under `platform/gitops/tenants/**`.
- Keep identifiers DNS-label-safe:
  - `orgId` and `projectId` must match `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` and be <= 63 chars.
- Validate before seeding:
  - `./tests/scripts/validate-tenant-folder-contract.sh`
  - `./tests/scripts/validate-tenant-intent-applications.sh`
  - `./tests/scripts/validate-tenant-intent-surface.sh`

## Ingress (Tier S default)

Tenant ingress is **platform-managed**:
- Tenants do **not** create `Gateway` resources.
- Tenants publish `HTTPRoute` objects from their tenant namespaces and must attach only to `Gateway/istio-system/tenant-<orgId>-gateway` (listener `http`/`https`).
- Tenant hostnames must live under the tenant workloads DNS space:
  - `<app>.<orgId>.workloads.<baseDomain>` (e.g. `api.smoke.workloads.dev.internal.example.com`)
- TLS is **platform-managed** in v1 via a wildcard certificate per org:
  - `Certificate/istio-system/tenant-<orgId>-workloads-wildcard-tls`

Enforcement:
- `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-ingress-gateway-api-guardrails.yaml`
- Design: `docs/design/multitenancy-networking.md#dk-mtn-ingress`

## Egress (Tier S default)

Tenant internet egress is **platform-managed**:
- Direct internet egress is denied by default (baseline).
- Tenants get internet egress only via a platform-managed forward proxy, with PR-authored allowlists and auditable logs.

Contract (v1):
- Allowlist intent (platform-owned; Kubernetes object):
  - `tenancy.darksite.cloud/v1alpha1 TenantProject.spec.egress.httpProxy.allow[]`
  - Absence of `spec.egress.httpProxy` means “no internet egress requested” (no proxy is created for the project).
- Tenant workload-plane authoring:
  - a `NetworkPolicy` in the tenant namespace allowing egress to the proxy (`egress-proxy-p-<projectId>.egress-<orgId>.svc.cluster.local:3128`).

Enforcement + implementation:
- Design: `docs/design/multitenancy-networking.md#dk-mtn-egress`
- Component: `platform/gitops/components/networking/egress-proxy`
- Controller: tenant provisioner (`platform/gitops/components/platform/tenant-provisioner`)

## Storage: tenant-facing S3 (optional primitive; M6)

Tenant-facing S3 is an **opt-in** primitive intended for Tier S tenants that need object storage directly.

Contract summary:
- tenants receive S3 credentials via a **platform-owned** Kubernetes `Secret` (projected from Vault),
- tenants do **not** create buckets/keys directly (provisioning is platform-owned + Git-triggered),
- Garage S3 reachability is **explicitly allowlisted** per tenant identity (no broad allow),
- Garage admin/RPC endpoints are never reachable from tenant namespaces.

### Git intent + projection (v1 repo surfaces)

For a bucket `<bucketName>` (example: `app`), the platform-owned tenant intent bundle typically includes:

- **Bucket intent**: a `ConfigMap` in the `garage` namespace with label `darksite.cloud/tenant-s3-intent=true` and `data.intent.json` containing `{orgId,bucketName}`.
  - Example (smoke): `platform/gitops/tenants/smoke/projects/demo/namespaces/prod/configmap-garage-tenant-s3-intent-app.yaml`
- **Tenant egress allow**: `NetworkPolicy` in the tenant namespace allowing egress only to `garage:3900`.
  - Example (smoke): `platform/gitops/tenants/smoke/projects/demo/namespaces/prod/networkpolicy-allow-garage-s3-egress.yaml`
- **Tenant Secret projection**: `ExternalSecret` in the tenant namespace that projects Vault `tenants/<orgId>/s3/<bucketName>` into a Kubernetes `Secret` (e.g. `Secret/tenant-s3-app`).
  - Example (smoke): `platform/gitops/tenants/smoke/projects/demo/namespaces/prod/externalsecret-tenant-s3-app.yaml`

Platform-owned allowlisting is required on the Garage side:
- Garage ingress allowlist: `platform/gitops/components/storage/garage/base/networkpolicy.yaml` (add a tenant identity `namespaceSelector` for each allowed tenant/project).

Runbook: `docs/toils/tenant-s3-primitive.md`.
