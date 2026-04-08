# Keycloak OIDC trust projections (ESO)

This component contains External Secrets Operator projections that depend on the Step CA / Keycloak OIDC trust bundle being published into Vault at `secret/keycloak/oidc-ca`.

Bootstrap ordering:
- `certificates-step-ca-bootstrap` must complete first (it writes `secret/keycloak/oidc-ca`).
- Then these `ExternalSecret` resources can sync and hydrate the in-cluster `Secret/*-oidc-ca` bundles and other OIDC consumers that embed the CA.

