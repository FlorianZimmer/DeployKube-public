# Idea: Crypto Agility Control Plane

Date: 2026-03-09  
Status: Draft

## Problem statement

DeployKube already treats PKI and secret-custody posture as deployment-level concerns, but the actual cryptographic choices are still scattered across controllers, manifests, third-party defaults, and bootstrap scripts.

Concrete repo examples today:

- `DeploymentConfig.spec.certificates.platformIngress.mode` selects the issuer path (`subCa|vault|acme|wildcard`), but it does not define certificate key algorithm, key size, signature profile, TLS protocol floor, or cipher policy.
- `DeploymentConfig.spec.secrets.rootOfTrust` selects where the seal boundary lives (`inCluster|external`) and which provider is used (`kmsShim|transit`), but not the cryptographic profile of that boundary.
- `tools/tenant-provisioner/internal/controllers/platform_ingress_certificates_controller.go` currently hard-codes platform ingress certificates to `RSA` with `2048`-bit keys.
- The contract placeholder manifests under `platform/gitops/components/certificates/ingress/base/*.yaml` mirror the same `RSA` + `2048` baseline.

That means a future requirement such as:

- “move external ingress certificates from RSA-2048 to ECDSA P-256,”
- “raise TLS minimums for public endpoints,”
- “switch a deployment from software-backed seal material to a hardware-backed profile,” or
- “carry a stricter regulated-environment crypto baseline without hand-editing component internals”

would currently require invasive per-component edits rather than one policy change with controlled rollout.

## Why now / drivers

- DeployKube explicitly targets regulated / high-paranoia environments, where crypto baselines can change because of compliance, customer procurement, incident response, or ecosystem deprecations.
- The repo already has the architectural shape needed for a central policy surface:
  - deployment-scoped knobs in `platform/gitops/deployments/<deploymentId>/config.yaml`
  - platform-owned controllers that translate high-level intent into cert-manager, Vault/OpenBao, and Gateway wiring
  - a KRM-native product direction (`platform.darksite.cloud`, `tenancy.darksite.cloud`)
- Current repo reality is only partially agile:
  - issuer selection is centralized,
  - but algorithm and key-size selection is not.
- Future cryptographic transitions are unlikely to be one-off:
  - RSA/ECDSA changes,
  - TLS version/cipher tightening,
  - trust-anchor rotation,
  - and eventual post-quantum experiments all benefit from a common control-plane model.

## Proposed approach (high-level)

Treat crypto agility as a **policy and rollout problem**, not just a bag of knobs.

### 1. Define a central crypto policy surface

Short-term repo-consistent path:

- Extend `DeploymentConfig` with a non-secret `spec.crypto` section for deployment-wide defaults and posture selection.

Long-term product path:

- Promote to a dedicated platform API such as `platform.darksite.cloud/v1alpha1 CryptoPolicy` or `CryptoProfile` once the contract is stable enough to justify its own CRD and controller surface.

The short-term rule should be:

- one deployment-level source of truth,
- no direct hand-tuning of crypto choices inside unrelated component overlays unless explicitly marked as an exception.

### 2. Model crypto as profiles plus targeted overrides

Avoid exposing dozens of low-level knobs as the primary UX. Prefer named profiles with a small number of explicit exceptions.

Illustrative shape:

```yaml
spec:
  crypto:
    profile: baseline-2026
    certificateClasses:
      publicIngress:
        keyAlgorithm: ECDSA
        keySize: 256
        signatureAlgorithm: ECDSAWithSHA256
        issuerClass: high-assurance
      privateIngress:
        keyAlgorithm: RSA
        keySize: 3072
    tls:
      publicIngress:
        minVersion: TLSV1_3
      internalGateway:
        minVersion: TLSV1_2
        allowLegacyClients: true
    rootOfTrust:
      keyProfile: external-soft
```

Important design intent:

- the product-facing contract should describe desired posture,
- platform controllers/adapters should translate that into component-specific fields,
- and unsupported combinations should fail validation early.

### 3. Split the policy by crypto surface

Do not force one setting to mean “everything everywhere”. At minimum, treat these as separate policy domains:

- **Certificate issuance**
  - key algorithm, key size, signature algorithm, lifetime/renewal bounds, issuer class
- **Transport TLS**
  - minimum protocol version, allowed cipher suites where relevant, curve preferences where supported
- **Trust distribution**
  - root/intermediate selection, allowed overlap windows during rotation, trust-bundle rollout semantics
- **Secrets/root-of-trust**
  - seal-provider assurance class, software vs external boundary, future PKCS#11-backed profiles

This keeps the model honest: cert-manager `Certificate.privateKey`, Gateway/Envoy TLS server policy, and OpenBao seal-provider posture are related, but not the same control.

### 4. Introduce capability-aware adapters, not raw global mutation

Many components will not support the same crypto choices in the same way.

Needed pattern:

- maintain a capability matrix per managed surface,
- have controllers/renderers map policy into supported fields,
- reject impossible combinations instead of silently degrading.

Examples:

- cert-manager `Certificate` supports `RSA`, `ECDSA`, and `Ed25519`, but issuer backends may not all accept the same combinations.
- Istio/Gateway TLS settings may support protocol and cipher controls on some listeners or API versions but not others.
- Some bootstrap-time secrets and third-party charts may require regeneration or restart sequencing rather than in-place mutation.

### 5. Treat migration as first-class

