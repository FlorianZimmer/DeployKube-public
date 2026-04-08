# Runbook: certificates smoke alerts (Step CA trust + issuance path)

This runbook covers:
- `StepCARootSecretMissing`
- `CertificateStepCAIssuanceSmokeCronJobStale`
- `CertificateStepCAIssuanceSmokeJobFailed`

These alerts protect the cert-manager dependency on the Step CA trust anchor:
- `Secret/cert-manager/step-ca-root-ca`
- `ClusterIssuer/step-ca`
- `CronJob/cert-manager/cert-smoke-step-ca-issuance`

Related:
- Design: `docs/design/certificates-and-pki-stack.md`
- cert-manager component: `platform/gitops/components/certificates/cert-manager/README.md`
- Step CA component: `platform/gitops/components/certificates/step-ca/README.md`
- Cert smokes: `platform/gitops/components/certificates/smoke-tests/README.md`

## What this means

### `StepCARootSecretMissing` (critical)

Meaning:
- `cert-manager/step-ca-root-ca` is absent.

Impact:
- `ClusterIssuer/step-ca` cannot issue or renew certificates.
- Existing Secrets continue to work until expiry, but new issuance and renewals are degraded.

### `CertificateStepCAIssuanceSmokeCronJobStale` (warning)

Meaning:
- `CronJob/cert-manager/cert-smoke-step-ca-issuance` has not reported a recent successful run.

Impact:
- The issuance path may still be healthy, but continuous assurance is missing.

### `CertificateStepCAIssuanceSmokeJobFailed` (critical)

Meaning:
- A recent `cert-smoke-step-ca-issuance-*` Job failed.

Impact:
- The cluster likely cannot issue certificates through `ClusterIssuer/step-ca`, or the trust anchor path is broken.

## Source of truth and lifecycle

`cert-manager/step-ca-root-ca` is a derived Secret.

Source of truth:
- Step CA root material is hydrated into `step-system` Secrets from Vault/ESO.
- `Application/argocd/certificates-step-ca-bootstrap` runs `Job/step-ca-root-secret-bootstrap`, which copies the root certificate and decrypted key into `Secret/cert-manager/step-ca-root-ca`.

Expected lifecycle:
- Initial bootstrap: sync `certificates-step-ca-bootstrap`
- Step CA root/key rotation or recovery: restore the Step CA source secrets first, then rerun `certificates-step-ca-bootstrap`
- Post-recovery validation: rerun the Step CA issuance smoke

## Degraded mode

Defined degraded behavior:
- `ClusterIssuer/selfsigned-bootstrap` remains available for cert-manager smoke/breakglass validation only.
- It is **not** the replacement issuer for normal platform or tenant endpoint TLS.
- If `step-ca-root-ca` or `ClusterIssuer/step-ca` is broken, treat endpoint issuance/renewal as degraded until the Step CA trust path is restored.

## Quick triage

1. Verify the alerting hooks are loaded:

```bash
kubectl -n mimir port-forward svc/mimir-ruler 18080:8080
curl -sS -H 'X-Scope-OrgID: platform' http://127.0.0.1:18080/prometheus/api/v1/rules \
  | jq -r '.data.groups[].name' | rg -n '^certificates\\.stepca\\.health$'
```

2. Check the trust secret and issuer:

```bash
kubectl -n cert-manager get secret step-ca-root-ca -o yaml || true
kubectl get clusterissuer step-ca -o yaml || true
```

3. Check recent issuance smokes:

```bash
kubectl -n cert-manager get cronjob cert-smoke-step-ca-issuance
kubectl -n cert-manager get jobs --sort-by=.metadata.creationTimestamp | tail -n 20
job="$(kubectl -n cert-manager get jobs -o name | rg 'cert-smoke-step-ca-issuance-' | tail -n 1 | sed 's#job.batch/##')"
kubectl -n cert-manager logs "job/${job}" || true
```

4. Check the upstream Step CA source secrets:

```bash
kubectl -n step-system get secret step-ca-step-certificates-certs -o yaml | rg -n 'root_ca\\.crt' || true
kubectl -n step-system get secret step-ca-step-certificates-secrets -o yaml | rg -n 'root_ca_key' || true
kubectl -n step-system get secret step-ca-step-certificates-ca-password -o yaml | rg -n 'password' || true
```

## Recovery

### Case A: `cert-manager/step-ca-root-ca` is missing but Step CA source secrets exist

Rerun the bootstrap app that publishes the derived Secret:

```bash
kubectl -n argocd annotate application certificates-step-ca-bootstrap argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application certificates-step-ca-bootstrap --type merge -p '{"operation":{"sync":{"prune":true}}}'

kubectl -n argocd get application certificates-step-ca-bootstrap \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'

kubectl -n step-system get jobs --sort-by=.metadata.creationTimestamp | tail -n 10
kubectl -n step-system logs job/step-ca-root-secret-bootstrap || true
```

Then validate:

```bash
kubectl -n cert-manager get secret step-ca-root-ca
kubectl get clusterissuer step-ca -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl -n cert-manager create job --from=cronjob/cert-smoke-step-ca-issuance cert-smoke-step-ca-issuance-manual-$(date +%s)
```

### Case B: Step CA source secrets are missing or incomplete in `step-system`

The cert-manager Secret is not the root problem. Restore the Step CA source first:

1. Check ESO / Vault / seed status:

```bash
kubectl -n step-system get externalsecret
kubectl -n argocd get application certificates-step-ca-seed certificates-step-ca-bootstrap certificates-step-ca
```

2. If the Vault seed must be replayed, rerun `certificates-step-ca-seed`, then rerun `certificates-step-ca-bootstrap`.
3. After the source is restored, rerun the issuance smoke as above.

## When to escalate

Escalate as a platform incident if:
- `ClusterIssuer/step-ca` stays not ready after the bootstrap rerun
- the Step CA source secrets are missing in `step-system`
- issuance smoke still fails after the root Secret is restored
- a large set of near-expiry endpoint certificates now depend on the broken issuer path
