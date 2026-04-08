# Toil: Root-Of-Trust Mode Matrix E2E

Run live root-of-trust mode validation by mutating `DeploymentConfig.spec.secrets.rootOfTrust`, rerunning secrets hooks, validating `kms-shim-token` state, and restoring original config.

Script:
- `tests/scripts/e2e-root-of-trust-modes-matrix.sh`

## Safety contract

- Mutates singleton `DeploymentConfig`.
- Requires explicit mutation acknowledgement.
- Restores original `spec.secrets.rootOfTrust` on exit.
- Restores Argo auto-sync for `argocd/platform-apps` and `argocd/deployment-secrets-bundle`.

## Profiles

- `quick`:
  - `mode=inCluster`

- `full`:
  - `quick` profile
  - `mode=external` according to `--run-external` plus endpoint policy:
    - If `--external-address` (or env) is provided, uses that endpoint.
    - If endpoint is missing and `--provision-external-simulator auto|yes`, provisions ephemeral in-cluster external KMS endpoint simulator.

## Assertions

- `mode=inCluster`:
  - `vault-system/Secret/kms-shim-token` exists
  - `vault-system/Secret/kms-shim-token` has empty `data.address`
  - `vault-seal-system/Secret/kms-shim-token` exists

- `mode=external`:
  - `vault-system/Secret/kms-shim-token` exists
  - `vault-system/Secret/kms-shim-token data.address` matches requested endpoint
  - optional (`--verify-vault-restart yes`, default):
    - restart each Vault pod (`vault-0..`) sequentially
    - each restarted pod becomes Ready and unsealed
    - external-seal startup marker appears in logs
    - simulator observes transit encrypt/decrypt calls

Hook behavior:
- `secrets-bootstrap` is mandatory in each phase.
- `secrets-vault-config` and `secrets-external-secrets-config` hooks are attempted; non-success is logged as warning so unrelated app health drift does not block this mode test.

Troubleshooting:
- If the live `DeploymentConfig` does not change modes after the patch step, stop and inspect the live object before waiting on the snapshot ConfigMap; the script now prints the live `spec.secrets.rootOfTrust.mode` readback for exactly this reason.
- After an external-mode run, stale `vault-system/Secret/kms-shim-token.data.address` or stale Vault pod runtime config can keep Vault pointed at the external seal endpoint even after the spec is restored to `mode=inCluster`. Clear the Secret key, restart Vault pods, and verify they come back on `http://kms-shim.vault-seal-system.svc:8200`.

## Local examples

Quick:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_ROT_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-root-of-trust-modes-matrix.sh \
  --profile quick \
  --ack-config-mutation yes
```

Full with simulator-backed external mode + Vault restart verification:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_ROT_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-root-of-trust-modes-matrix.sh \
  --profile full \
  --run-external auto \
  --provision-external-simulator yes \
  --verify-vault-restart yes \
  --timeout 35m \
  --ack-config-mutation yes
```

Full with explicit external address:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_ROT_E2E_ACK_CONFIG_MUTATION=yes \
DK_ROT_E2E_EXTERNAL_ADDRESS="https://kms-shim.example.internal:8200" \./tests/scripts/e2e-root-of-trust-modes-matrix.sh \
  --profile full \
  --run-external yes \
  --provision-external-simulator no \
  --ack-config-mutation yes
```

## CI workflow

- `.github/workflows/root-of-trust-mode-e2e.yml`
- PR quick run (gated by `DK_ROT_E2E_ENABLED=true`)
- nightly/manual full run (defaults to simulator-backed external mode + restart verification unless overridden)
