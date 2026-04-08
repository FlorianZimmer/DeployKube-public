# Provisioning Contract v0

Last updated: 2026-03-14
Status: Implemented contract baseline (examples + validation); no end-to-end reconciler yet

Purpose:
- define the first repo-truth answer to "single YAML provisioning" without inventing a parallel bootstrap-only schema
- keep the contract KRM-native and aligned with the existing platform APIs

## Tracking

- Canonical tracker: `docs/component-issues/cloud-productization-roadmap.md`

## Decision

The `v0` provisioning contract is a **multi-document YAML bundle** composed of existing KRM APIs:

- exactly one `platform.darksite.cloud/v1alpha1 DeploymentConfig`
- one or more `tenancy.darksite.cloud/v1alpha1 Tenant`
- one or more `tenancy.darksite.cloud/v1alpha1 TenantProject`

This is intentionally a **bundle contract**, not a new umbrella CRD.

Rationale:
- reuses the APIs the platform already owns and reconciles
- avoids a second, drift-prone "bootstrap schema" that says the same thing differently
- stays compatible with the long-term KRM-native UI/controller direction

## What v0 means

Implemented now:
- documented bundle shape for "small deployment + first tenant"
- concrete example bundles under `platform/gitops/deployments/examples/provisioning-v0/`
- repo validation for bundle-level invariants via `./tests/scripts/validate-provisioning-bundle-examples.sh`

Not implemented yet:
- a single controller or Stage 0/1 entrypoint that consumes this bundle end to end
- hardware inventory / server-pool / workload-cluster provisioning objects
- secret-bearing inputs inside the bundle (bootstrap secrets stay in the Deployment Secrets Bundle path)

## Bundle invariants

The repo currently validates these invariants for the example bundles:

- only these Kinds are allowed: `DeploymentConfig`, `Tenant`, `TenantProject`
- exactly one `DeploymentConfig` must exist
- at least one `Tenant` must exist
- at least one `TenantProject` must exist
- `DeploymentConfig.metadata.name == DeploymentConfig.spec.deploymentId`
- every `TenantProject.spec.tenantRef.name` must refer to a `Tenant` in the same bundle
- every `TenantProject.spec.environments[]` must include the bundle deployment environment (`DeploymentConfig.spec.environmentId`)

The underlying per-object schemas remain their existing sources of truth:
- `platform/gitops/deployments/schema.json`
- `platform/gitops/components/platform/tenant-provisioner/base/tenancy.darksite.cloud_tenants.yaml`
- `platform/gitops/components/platform/tenant-provisioner/base/tenancy.darksite.cloud_tenantprojects.yaml`

## Example bundles

- `platform/gitops/deployments/examples/provisioning-v0/minimal-dev-first-tenant.yaml`
- `platform/gitops/deployments/examples/provisioning-v0/minimal-prod-first-tenant.yaml`

These examples are:
- plaintext only
- non-secret
- illustrative contract examples, not live bootstrap inputs

## Validation

Run:

```bash./tests/scripts/validate-deployment-config.sh./tests/scripts/validate-provisioning-bundle-examples.sh
```

## Roadmap relationship

This closes the roadmap item "Provisioning schema v0: publish a validated single YAML schema + examples" at the contract level.

The remaining roadmap gap is narrower:
- turn this contract into an end-to-end provisioning workflow/controller without reintroducing repo-side YAML rendering
