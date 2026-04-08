# Guide: Certificate Modes (Option A)

This guide describes how DeployKube selects ingress certificate behavior through `DeploymentConfig.spec.certificates`.

## Mode model

Two surfaces are configured independently:

- `spec.certificates.platformIngress.mode`: `subCa|acme|wildcard`
- `spec.certificates.tenants.mode`: `subCa|acme`

Option A contract:

- Platform wildcard certs cover platform hostnames (`*.${baseDomain}`).
- Tenant workload hostnames remain per-tenant (`*.${orgId}.workloads.${baseDomain}`), so tenants do not support `wildcard` mode.

## Quick selection matrix

- Use `subCa` when:
  - You want internal Step CA issuance and existing trust flow.
- Use `acme` when:
  - You need ACME issuance for platform and/or tenant certs.
  - You can satisfy DNS-01 challenge requirements.
- Use `wildcard` (platformIngress only) when:
  - You already own a wildcard keypair and want one secret for all platform endpoints.

## Required config by mode

`subCa`:
- No additional fields required (defaults apply).

`acme`:
- `spec.certificates.acme.server`
- `spec.certificates.acme.email`
- Optional for self-hosted ACME endpoints:
  - `spec.certificates.acme.caBundle` (base64-encoded PEM trust bundle used by cert-manager)
- `spec.certificates.acme.solver.provider` (`rfc2136|cloudflare|route53`)
- Provider-specific requirements:
  - `rfc2136`:
    - `spec.certificates.acme.solver.rfc2136.nameServer`
    - `spec.certificates.acme.solver.rfc2136.tsigKeyName`
    - `spec.certificates.acme.credentials.vaultPath`
  - `cloudflare`:
    - `spec.certificates.acme.credentials.vaultPath` (API token source)
  - `route53`:
    - `spec.certificates.acme.solver.route53.region`
    - Optional static credentials: `spec.certificates.acme.credentials.vaultPath`
    - If no `vaultPath` is set, route53 uses ambient credentials on cert-manager.

`wildcard` (platform only):
- `spec.certificates.platformIngress.wildcard.vaultPath`
- Recommended for strict chain smoke verification:
  - `spec.certificates.platformIngress.wildcard.caBundleSecretName`
  - `spec.certificates.platformIngress.wildcard.caBundleVaultPath`

## Safe cutover sequence

1. Update `platform/gitops/deployments/<deploymentId>/config.yaml` with target mode fields.
2. Ensure required Vault paths exist for the mode.
3. Commit + seed Forgejo + let Argo reconcile.
4. Run certificate smoke jobs:
   - `cert-smoke-step-ca-issuance` (auto-skips when subCa is not used)
   - `cert-smoke-ingress-readiness`
   - `cert-smoke-gateway-sni`
5. Record evidence under `docs/evidence/YYYY-MM-DD-<topic>.md`.

## Mode Matrix E2E

Use the live matrix runner to validate all three platform modes on a real cluster:

- `tests/scripts/e2e-cert-modes-matrix.sh`
- runbook: `docs/toils/certificates-mode-matrix-e2e.md`

This script reuses existing certificate smoke CronJobs, switches `DeploymentConfig.spec.certificates` between modes, and restores the original config at the end.

## Notes for external ACME endpoints

External ACME (for example Let's Encrypt) only works if challenge DNS is resolvable by the external CA. For private-only internal zones, use self-hosted ACME or provide public delegation for challenge records.
