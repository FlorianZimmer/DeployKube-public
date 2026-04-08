# Toil: Platform Wildcard (BYO) Certificate

This runbook targets `spec.certificates.platformIngress.mode=wildcard`.

## Contract summary

- Wildcard mode applies to platform ingress only.
- Tenant workload wildcard certs remain per-tenant (`subCa|acme`).

## Required inputs

`DeploymentConfig`:

- `spec.certificates.platformIngress.mode=wildcard`
- `spec.certificates.platformIngress.wildcard.vaultPath`

Recommended:

- `spec.certificates.platformIngress.wildcard.caBundleSecretName`
- `spec.certificates.platformIngress.wildcard.caBundleVaultPath`

Vault path must contain keypair properties mapped by:

- `tlsCertProperty` (default `tls.crt`)
- `tlsKeyProperty` (default `tls.key`)

## Verification

1. Check projected wildcard secret:
```bash
kubectl -n istio-system get secret platform-wildcard-tls -o yaml
```

2. Check Gateway listeners use the wildcard secret:
```bash
kubectl -n istio-system get gateway public-gateway -o yaml
```

3. Run smoke jobs:
```bash
kubectl -n cert-manager create job --from=cronjob/cert-smoke-ingress-readiness wildcard-readiness-$(date +%s)
kubectl -n cert-manager create job --from=cronjob/cert-smoke-gateway-sni wildcard-sni-$(date +%s)
```

## Rotation flow

1. Update wildcard cert/key in Vault at configured `vaultPath`.
2. Wait for ExternalSecret refresh.
3. Confirm updated secret data timestamps in `istio-system`.
4. Re-run SNI smoke job and spot-check endpoint TLS.
