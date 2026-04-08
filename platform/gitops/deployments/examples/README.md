# DeploymentConfig examples

This folder contains **minimal, non-secret** `DeploymentConfig` examples for understanding the contract and validating changes locally.

Notes:
- These examples are not referenced by bootstrap Stage 0/1 or Argo CD.
- Keep them plaintext (no credentials, tokens, or private keys).
- Certificate mode examples intentionally show explicit defaults (`subCa`) under `spec.certificates` for clarity.
- Optional knobs exist beyond what these minimal examples show; contract truth is `platform/gitops/deployments/schema.json` and `docs/design/deployment-config-contract.md`.

Validation:

```bash./tests/scripts/validate-deployment-config.sh
```

Provisioning bundle examples:
- `provisioning-v0/` contains multi-document "single YAML" examples that compose `DeploymentConfig` + `Tenant` + `TenantProject`.
- Validate them with:

```bash./tests/scripts/validate-provisioning-bundle-examples.sh
```
