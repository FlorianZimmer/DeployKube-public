# Toil: ACME DNS-01 Troubleshooting

This runbook targets `spec.certificates.*=acme` deployments.

## Fast checks

1. Check controller-owned ACME issuer:
```bash
kubectl get clusterissuer acme -o yaml
```

2. Check ACME credential projection:
```bash
kubectl -n cert-manager get externalsecret
kubectl -n cert-manager get secret cert-manager-acme-dns01-credentials -o yaml
```

3. Check cert-manager issuance resources:
```bash
kubectl -n istio-system get certificate
kubectl -n cert-manager get challenges.acme.cert-manager.io,orders.acme.cert-manager.io
```

## Common failures

- `ClusterIssuer Not Ready`:
  - Verify `spec.certificates.acme.server` and `email` are set.
  - Verify solver settings match your DNS provider.

- `Challenge pending/failed`:
  - Verify DNS-01 credentials in Vault and projected secret keys.
  - Verify provider wiring:
    - `rfc2136`: authoritative DNS accepts RFC2136 updates.
    - `cloudflare`: API token has DNS edit rights for the zone.
    - `route53`: cert-manager has IAM permissions (ambient or static keys).
  - For external ACME, verify challenge record is publicly resolvable.

- `Tenant certs pending with acme mode`:
  - Verify `spec.certificates.tenants.mode=acme`.
  - Verify `ClusterIssuer/<acmeName>` exists and is Ready.

## Breakglass rollback

If ACME is degraded, rollback by setting:

- `spec.certificates.platformIngress.mode=subCa`
- `spec.certificates.tenants.mode=subCa`

Then commit and let Argo reconcile. Re-run smoke jobs.
