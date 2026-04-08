# platform/forgejo/valkey

Forgejo-specific overlay for the shared Valkey base manifests. This layer will:
- Instantiate the base with Forgejo naming (`forgejo-valkey`, `forgejo-valkey-sentinel`).
- Set replica counts, StorageClass, and ExternalSecret references.
- Publish ClusterIP services for in-cluster access.

## Smoke Jobs / Test Coverage

- `CronJob/forgejo-valkey-smoke` (app: `platform-forgejo-valkey-smoke-tests`) validates:
  - auth + `PING`,
  - Sentinel master discovery,
  - `SET`/`GET` against the Sentinel-discovered master (avoid read-after-write flakiness from the load-balanced `Service/forgejo-valkey`).

Notes:
- Runs **in-mesh** (Istio native sidecar) because the Valkey pods are in-mesh; a non-mesh client can get `Connection reset by peer`.

Run once:

```bash
kubectl -n forgejo create job --from=cronjob/forgejo-valkey-smoke smoke-manual-$(date +%s)
```

## Backup and Restore

- Cache-only: no backup/restore is shipped for Valkey.
- Losing Valkey data must be acceptable to Forgejo (caches/queues/sessions must be recoverable).