Crypto agility is only real if changes can be rolled out safely.

Required rollout concepts:

- profile versions (`baseline-2026`, `strict-2027`, `pq-experiment-1`)
- compatibility windows
- dual-publish / overlap periods for trust bundles
- staged certificate reissuance
- smoke tests that prove the active endpoint is serving the expected profile

This likely matters more than the config schema itself.

## What is already implemented (repo reality)

- `DeploymentConfig` already centralizes some adjacent posture choices:
  - `spec.certificates.platformIngress.mode`
  - `spec.certificates.tenants.mode`
  - `spec.secrets.rootOfTrust`
- Platform ingress certificate reconciliation is controller-owned in:
  - `tools/tenant-provisioner/internal/controllers/platform_ingress_certificates_controller.go`
- The current platform ingress certificate baseline is explicitly `RSA` + `2048` in both the controller and placeholder manifests under:
  - `platform/gitops/components/certificates/ingress/base/`
- DeployKube already has a split issuer posture:
  - Step CA for simpler internal/private issuance
  - Vault/OpenBao PKI for external high-assurance platform ingress
  - ACME as an alternative public-trust path
- OpenBao seal-provider posture is already deployment-selectable through `spec.secrets.rootOfTrust`, with future hardware-backed modes called out but not yet implemented.

## What is missing / required to make this real

- A single deployment-level crypto policy contract (`spec.crypto` or equivalent).
- Validation schema and controller logic that reject unsupported combinations.
- A component capability inventory, for example:
  - platform ingress certificates
  - tenant ingress certificates
  - Istio public gateway TLS
  - internal service TLS where explicitly managed
  - OpenBao seal-provider profiles
  - bootstrap-generated TLS assets
- Clear ownership rules:
  - which surfaces are centrally managed,
  - which are inherited from upstream charts,
  - which are intentionally out of scope.
- Functional validation:
  - repo-side checks for rendered intent,
  - runtime smokes that inspect real certificates and handshake properties,
  - evidence notes for profile migrations.
- Rollout mechanics for trust-bundle overlap and cert reissuance without service interruption.
- Documentation that distinguishes:
  - profile intent,
  - runtime capability,
  - and exception workflow.

## Risks / weaknesses

- **False sense of agility**: a central knob is useless if downstream components or clients cannot actually accept the new profile.
- **Breakage from compatibility drift**: tightening algorithms or TLS versions can strand old clients, operators, or bootstrap workflows.
- **Policy explosion**: exposing too many low-level knobs will turn this into a fragile tuning surface instead of a maintainable product contract.
- **Hidden one-time state**: some issuer or CA changes may require new intermediates, trust-bundle overlap, or manual ceremonies rather than a simple rolling update.
- **Third-party chart limits**: not every dependency cleanly exposes TLS or key-generation settings through values or CRDs.
- **PQC distraction risk**: “future-proofing” can become speculative if it is not anchored in real supported libraries and operator workflows.

## Alternatives considered

### Option A: Keep crypto choices embedded per component

This is effectively the current state.

- Pros: simple in the short term.
- Cons: slow to change, easy to miss surfaces, poor auditability, and not productizable.

### Option B: Only define hard-coded secure defaults, no agility surface

- Pros: less complexity and less chance of users choosing bad combinations.
- Cons: weak fit for regulated environments and future migrations; every change still becomes an implementation project.

### Option C: Expose raw knobs for every component directly

- Pros: maximum flexibility.
- Cons: likely unmaintainable, leaks third-party internals into the product API, and conflicts with the goal of a stable KRM-native platform contract.

### Option D: Profiles first, exceptions second

This looks like the best starting direction.

- Default to named profiles with strong validation.
- Allow a narrow override path only for surfaces the platform explicitly owns.

## Open questions

1. What is the primary business driver for v1:
   - regulated-baseline switching,
   - customer-by-customer crypto posture,
   - faster deprecation response,
   - or future post-quantum experimentation?
2. What is the first supported scope:
   - platform ingress certificates only,
   - platform ingress plus gateway TLS,
   - or also secret-plane/root-of-trust posture?
3. Should `spec.crypto` live in `DeploymentConfig` long-term, or should that be only the bootstrap path until a dedicated `CryptoPolicy` CRD exists?
4. Do we want raw algorithm names in the user-facing API, or only approved profiles with a tiny number of sanctioned overrides?
5. Which runtime checks do we require before declaring a profile migration successful:
   - certificate metadata inspection,
   - live TLS handshake scan,
   - client compatibility smoke,
   - trust-bundle overlap verification?
6. Which surfaces are explicitly out of scope for v1:
   - Istio mesh internals,
   - application-layer database encryption,
   - artifact signing / provenance,
   - tenant self-service crypto choices?
7. What is the rollback story if a stricter profile is applied and a critical client breaks?

## Promotion criteria (to `docs/design/**`)

Promote this idea once all of the following are true:

- The v1 scope is chosen and bounded.
- The repo has an agreed deployment-level contract (`DeploymentConfig.spec.crypto` or equivalent).
- At least one end-to-end prototype exists for a real managed surface, ideally:
  - changing platform ingress certificate key algorithm/profile without hand-editing component-specific manifests.
- Validation exists for both:
  - unsupported combinations at reconcile/render time, and
  - runtime proof of the effective certificate/TLS posture.
- The migration and rollback workflow is documented, including trust overlap and evidence expectations.
