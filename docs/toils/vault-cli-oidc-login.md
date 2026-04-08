# Toil: Vault CLI OIDC login (human)

This runbook documents DeployKube’s **human** Vault CLI login workflow via Keycloak OIDC.

Related:
- Automation (JWT, no browser): `docs/toils/vault-cli-noninteractive.md`
- Vault component docs: `platform/gitops/components/secrets/vault/README.md`
- Keycloak component docs: `platform/gitops/components/platform/keycloak/README.md`

## Preconditions

- Vault `auth/oidc` is configured (GitOps) by `CronJob/vault-oidc-config`.
- Keycloak client `vault-cli` allows local redirect URIs:
  - `http://127.0.0.1:8400/*` and `http://localhost:8400/*`
- Your Keycloak user is in at least one group (so the `groups` claim exists).

## Login (recommended)

```sh
export VAULT_ADDR=https://vault.<env>.internal.example.com
export VAULT_CACERT=shared/certs/deploykube-root-ca.crt

vault login -method=oidc -path=oidc role=default \
  port=8400 callbackhost=127.0.0.1 callbackport=8400 listenaddress=127.0.0.1 \
  skip_browser=true
```

The CLI prints a Keycloak login URL. Open it in your browser, complete login, and the CLI finishes by writing `~/.vault-token`.

Verify:

```sh
vault token lookup
```

## Troubleshooting

### Port 8400 already in use

The Vault CLI starts a local callback listener on `127.0.0.1:8400`. If you previously aborted a login, the port may still be bound.

```sh
lsof -nP -iTCP:8400 -sTCP:LISTEN
kill <pid>
```

### `groups` claim missing

If Vault errors with something like `\"groups\" claim not found in token`, ensure:
- the user is a member of at least one Keycloak group, and
- the Keycloak `vault-cli` client includes a `groups` protocol mapper (claim name: `groups`).

### Keycloak `unknown_error` during auth

If the Keycloak auth endpoint returns an `unknown_error` (HTTP 500), retry the login; this is typically transient.
