# Toil: Release Runtime Smoke Suite

Run the curated runtime smoke set used by release gating.

Script:
- `tests/scripts/e2e-release-runtime-smokes.sh`

## Why this exists

- In-cluster CronJobs provide continuous assurance, but release gating needs a deterministic one-shot runtime signal.
- This wrapper keeps release runtime coverage explicit and stable via pinned app allowlists.

## Profiles

- `quick`:
  - `networking-metallb`
  - `networking-gateway-api`
  - `networking-dns-external-sync`
  - `networking-ingress-smoke-tests`
  - `shared-policy-kyverno`
  - `secrets-vault-config`
  - `secrets-external-secrets-config`
  - `platform-registry-harbor-smoke-tests`

- `full`:
  - all `quick` apps
  - `platform-observability-tests`
  - `platform-forgejo-valkey-smoke-tests`
  - `storage-backup-system`

## Safety notes

- The default full profile is non-destructive.
- Restore canary is optional and explicit:
  - `--include-restore-canary yes`

## Examples

Quick:

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/e2e-release-runtime-smokes.sh \
  --profile quick \
  --timeout 25m
```

Full:

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/e2e-release-runtime-smokes.sh \
  --profile full \
  --timeout 35m
```

Full + restore canary:

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/e2e-release-runtime-smokes.sh \
  --profile full \
  --include-restore-canary yes \
  --timeout 35m
```
