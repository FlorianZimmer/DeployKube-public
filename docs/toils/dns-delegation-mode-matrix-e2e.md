# Toil: DNS Delegation Mode Matrix E2E

Run live DNS delegation mode validation by mutating `DeploymentConfig.spec.dns.delegation`, validating controller outputs, rerunning DNS hooks, and restoring original config.

Script:
- `tests/scripts/e2e-dns-delegation-modes-matrix.sh`

## Safety contract

- Mutates singleton `DeploymentConfig`.
- Requires explicit mutation acknowledgement.
- Restores original `spec.dns.delegation` on exit.
- Restores Argo auto-sync for `argocd/platform-apps` and `argocd/deployment-secrets-bundle`.

## Profiles

- `quick`:
  - `mode=none`
  - `mode=manual`

- `full`:
  - `quick` profile
  - `mode=auto` according to `--run-auto` plus writer backend policy:
    - If writerRef is provided, uses provided writer secret.
    - If writerRef is missing and `--provision-writer-simulator auto|yes`, provisions ephemeral in-cluster writer simulator.

## Assertions

- `mode=none`:
  - `dns-system/ConfigMap/deploykube-dns-wiring` has `DNS_DELEGATION_MODE=none`
  - `DeploymentConfig.status.dns.delegation.mode=none`
  - legacy `argocd/ConfigMap/deploykube-dns-delegation` is absent

- `mode=manual`:
  - `dns-system/ConfigMap/deploykube-dns-wiring` has `DNS_DELEGATION_MODE=manual`
  - `DeploymentConfig.status.dns.delegation.mode=manual`
  - `DeploymentConfig.status.dns.delegation.parentZone` matches
  - `DeploymentConfig.status.dns.delegation.manualInstructions[]` is populated
  - legacy `argocd/ConfigMap/deploykube-dns-delegation` is absent

- `mode=auto`:
  - `dns-system/ConfigMap/deploykube-dns-wiring` has `DNS_DELEGATION_MODE=auto`
  - `DeploymentConfig.status.dns.delegation.mode=auto`
  - legacy `argocd/ConfigMap/deploykube-dns-delegation` is absent
  - tenant controller logs include `auto delegation reconciled`
  - when simulator is provisioned, script validates parent-zone write payload at rrset level (NS + glue A)

## Local examples

Quick:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_DNS_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-dns-delegation-modes-matrix.sh \
  --profile quick \
  --parent-zone internal.example.com \
  --ack-config-mutation yes
```

Full with simulator-backed auto mode:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_DNS_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-dns-delegation-modes-matrix.sh \
  --profile full \
  --run-auto auto \
  --provision-writer-simulator yes \
  --timeout 30m \
  --ack-config-mutation yes
```

Full with explicit writerRef:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_DNS_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-dns-delegation-modes-matrix.sh \
  --profile full \
  --run-auto yes \
  --writer-secret-name deploykube-dns-delegation \
  --writer-secret-namespace dns-system \
  --ack-config-mutation yes
```

## CI workflow

- `.github/workflows/dns-delegation-mode-e2e.yml`
- PR quick run (gated by `DK_DNS_E2E_ENABLED=true`)
- nightly/manual full run (defaults to simulator-backed auto mode unless overridden)
