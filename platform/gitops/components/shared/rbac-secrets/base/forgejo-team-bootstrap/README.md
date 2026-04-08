# Forgejo Team Bootstrap Job (temp automation)

- Purpose: reconcile the credentials needed by `forgejo-team-sync` (Forgejo PAT + Keycloak client secret), write them to Vault `secret/forgejo/team-sync`, and emit an in-cluster Secret for immediate CronJob use.
- Runs as an Argo CD **Sync hook** (Job) in `rbac-system` under the `shared-rbac-secrets` app; idempotent via ConfigMap `forgejo-team-bootstrap-status` + the output Secret.
- Depends on:
  - `forgejo-admin` Secret (ExternalSecret backed by `secret/forgejo/admin`).
  - `keycloak-admin-credentials` Secret.
  - Vault policy/role `forgejo-team-sync` (created by `vault-configure`).
- Outputs:
  - Vault (KV v2): `secret/forgejo/team-sync` with `token`, `keycloakClientId`, `keycloakClientSecret`.
  - Secret: `forgejo-team-sync` in `rbac-system` with the same keys for CronJob consumption.
- Remove this job when the full RBAC automation replaces it; then rely on the permanent team-sync CronJob only.

## Rerun / Rotation
- Default behavior is **no rotation**:
  - It reuses the existing Forgejo token (if valid) and reads the **current** Keycloak client secret from Keycloak.
- Drift prevention: if the job finds the status ConfigMap + output Secret but the stored Keycloak credentials no longer work, it does **not** skip and will reconcile the secret back to the Keycloak source of truth.
- It also validates that the stored Forgejo token can manage the target org. If not, it reconciles by granting the bot org ownership and reusing/rotating the token as configured.

To rerun explicitly:
- Set `FORGEJO_TEAM_BOOTSTRAP_FORCE=true` on the Job and re-apply/sync (or delete the `forgejo-team-bootstrap-status` ConfigMap and re-sync).

To rotate credentials (explicit, opt-in):
- `FORGEJO_TEAM_BOOTSTRAP_ROTATE_FORGEJO_TOKEN=true`: mint a new Forgejo PAT and prune old tokens with the `forgejo-team-sync` prefix.
- `FORGEJO_TEAM_BOOTSTRAP_ROTATE_KEYCLOAK_SECRET=true`: rotate the Keycloak client secret, then read it back and persist it to Vault/Kubernetes.

## Notes
- The team-sync bot user must be an **owner** of the target org (default: `platform`). Forgejo models this via the built-in **Owners** team; the bootstrap job ensures the bot is a member (using Forgejo admin credentials) so the CronJob can run with a bot-scoped PAT instead of an admin token.
- Keycloak admin login uses `--data-urlencode` for username/password so Vault-managed passwords containing `+` / `&` work reliably with the token endpoint.
