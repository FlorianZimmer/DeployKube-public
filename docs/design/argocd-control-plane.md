# Argo CD Control Plane Design

Status: Design + implementation

## Tracking

- Canonical tracker: `docs/component-issues/argocd.md`
- Related docs:
  - `docs/design/gitops-operating-model.md`
  - `docs/design/cluster-access-contract.md`
  - `docs/design/multitenancy-gitops-and-argo.md`

## Purpose

Define Argo CD's role as the GitOps reconciler for DeployKube, its trust boundaries, and the operational contracts that must remain stable across environments.

## Scope

In scope:
- Argo CD app-of-apps topology and project boundaries.
- Runtime trust model (repo source, auth, and admission constraints).
- Reconciliation and breakglass operations model.

Out of scope:
- Tenant-specific Argo productization details (tracked in `multitenancy-gitops-and-argo.md`).
- Forgejo internals (tracked in `forgejo-gitops-mirror.md`).

## Architecture

1. Root app:
- `Application/platform-apps` in namespace `argocd` is the single root for platform reconciliation.

2. Source of truth:
- Argo reads from the Forgejo mirror (`platform/cluster-config`).
- Mirror seeding is a privileged operation; day-2 posture is still GitOps-first with evidence.
- In-cluster Git transport is HTTPS via `forgejo-https.forgejo.svc.cluster.local`.
- Argo trust for Forgejo TLS is anchored via `ConfigMap/argocd-tls-certs-cm`.

3. Project boundary:
- Platform applications must run under `AppProject/platform`.
- `AppProject/default` remains deny-by-default to prevent accidental broad apply scope.

4. Ordering model:
- Sync-wave ordering is used for deterministic bootstrap and dependencies.
- CRD-before-CR ordering remains mandatory for custom APIs.

5. Application generation model:
- `PlatformApps` (`platform.darksite.cloud/v1alpha1`) is reconciled by `platform-apps-controller`.
- Controller-owned Argo `Application` objects are derived from `PlatformApps.spec` (not hand-edited per-app manifests in env overlays).

## Implemented contracts (runtime)

1. Stage 1 bootstrap contract:
- Stage 1 installs Forgejo and creates internal TLS material (`Secret/forgejo-repo-tls`) and TLS endpoint (`Service/forgejo-https`).
- Stage 1 installs Argo, writes Forgejo CA into `argocd-tls-certs-cm`, restarts repo-server, then registers the repo/root app.

2. Argo ingress hardening contract:
- `Job/argocd-https-switch` (PostSync) derives hostname from deployment config, patches `HTTPRoute/argocd` hostnames, sets `argocd-cm.url=https://<argocd-host>`, sets `server.insecure=false` and `server.repo.server.strict.tls=true`, and removes `--insecure` from server deployment args.
- Job RBAC is namespaced and resource-scoped to the specific ConfigMaps/Deployment/HTTPRoute.

3. Argo OIDC config contract:
- `Job/argocd-oidc-config` (PostSync) waits for Keycloak bootstrap readiness, then patches `argocd-cm` OIDC config and `argocd-rbac-cm` policy.
- Job reads hostnames from deployment config and uses scoped RBAC (`resourceNames`) for ConfigMaps/Secrets/workloads.

4. Bootstrap safety exception (Vault/ESO path):
- Mesh default remains STRICT mTLS.
- `PeerAuthentication/vault-permissive` is applied for Vault workload in `vault-system` so out-of-mesh External Secrets can authenticate to Vault during bootstrap and reconcile critical secrets.

## Security and access contracts

- Access-plane resources (RBAC, CRDs, admission/webhooks) are GitOps-only under normal operation.
- Argo identities are allow-listed narrowly where controller self-management is required.
- Breakglass is allowed only through documented operator flows with evidence.
- The local Argo admin account may be disabled by runtime OIDC policy; automation should use non-interactive token flows.

See:
- `docs/design/cluster-access-contract.md`
- `docs/toils/argocd-interactive-troubleshooting.md`
- `docs/toils/argocd-cli-noninteractive.md`

## Implementation map (repo)

- Argo config and policy: `platform/gitops/components/platform/argocd/config/`
- Argo ingress wiring: `platform/gitops/components/platform/argocd/ingress/`
- PlatformApps API/controller: `platform/gitops/components/platform/platform-apps-controller/`, `tools/tenant-provisioner/internal/controllers/platform_apps_controller.go`
- Environment app bundles: `platform/gitops/apps/environments/*/`
- Root app definitions: `platform/gitops/apps/base/`
- CLI/token helpers: `shared/scripts/argocd-token.sh`

## Invariants

- Argo reconciles from Git; no hand-managed in-cluster drift for steady-state resources.
- Root app status (`Synced Healthy`) is the first promotion gate for platform changes.
- Any change to Argo auth/project policy must ship with evidence and rollback notes.
- For Forgejo repo access, Argo and in-cluster automation use the internal HTTPS endpoint plus CA trust wiring.

## Validation and evidence

Primary signals:
- Root app + touched app status are `Synced Healthy`.
- Relevant PostSync/Cron smoke jobs pass for changed surfaces.
- Forgejo TLS endpoint and CA secret are present and readable by scoped service accounts.
- Evidence note exists under `docs/evidence/YYYY-MM-DD-*.md`.

Recent evidence:
