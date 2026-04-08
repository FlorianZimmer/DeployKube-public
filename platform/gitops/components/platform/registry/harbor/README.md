# Harbor (OCI Registry)

Harbor is DeployKube’s platform-managed, in-cluster OCI registry (images today; OCI artifacts/charts later).

This component installs Harbor in the `harbor` namespace and exposes it via Istio + Gateway API:
- `harbor.<baseDomain>`: Harbor UI / API
- `registry.<baseDomain>`: OCI registry endpoint (`/v2/…`)

Hostnames and TLS are deployment-config driven and reconciled by the tenant-provisioner controller (no repo-side per-deployment hostname overlays).

Versions:
- Helm chart: `harbor/harbor` `1.18.2`
- App: `goharbor/*` `v2.14.2` (as rendered by the chart)

Design / tracker:
- `docs/design/registry-harbor.md`
- `docs/component-issues/registry-harbor.md`

## Subfolders

| Path | Purpose |
| ---- | ------- |
| `secrets/` | ExternalSecrets for Harbor wiring (Vault → K8s Secrets). |
| `postgres/` | `PostgresInstance` request and Postgres credential sources for Harbor (`postgres-rw.harbor.svc`). |
| `helm/` | Harbor Helm chart rendered via Kustomize `helmCharts:` (no secrets in Git). |
| `ingress/` | `HTTPRoute` objects for `harbor` and `registry` hostnames. |
| `smoke-tests/` | PostSync smoke job (gateway + API + registry `/v2`). |

## Notes

- Harbor is configured with `expose.type=clusterIP` and is exposed externally via `HTTPRoute` (Istio Gateway).
- Harbor uses an external Postgres requested through `data.darksite.cloud/v1alpha1 PostgresInstance`; `platform-postgres-controller` owns the underlying CNPG backend so Harbor no longer ships raw CNPG manifests itself.
- Harbor chart-generated `Secret` objects are removed with Kustomize `$patch: delete`; Secrets are owned by ExternalSecrets.
- Harbor’s chart-generated `ConfigMap/harbor-nginx` is patched to set upstream `Host` to `harbor-core` (preserving the original hostname via `X-Forwarded-Host`) to avoid Envoy `PassthroughCluster` plaintext under mesh `STRICT` mTLS.

## Argo apps (platform-apps chart)

Proxmox (`proxmox-talos`) enables the Harbor apps; dev environments disable them by default.

Apps + expected order:
- `platform-registry-harbor-secrets` (Vault → K8s Secrets, token-service cert)
- `platform-registry-harbor-postgres` (`PostgresInstance` intent + backend reconciliation)
- `platform-registry-harbor` (Harbor chart)
- `platform-registry-harbor-ingress` (HTTPRoutes)
- `platform-registry-harbor-smoke-tests` (PostSync validation)

## Secrets (Vault paths)

The Vault KV v2 paths are seeded by `platform/gitops/components/secrets/vault/config/scripts/configure.sh` and consumed via ExternalSecrets:
- `harbor/admin` (`password`)
- `harbor/core` (`secret`, `secretKey`, `csrfKey`)
- `harbor/jobservice` (`secret`)
- `harbor/registry` (`httpSecret`, `credentialsPassword`, `credentialsHtpasswd`)
- `harbor/database` (`appPassword`, `superuserPassword`)

`ExternalSecret/harbor-oidc-ca` is Harbor-owned even though it reads the shared `secret/keycloak/oidc-ca` source path. Do not duplicate that object in `components/secrets/external-secrets/keycloak-oidc-trust/`, or Argo will keep the Keycloak OIDC trust fan-out and Harbor secrets apps OutOfSync by racing over the same resource.

## Smoke test

`smoke-tests/` installs a PostSync `Job/harbor-smoke` that:
- resolves `harbor`/`registry` hostnames from the DeploymentConfig snapshot (`argocd/deploykube-deployment-config`),
- curls `https://<harborHost>/api/v2.0/ping`,
- curls `https://<registryHost>/v2/` (expects `200` or `401`),
- and verifies Harbor API auth using `Secret/harbor/harbor-admin-password`.
