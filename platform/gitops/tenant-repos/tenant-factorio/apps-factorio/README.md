# Tenant repo: tenant-factorio/apps-factorio

This folder is a **seed source** for the tenant workload repo:
- Forgejo org: `tenant-factorio`
- Repo: `apps-factorio.git`

This repo is reconciled by Argo CD via the platform-owned `Application/apps-factorio`
and targets the tenant namespace(s) created by the platform-owned tenant intent surface:
- `t-factorio-p-factorio-dev-app`
- `t-factorio-p-factorio-prod-app`

Notes:
- Do **not** commit `Namespace` or `ExternalSecret` objects here; those are platform-owned.
- Tenant baseline policies apply (PSS restricted pods, no `Service` type `LoadBalancer`, etc.).
- CI / PR gates:
  - This repo vendors the standard DeployKube tenant PR gate suite under `shared/scripts/tenant/`.
  - CI workflow: `.forgejo/workflows/tenant-pr-gates.yaml` (also mirrored for GitHub under `.github/workflows/`).
  - In product mode, the platform enforces the `tenant-pr-gates` check as a required status check on the protected default branch.
- Backup/restore contract:
  - Backup credentials are provisioned by the platform into `Secret/factorio-backup` (Vault source: `secret/tenants/factorio/projects/factorio/sys/backup`).
  - `CronJob/factorio-restore-drill` restores `latest` into scratch space and validates expected files exist.
