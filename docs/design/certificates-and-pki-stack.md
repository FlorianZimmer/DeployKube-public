# Certificates and PKI Stack Design

Status: Design + implementation

## Tracking

- Canonical tracker: `docs/component-issues/cert-manager.md`
- Related trackers:
  - `docs/component-issues/step-ca.md`
  - `docs/component-issues/certificates-ingress.md`
- Related docs:
  - `docs/design/deployment-secrets-bundle.md`
  - `docs/design/cluster-access-contract.md`
  - `docs/design/multitenancy-networking.md`
  - `docs/design/vault-pki-high-assurance-external-certificates.md`

## Purpose

Define the platform PKI chain from issuer to certificate consumers, including cert-manager, the current Step CA implementation, the implemented Vault PKI path for high-assurance external certificates, and ingress certificate delivery contracts.

## Scope

In scope:
- cert-manager controller posture and certificate lifecycle baseline.
- current Step CA implementation and root distribution contract.
- implemented Vault PKI architecture for high-assurance external certificates.
- Ingress certificate ownership and hostname alignment contracts.

Out of scope:
- Tenant-specific ingress productization details (see `multitenancy-networking.md`).
- Application-specific certificate usage patterns.

## PKI topology

1. Current implementation:
- Step CA currently provides the simpler internal/private issuing authority for platform certificates.

2. External high-assurance implementation:
- Vault PKI is the issuer path only for external client-facing certificates that require high-assurance revocation, CRL, and OCSP.

3. Certificate control plane:
- cert-manager reconciles `Certificate` resources and associated issuance flow.

4. Ingress consumers:
- Ingress-facing certificates are platform-owned and aligned with deployment config DNS contracts.

The long-term architecture is a split model:

- `cert-manager` stays in place
- `Step CA` remains acceptable for internal/private certificates
- `Vault PKI` is added for external high-assurance certificates
- `ACME` remains the preferred path for publicly trusted certificates

## Deployment Modes (Ingress TLS)

DeploymentConfig controls certificate modes under `spec.certificates`.

- `platformIngress.mode=subCa`
  - Current implementation: platform endpoints use cert-manager `Certificate` objects with `ClusterIssuer/step-ca`.
  - Target direction: `subCa` remains the simpler platform-managed private issuer mode for internal/private endpoints.
- `platformIngress.mode=vault`
  - Current implementation: platform endpoints use cert-manager `Certificate` objects with `ClusterIssuer/vault-external`.
  - The Vault/OpenBao `pki-ext` mount publishes CA Issuers, CRL, and OCSP URLs for these high-assurance external certificates.
  - Gateway SNI smoke treats this as a strict-CA mode and verifies presented platform endpoint certificates against the shared cert-manager root CA bundle.
- `platformIngress.mode=acme`
  - Platform endpoints use cert-manager `Certificate` objects with a controller-owned ACME `ClusterIssuer`.
  - ACME directory URL is configurable, so this supports self-hosted ACME servers and external endpoints.
  - DNS-01 provider wiring supports `rfc2136`, `cloudflare`, and `route53` (with route53 ambient-credential or Vault-projected static-credential modes).
- `platformIngress.mode=wildcard`
  - Platform endpoints consume one BYO wildcard TLS secret (projected from Vault via ExternalSecret).
  - Public Gateway listeners reference the shared wildcard secret.

Gateway SNI smoke verification contract:
- `subCa` and `vault` verify the full presented gateway chain against `cert-manager/step-ca-root-ca`.
- `wildcard` and `acme` use the optional `platformIngress.wildcard.caBundleSecretName` / `platformIngress.wildcard.caBundleProperty` override when configured; otherwise they still require a valid handshake + hostname match but do not hard-fail on chain verification.

DeploymentConfig singleton contract for certificate smokes:
- The certificate smoke jobs read `deploymentconfigs.platform.darksite.cloud` and require exactly one object.
- Zero or multiple `DeploymentConfig` objects are treated as a hard failure so platform certificate mode selection never becomes ambiguous.

## Option A Tenant Rule

Option A is the enforced contract in this repo:

- Tenant workload hostnames keep their existing shape: `*.${orgId}.workloads.${baseDomain}`.
- A single platform wildcard (`*.${baseDomain}`) does not cover tenant hostnames.
- Therefore tenant workload certificates remain per-tenant and mode-controlled via:
  - `spec.certificates.tenants.mode=subCa|acme`

`tenants.mode=wildcard` is intentionally unsupported in Option A.

## Tenant endpoint TLS ownership

Tenant-facing endpoint TLS stays platform-owned.

Current implementation:
- Tier S tenant gateways terminate TLS with a controller-owned wildcard certificate per org in `istio-system`.
- Tenants attach `HTTPRoute` objects to the tenant gateway, but do not author `Certificate`, `Issuer`, or `ClusterIssuer` resources.

Target end-state:
- Retire wildcard tenant certificates in favor of controller-owned exact-host certificates.
- The higher-level tenant intent API remains the source of truth for approved hostnames.
- Platform controllers reconcile exact DNS records, exact `Certificate` resources, and gateway listener wiring.
- Tenant repos still do not gain raw cert-manager self-service; cert-manager remains an internal platform dependency behind controller-owned APIs.
- External client-facing tenant hostnames that need active revocation should eventually use the Vault-backed high-assurance issuer path; internal/private hostnames can stay on the simpler issuer path.

## Ownership boundaries

- cert-manager, Vault PKI, and Step CA are platform components; tenants do not own issuer control-plane resources.
- Ingress certificate objects for platform endpoints are platform-owned (controller/GitOps-managed).
- Tenant endpoint certificates are also platform-owned; tenant repos express hostnames/routes, not raw cert-manager resources.
- Access-plane restrictions apply to admission/webhook and CRD resources used by PKI controllers.

## Implementation map (repo)

- cert-manager component: `platform/gitops/components/certificates/cert-manager/`
- step-ca component: `platform/gitops/components/certificates/step-ca/`
- high-assurance external CA design: `docs/design/vault-pki-high-assurance-external-certificates.md`
- ingress certificate component: `platform/gitops/components/certificates/ingress/`
- smoke jobs: `platform/gitops/components/certificates/smoke-tests/`

## Invariants

- Certificate hostnames must align with deployment DNS contract.
- Certificate mode must be sourced from `DeploymentConfig` only (no repo-side renderer path).
- Platform wildcard mode must project TLS material via Vault/ESO; plaintext key material is not committed.
- cert-manager webhook/cainjector paths must remain functional under current mesh/admission posture.
- Root trust distribution to dependent workloads (for OIDC and internal TLS) must remain consistent.
- High-assurance revocation is a CA-layer concern; cert-manager alone is insufficient without an authoritative CA that supports revocation publication and recovery semantics for the affected external certificate class.

## Validation and evidence

Primary signals:
- certificate smoke jobs pass (`issuance`, `readiness`, and SNI checks).
- ingress endpoints present expected certificates.
- evidence notes capture both repo contract checks and runtime verification.
