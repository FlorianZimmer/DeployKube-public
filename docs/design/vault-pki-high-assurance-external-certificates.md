# Vault PKI for High-Assurance External Certificates

Last updated: 2026-03-08  
Status: Implemented split-path baseline for platform ingress; Step CA remains the simpler internal/private issuer path

## Tracking

- Canonical tracker: `docs/component-issues/vault.md`

Related trackers and companion design docs:

- `docs/component-issues/cert-manager.md`
- `docs/component-issues/step-ca.md`
- `docs/design/certificates-and-pki-stack.md`
- `docs/design/multitenancy-networking.md`
- `docs/design/deployment-secrets-bundle.md`

## Purpose

Define the implemented PKI split for DeployKube:

- `cert-manager` remains the certificate control plane.
- `Vault PKI` is the issuer path for external client-facing certificates that require active revocation.
- `Step CA` remains an acceptable simpler issuer path for internal/private certificates.

## Why this direction changed

The platform does not need CRL/OCSP for every certificate. The requirement is narrower:

- external client-facing certificates need active revocation (`CRL`/`OCSP`)
- internal/private certificates do not currently require that assurance level

That makes a blanket migration away from Step CA unnecessary. The correct model is a split issuer posture.

## Current state

Today the repo implements:

- `cert-manager` as the cluster certificate control plane
- `ClusterIssuer/step-ca` for internal/private issuance
- `ClusterIssuer/vault-external` backed by `pki-ext` for external high-assurance platform ingress certificates
- CRL and OCSP publication on the Vault/OpenBao external PKI mount
- platform ingress certificate reconciliation via `platformIngress.mode=vault`
- platform-owned tenant wildcard certificates as the current tenant TLS shape

## Target state

### External high-assurance issuer path

`Vault PKI` is used only for external client-facing certificates that require:

- authoritative serial inventory
- active revocation
- CRL publication
- OCSP publication
- restore drills that preserve revocation truth

### Internal/private issuer path

Internal/private certificates remain on the simpler platform-managed issuer path.

Today that path is `Step CA` via cert-manager. That remains acceptable unless and until internal requirements change.

### Tenant TLS ownership

Tenant endpoint TLS remains platform-owned.

When tenant endpoints eventually move from wildcard to exact-host certificates, the controller can choose the correct issuer class per endpoint:

- external client-facing hostnames that require high assurance -> Vault PKI path
- internal/private hostnames -> simpler internal issuer path

Tenants still do not own raw `Issuer` or `Certificate` resources.

## Architecture boundaries

### Vault PKI owns

- external high-assurance CA mounts and roles
- serial inventory and revocation truth for that certificate class
- CRL and OCSP publication
- recovery semantics for revocation-capable PKI

### Step CA owns

- the simpler internal/private certificate path
- current internal CA trust distribution contract
- issuance flows that do not need CRL/OCSP

### cert-manager owns

- Kubernetes `Certificate` reconciliation
- secret materialization into namespaces
- renewal orchestration
- issuer selection per certificate surface

### Platform controllers own

- what hostnames are allowed
- which certificate objects exist
- which issuer class applies to each endpoint class

## Migration phases

### Phase 0: Architecture and tracking

- Record the split issuer model in design docs and component trackers.
- Stop describing Vault PKI as the default issuer target for every certificate class.

### Phase 1: Vault PKI foundation for external certificates

- Done:
  - Vault PKI mount `pki-ext` and issuance role for platform ingress.
  - Dedicated external intermediate under the existing root.
  - CRL and OCSP publication URLs on issued certificates.
  - Smoke coverage for issuance and revocation publication health.
- Remaining:
  - Define backup and restore scope for PKI metadata, serial inventory, and revocation records.

### Phase 2: cert-manager integration

- Done:
  - Added `ClusterIssuer/vault-external`.
  - Kept internal/private issuance on `ClusterIssuer/step-ca`.
  - Wired platform ingress certificates to select the correct issuer via `DeploymentConfig.spec.certificates.platformIngress.mode`.
- Remaining:
  - Extend endpoint classification beyond the current platform ingress scope where needed.

### Phase 3: endpoint adoption

- Done:
  - Migrated current platform ingress endpoints onto the Vault-backed issuer path on Proxmox.
- Remaining:
  - Keep trust distribution explicit and evidence-backed for any future endpoint classes.
  - Preserve revocation visibility during certificate replacement and disaster recovery with authoritative inventory and restore drills.

## Invariants

- High-assurance revocation is a CA-layer concern, not a cert-manager-only concern.
- External high-assurance certificates and internal/private certificates are separate classes.
- `cert-manager` remains the certificate control plane.
- Step CA is not being retired by this decision; it remains the current simpler internal/private issuer path.
- Tenant certificate issuance remains platform-owned.
