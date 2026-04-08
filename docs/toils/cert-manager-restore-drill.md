# Cert-manager restore drill

This toil documents the implemented cert-manager component recovery drill.

Goal:
- prove that the derived `Secret/cert-manager/step-ca-root-ca` can be regenerated from the Step CA source secrets in `step-system`
- prove that `ClusterIssuer/step-ca` still issues certificates after the regeneration path is exercised
- prove that cert-manager itself still serves its namespaced self-signed smoke after the drill

Related:
- Component README: `platform/gitops/components/certificates/cert-manager/README.md`
- Step CA component: `platform/gitops/components/certificates/step-ca/README.md`
- Alert/runbook: `docs/runbooks/certificates-smoke-alerts.md`
- Smoke manifests: `platform/gitops/components/certificates/smoke-tests/README.md`

## Recovery contract

Source of truth:
- `Secret/cert-manager/step-ca-root-ca` is a derived Secret, not the custody root.
- The custody root remains the Step CA source material in `step-system`, hydrated from Vault/ESO:
  - `Secret/step-system/step-ca-step-certificates-certs`
  - `Secret/step-system/step-ca-step-certificates-secrets`
  - `Secret/step-system/step-ca-step-certificates-ca-password`
- The cert-manager component itself owns GitOps-managed `ClusterIssuer` objects; it does not own tenant/platform `Certificate` CRs authored by other components/controllers.

Recovery expectation:
- If the live cert-manager trust secret is lost, regenerate it from the Step CA source secrets using the repo-shipped bootstrap logic.
- After regeneration, validate both:
  - Step CA issuance path via `CronJob/cert-smoke-step-ca-issuance`
  - cert-manager core self-signed path via `Job/cert-manager-certificate-smoke`

Excluded from backup scope:
- `CertificateRequest`, `Order`, and `Challenge` resources are ephemeral runtime artefacts and are not treated as backup material for this component.
- Platform/tenant endpoint `Certificate` resources are owned by separate GitOps components/controllers and should be restored through those components, not through this cert-manager drill.

## Recommended drill: scratch mode

Use the safe scratch drill routinely. It reconstructs the derived TLS secret in a temporary namespace and then runs the live Step CA issuance smoke.

```bash./scripts/ops/cert-manager-restore-drill.sh \
  --kubeconfig tmp/kubeconfig-prod \
  --mode scratch
```

What it does:
- verifies the Step CA source secrets exist and contain the required keys
- reads the live `cert-manager/step-ca-root-ca` certificate fingerprint
- reconstructs the same TLS secret into a temporary namespace using the repo bootstrap script
- verifies the reconstructed certificate fingerprint matches the live one
- runs a one-off `cert-smoke-step-ca-issuance` Job from the live CronJob

By default the temporary namespace is deleted after the drill.

## Optional drill: live replacement

Use this only during an explicit maintenance window or when you intentionally want to prove in-place recovery of `cert-manager/step-ca-root-ca`.

```bash./scripts/ops/cert-manager-restore-drill.sh \
  --kubeconfig tmp/kubeconfig-prod \
  --mode live \
  --confirm-live-secret-replacement yes \
  --live-secret-backup-file tmp/step-ca-root-ca-before-drill.yaml
```

Tradeoff:
- this fully exercises delete-and-regenerate on the live secret
- it briefly degrades `ClusterIssuer/step-ca` issuance while the secret is absent

## Post-drill cert-manager self-signed smoke

Run the component smoke after either drill mode:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n cert-manager delete job cert-manager-certificate-smoke --ignore-not-found
PATH="$(pwd)/tmp/tools:$PATH" kustomize build platform/gitops/components/certificates/cert-manager/tests \
  | sed 's#registry.example.internal/deploykube/validation-tools-core@sha256:babdd8ea44c3f169da4b55458061729329880fdf5c00194906d2dd6cdc655347#198.51.100.11:5010/deploykube/validation-tools-core@sha256:babdd8ea44c3f169da4b55458061729329880fdf5c00194906d2dd6cdc655347#g' \
  | KUBECONFIG=tmp/kubeconfig-prod kubectl apply -f -
KUBECONFIG=tmp/kubeconfig-prod kubectl -n cert-manager wait --for=condition=complete job/cert-manager-certificate-smoke --timeout=10m
KUBECONFIG=tmp/kubeconfig-prod kubectl -n cert-manager logs job/cert-manager-certificate-smoke
```

Why the mirror rewrite is required:
- direct workstation `kubectl apply -f -` bypasses the GitOps-side image rewrite to the local registry mirror on Proxmox
- this smoke image currently uses the same digest in both the canonical and local registry refs, so the manual rewrite only swaps the registry host
