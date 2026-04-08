# Toil: Tune Loki retention via DeploymentConfig

Loki retention is **DeploymentConfig-driven** and reconciled by the tenant provisioner controller (no repo-side “render then commit” of Helm values).

Source of truth:
- `platform/gitops/deployments/<deploymentId>/config.yaml` → `spec.observability.loki.limits.retentionPeriod`

CI guardrail:
- `./tests/scripts/validate-loki-limits-controller-cutover.sh`

## Change retention (repo)

1. Edit the DeploymentConfig:
   - `platform/gitops/deployments/<deploymentId>/config.yaml`

2. Validate locally:

```bash./tests/scripts/validate-loki-limits-controller-cutover.sh./tests/scripts/ci.sh deployment-contracts
```

3. Commit the change (Forgejo seeding snapshots git `HEAD`):
   - `DK_ALLOW_MAIN_COMMIT=1 git commit...`

## Roll out (proxmox-talos)

1. Push and seed Forgejo:

```bash
DK_ALLOW_MAIN_PUSH=1 git push origin main
KUBECONFIG=tmp/kubeconfig-prod \
  FORGEJO_SEED_SENTINEL=tmp/bootstrap/forgejo-repo-seeded-proxmox \
  FORGEJO_FORCE_SEED=true \./shared/scripts/forgejo-seed-repo.sh
```

2. Refresh Argo and verify apps are healthy:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd get application platform-observability-loki \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}{"\n"}'
```

3. Verify the live Loki config contains the new retention:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n loki get configmap loki -o jsonpath='{.data.config\.yaml}' | rg -n 'retention_period'
```

4. Optional: run the continuous smokes as one-off Jobs:

```bash
ts=$(date +%s)
KUBECONFIG=tmp/kubeconfig-prod kubectl -n observability create job --from=cronjob/observability-log-smoke observability-log-smoke-manual-${ts}
KUBECONFIG=tmp/kubeconfig-prod kubectl -n observability create job --from=cronjob/observability-loki-ring-smoke observability-loki-ring-smoke-manual-${ts}
```
