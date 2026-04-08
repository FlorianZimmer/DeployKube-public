# Toil: Vault CLI (non-interactive, browserless)

This runbook documents DeployKube’s non-interactive Vault CLI workflow (token-based, no browser).

Related:
- Token helper: `shared/scripts/vault-token.sh`
- Keycloak + Vault automation wiring: `platform/gitops/components/platform/keycloak/README.md`
- Human login (OIDC): `docs/toils/vault-cli-oidc-login.md`

Note:
- This runbook is for **automation** via Vault `auth/jwt` (token-based, browserless).
- Human Vault UI/CLI login uses the separate `auth/oidc` mount (configured by `CronJob/vault-oidc-config`; see `platform/gitops/components/secrets/vault/README.md`).

## Automation wiring (expected posture)

- Keycloak client `vault-cli` (direct access grant)
- Group `dk-bot-vault-writer`
- Vault `jwt` auth mount/role `vault-automation`
- Policy `automation-write` (CRUD on `secret/*` + self-renew)
- Automation user `vault-automation` is a member of `dk-bot-vault-writer`
- Vault role is pinned to the Keycloak user `sub` for `vault-automation` (resolved automatically by vault config jobs) for defense in depth.
- Vault role `bound_audiences` is derived from the live automation token claims (fallback: configured default), so environments that emit `aud=account` still validate correctly.

## Credentials source (Vault-managed)

- User: `secret/keycloak/vault-automation-user` (`username`, `password`)
- Client secret: `secret/keycloak/vault-client` (`clientSecret`)

## Get a Vault token from your Mac

Preferred Vault lookup path:

```sh
KEYCLOAK_VAULT_ADDR=http://127.0.0.1:8200 \  # optional: pull creds from Vault if you already have access./shared/scripts/vault-token.sh
# script prints: export VAULT_TOKEN=...
```

Minimal env without Vault lookup:

```sh
KEYCLOAK_USERNAME=vault-automation \
KEYCLOAK_PASSWORD=<from vault/keycloak admin> \
KEYCLOAK_CLIENT_SECRET=<vault-cli client secret from vault> \./shared/scripts/vault-token.sh
```

## Use the token to write service secrets

```sh
export VAULT_ADDR=https://vault.<env>.internal.example.com
export VAULT_CACERT=shared/certs/deploykube-root-ca.crt
export VAULT_TOKEN=<from the script>

vault kv put secret/my-service/example password="$(openssl rand -base64 24)"
```

Smoke/verify:
- The helper already runs `vault kv get secret/bootstrap`.
- You can also run `vault kv get secret/my-service/example` to confirm.
