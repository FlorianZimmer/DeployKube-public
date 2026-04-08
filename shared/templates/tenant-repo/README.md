# Template: tenant repo CI + PR gates

This template is intended to be copied into a tenant workload repo (`tenant-<orgId>/apps-<projectId>`).

It provides:
- a CI workflow that runs the DeployKube **tenant PR gate suite** on every PR (and on `main` pushes)
- a stable status-check name (`tenant-pr-gates`) that the platform can require via Forgejo protected branches

## How to use

1. Vendor the gate suite into the tenant repo:
   - `shared/scripts/tenant/`
   - `shared/contracts/tenant-prohibited-kinds.yaml`

2. Copy the workflow file for your Git server:
   - Forgejo: `.forgejo/workflows/tenant-pr-gates.yaml`
   - GitHub: `.github/workflows/tenant-pr-gates.yaml`

3. Ensure the tenant repo is protected so PRs require the `tenant-pr-gates` check.

In DeployKube product mode (Forgejo), this is enforced by the platform CronJob
`rbac-system/CronJob/forgejo-tenant-pr-gate-enforcer`.

