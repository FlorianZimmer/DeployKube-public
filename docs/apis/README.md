# API Reference (Custom CRDs)

This folder contains the **API reference** for DeployKube’s product-owned Kubernetes APIs:
- CRDs under the canonical API domain `*.darksite.cloud`
- Their intended usage patterns, invariants, and examples

These docs are the **stable contract** view of our APIs. The runtime truth remains the CRD schemas + controller behavior in-repo.

## Structure

For each API group and version:

- `docs/apis/<area>/<group>/README.md` (group overview + ownership)
- `docs/apis/<area>/<group>/<version>/README.md` (version overview + kinds)
- `docs/apis/<area>/<group>/<version>/<Kind>.md` (kind reference + examples)

Examples:
- `docs/apis/data/data.darksite.cloud/README.md`
- `docs/apis/platform/platform.darksite.cloud/v1alpha1/DeploymentConfig.md`
- `docs/apis/tenancy/tenancy.darksite.cloud/v1alpha1/Tenant.md`

## Ownership rule

If we introduce a new CRD in `*.darksite.cloud`, we must add/extend the matching API reference docs under `docs/apis/**`.
