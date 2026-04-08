# Keycloak Secrets (ESO)

This component fans Vault material into Kubernetes so the rest of the Keycloak stack can converge early in the bootstrap sequence:

- `keycloak-admin-credentials`, `keycloak-dev-user`, and `keycloak-db` land in the `keycloak` namespace for the operator + CNPG overlay.
- `keycloak-argocd-automation-user` holds the Argo automation account used by agents to obtain Argo CD tokens non-interactively.
- `keycloak-vault-automation-user` holds the Vault automation account used by agents to mint JWT auth tokens in Vault.
- `keycloak-automation-user` remains as a legacy compatibility alias for Argo automation callers during migration.
- `keycloak-argocd-client` / `keycloak-forgejo-client` / `keycloak-kiali-client` / `keycloak-harbor-client` / `keycloak-hubble-client` / `keycloak-vault-client` replicate Vault’s OIDC client definitions back into the `keycloak` namespace so the bootstrap job can mount secrets without reaching across namespaces.
- `keycloak-upstream-{oidc,saml,ldap,scim}` project upstream IAM integration material (`secret/keycloak/upstream-*`) into `keycloak` so IAM mode reconciliation can configure upstream providers without plaintext in Git.
  - Expected key contract:
    - `secret/keycloak/upstream-oidc`: `clientSecret` (required), `clientId` (optional), `ca.crt` (optional TLS trust for hybrid health checks).
    - `secret/keycloak/upstream-saml`: `signingCert`.
    - `secret/keycloak/upstream-ldap`: `bindDn`, `bindPassword`.
    - `secret/keycloak/upstream-scim`: `token` (or bridge-specific auth key).
- `kiali` (namespace `istio-system`) is a small shim Secret containing `oidc-secret` for Kiali’s OIDC flow (sourced from `secret/keycloak/kiali-client`).
- `keycloak-postgres-superuser` mirrors the CNPG superuser password (username fixed to `postgres`) so managed roles and the bootstrap tooling can escalate when required.
- Cross-namespace bindings keep Argo CD (`argocd-secret: oidc.clientSecret`) and Forgejo (`forgejo-oidc-client`) aligned with the Keycloak-managed OIDC clients.
- Shared OIDC trust bundles (`argocd-oidc-ca`, `forgejo-oidc-ca`, and any Secret embedding the CA) live in `components/secrets/external-secrets/keycloak-oidc-trust/` and intentionally sync later, after Step CA bootstrap has published `secret/keycloak/oidc-ca`.
- Harbor consumes the same `secret/keycloak/oidc-ca` material via `platform/gitops/components/platform/registry/harbor/secrets/externalsecrets.yaml`; `ExternalSecret/harbor-oidc-ca` must remain Harbor-owned so Argo does not leave the Keycloak trust fan-out and Harbor secrets apps fighting over the same object.
- Every ExternalSecret points at `ClusterSecretStore vault-core`, so Vault must expose the `secret/keycloak/*` paths and the `external-secrets` Vault role must be configured (handled by the updated `vault-configure` job).

As we replace legacy manifests, keep this README synced with the data contracts (secret keys, refresh windows, error handling expectations).
