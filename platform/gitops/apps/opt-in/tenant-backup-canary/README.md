# Tenant Backup Canary (Opt-in)

Purpose: provide a small, **platform-owned** canary tenant workload (`smoke/demo`) to continuously validate tenant-scoped backup boundaries and restore-drill compatibility.

This opt-in app intentionally:
- creates a single tenant namespace for the reserved smoke tenant/project (`smoke/demo`),
- provisions a small PVC with deterministic content,
- ships **suspended** CronJobs that can be manually triggered to:
  - write the canary payload,
  - run a restic backup into the tenant-scoped S3 repo,
  - run a restic restore drill under tenant baseline constraints.

Notes:
- Credentials are **not** stored in Git. They are expected to be provisioned into Vault under `secret/tenants/smoke/projects/demo/sys/backup` by the platform backup provisioners:
  - `vault-system/CronJob/vault-tenant-backup-provisioner-role` (Vault role/policy reconcile)
  - `garage/CronJob/garage-tenant-backup-provisioner` (Garage bucket + Vault KV reconcile)
- Tenant namespaces are denied from creating ESO CRDs by policy; secret projection for this canary is handled by the Vault-side helper CronJobs (see `platform/gitops/components/secrets/vault/config/`).
- The canary namespace (`tenant-smoke-demo`) is a tenant namespace and must set `darksite.cloud/project-id=demo` (admission-enforced).

## Enable (prod)

Apply the Argo CD `Application`:

```sh
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd apply -f platform/gitops/apps/opt-in/tenant-backup-canary/applications/tenant-backup-canary-prod.yaml
```

## Run the drill (manual)

After the app is synced and the Vault → tenant secret sync has populated `Secret/tenant-backup-s3`, create Jobs from the suspended CronJobs:

```sh
KUBECONFIG=tmp/kubeconfig-prod kubectl -n tenant-smoke-demo create job --from=cronjob/tenant-backup-canary-write tbc-write-$(date +%H%M%S)
KUBECONFIG=tmp/kubeconfig-prod kubectl -n tenant-smoke-demo create job --from=cronjob/tenant-backup-canary-backup tbc-backup-$(date +%H%M%S)
KUBECONFIG=tmp/kubeconfig-prod kubectl -n tenant-smoke-demo create job --from=cronjob/tenant-backup-canary-restore tbc-restore-$(date +%H%M%S)
```
