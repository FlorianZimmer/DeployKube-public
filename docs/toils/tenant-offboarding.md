# Toil: Tenant offboarding (Tier S) — inventory + wipe primitives

This toil documents the **operator-facing scripts** for tenant offboarding evidence capture and safe-by-construction wipes.

Design: `docs/design/multitenancy-lifecycle-and-data-deletion.md#8-runbook-offboarding-data-deletion--evidence`

## Scripts (repo surface)

- Inventory (namespaces + PVC→PV + backend paths): `scripts/toils/tenant-offboarding/inventory.sh`
- Wipe PV backend data (generates/executes Jobs): `scripts/toils/tenant-offboarding/wipe-pv-data.sh`
- Delete Garage tenant buckets + keys (in-cluster Job): `scripts/toils/tenant-offboarding/delete-garage-tenant-s3.sh`
- Wipe Vault KV v2 subtree (metadata delete): `scripts/toils/tenant-offboarding/wipe-vault-tenant-kv.sh`

## Typical workflow (Phase D/E/G helpers)

> Always create an evidence note first: `docs/evidence/YYYY-MM-DD-tenant-<orgId>-offboarding.md`.

### 1) Inventory (read-only)

```bash
KUBECONFIG=tmp/kubeconfig-prod \./scripts/toils/tenant-offboarding/inventory.sh --org-id <orgId>
```

### 2) PV wipe jobs (dry-run → apply)

Dry-run (prints a Job bundle):

```bash
KUBECONFIG=tmp/kubeconfig-prod \./scripts/toils/tenant-offboarding/wipe-pv-data.sh --org-id <orgId>
```

Apply (destructive; requires explicit confirmation):

```bash
KUBECONFIG=tmp/kubeconfig-prod \./scripts/toils/tenant-offboarding/wipe-pv-data.sh --org-id <orgId> --apply --confirm <orgId>
```

### 3) Garage tenant S3 deletion (dry-run → apply)

Dry-run (prints the Job and its plan):

```bash
KUBECONFIG=tmp/kubeconfig-prod \./scripts/toils/tenant-offboarding/delete-garage-tenant-s3.sh --org-id <orgId>
```

Apply (destructive; requires explicit confirmation):

```bash
KUBECONFIG=tmp/kubeconfig-prod \./scripts/toils/tenant-offboarding/delete-garage-tenant-s3.sh --org-id <orgId> --apply --confirm <orgId>
```

### 4) Vault KV wipe (dry-run → apply)

Dry-run:

```bash
export VAULT_ADDR=<vault_url>
export VAULT_TOKEN=<token>./scripts/toils/tenant-offboarding/wipe-vault-tenant-kv.sh --org-id <orgId>
```

Apply (destructive; requires explicit confirmation):

```bash
export VAULT_ADDR=<vault_url>
export VAULT_TOKEN=<token>./scripts/toils/tenant-offboarding/wipe-vault-tenant-kv.sh --org-id <orgId> --apply --confirm <orgId>
```

