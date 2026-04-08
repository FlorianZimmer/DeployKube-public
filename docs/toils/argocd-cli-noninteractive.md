# Toil: Argo CD CLI (non-interactive, browserless)

This runbook documents DeployKube’s non-interactive Argo CD CLI workflow (token-based, no browser).

Related:
- GitOps operating model: `docs/design/gitops-operating-model.md`
- Keycloak token helpers: `shared/scripts/argocd-token.sh`

## Token helper (recommended)

Automation account:
- User: `argocd-automation` (Vault `secret/keycloak/argocd-automation-user`, projected via ESO)
- Argo CD RBAC maps it to `role:argocd-sync-bot` via Keycloak group `dk-bot-argocd-sync` (sync on `platform/*` apps).

Get a token on your Mac (preferred Vault path):

```sh
KEYCLOAK_VAULT_ADDR=http://127.0.0.1:8200 \  # or your Vault URL./shared/scripts/argocd-token.sh
# script prints: export ARGOCD_AUTH_TOKEN=...
```

Fallback without Vault:

```sh
KEYCLOAK_USERNAME=argocd-automation \
KEYCLOAK_PASSWORD=<from vault> \
KEYCLOAK_CLIENT_SECRET=<argocd client secret from vault> \./shared/scripts/argocd-token.sh
```

## Use the token (no browser)

Derive the Argo CD host from the deployment config snapshot:

```sh
ARGOCD_HOST="$(kubectl -n argocd get configmap deploykube-deployment-config \
  -o jsonpath='{.data.deployment-config\.yaml}' | yq -r '.spec.dns.hostnames.argocd')"
```

```sh
ARGOCD_AUTH_TOKEN=$ARGOCD_AUTH_TOKEN \
argocd app sync storage-garage \
  --grpc-web \
  --server "${ARGOCD_HOST}" \
  --server-crt shared/certs/deploykube-root-ca.crt
```

## DNS broken fallback (port-forward)

```sh
KUBECONFIG=tmp/kubeconfig-prod \
ARGOCD_AUTH_TOKEN=$ARGOCD_AUTH_TOKEN \
argocd app get platform-apps --grpc-web --port-forward --port-forward-namespace argocd --plaintext
```

## Troubleshooting

- Ensure the `groups` claim is present (`dk-bot-argocd-sync`).
- Argo CD OIDC uses `groupsFieldName: groups`.
- RBAC includes `g, dk-bot-argocd-sync, role:argocd-sync-bot`.
