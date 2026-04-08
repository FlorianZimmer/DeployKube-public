# Toil: Certificates Mode Matrix E2E

Run live E2E validation across certificate modes (`subCa`, `acme`, `wildcard`) by mutating `DeploymentConfig.spec.certificates`, running certificate smoke CronJobs, and restoring the original config.

Script:
- `tests/scripts/e2e-cert-modes-matrix.sh`

## Safety and scope

- This is a runtime test against a real cluster.
- It patches the singleton `DeploymentConfig` and restores it on exit.
- By default it temporarily scales `argocd/deployment-config-controller` to `0` during the matrix run to prevent reconciliation drift while testing mutable modes.
- By default it also temporarily disables Argo auto-sync on both `argocd/platform-apps` and `argocd/deployment-secrets-bundle` to avoid GitOps reverting the temporary matrix patch.
- Use a dedicated validation cluster or maintenance window.

## Required acknowledgement

You must explicitly acknowledge config mutation:

```bash
DK_CERT_E2E_ACK_CONFIG_MUTATION=yes
```

or pass:

```bash
--ack-config-mutation yes
```

## Quick run (subCa only)

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_CERT_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-cert-modes-matrix.sh \
  --modes subCa \
  --timeout 20m \
  --ack-config-mutation yes
```

## Full matrix run

Minimal required environment for full matrix:

- ACME:
  - `DK_CERT_E2E_ACME_SERVER`
  - `DK_CERT_E2E_ACME_EMAIL`
  - Optional for self-hosted ACME: `DK_CERT_E2E_ACME_CA_BUNDLE` (base64 PEM)
  - `DK_CERT_E2E_ACME_PROVIDER` (`rfc2136|cloudflare|route53`)
  - Provider-specific fields (`DK_CERT_E2E_ACME_RFC2136_*` / `DK_CERT_E2E_ACME_CREDENTIALS_VAULT_PATH` / `DK_CERT_E2E_ACME_ROUTE53_REGION`, etc.)
- Wildcard:
  - `DK_CERT_E2E_WILDCARD_VAULT_PATH`

Example:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_CERT_E2E_ACK_CONFIG_MUTATION=yes \
DK_CERT_E2E_ACME_SERVER="https://<acme-directory>" \
DK_CERT_E2E_ACME_EMAIL="platform@example.com" \
DK_CERT_E2E_ACME_PROVIDER="rfc2136" \
DK_CERT_E2E_ACME_RFC2136_NAMESERVER="198.51.100.3:53" \
DK_CERT_E2E_ACME_RFC2136_TSIG_KEY_NAME="acme-key." \
DK_CERT_E2E_ACME_CREDENTIALS_VAULT_PATH="secret/data/cert-manager/acme-dns01" \
DK_CERT_E2E_WILDCARD_VAULT_PATH="secret/data/ingress/platform-wildcard" \./tests/scripts/e2e-cert-modes-matrix.sh \
  --modes subCa,acme,wildcard \
  --timeout 25m \
  --ack-config-mutation yes
```

## CI wiring

Workflow:
- `.github/workflows/certificates-mode-e2e.yml`

Behavior:
- PR (internal branches, when `DK_CERT_E2E_ENABLED=true`): quick `subCa` run.
- Nightly schedule (when `DK_CERT_E2E_ENABLED=true`): full matrix.
- Manual dispatch: `quick` or `full`.

Runner configuration:
- Optional repo variable: `DK_CERT_E2E_KUBECONFIG` (absolute path on self-hosted runner).
- Full matrix secrets/vars are read from `DK_CERT_E2E_*` workflow env mapping.
- Optional override: `DK_CERT_E2E_FREEZE_DEPLOYMENT_CONFIG_CONTROLLER=no` (or `--freeze-deployment-config-controller no`) to disable controller freeze when desired.
- Optional override: `DK_CERT_E2E_FREEZE_GITOPS_SYNC=no` (or `--freeze-gitops-sync no`) to keep Argo auto-sync enabled.
