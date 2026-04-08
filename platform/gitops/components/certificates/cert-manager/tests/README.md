# cert-manager Smoke Tests

## Run

```sh
kubectl apply -k platform/gitops/components/certificates/cert-manager/tests
kubectl -n cert-manager wait --for=condition=complete job/cert-manager-certificate-smoke --timeout=10m
kubectl -n cert-manager logs job/cert-manager-certificate-smoke
```

If re-running the same manifest, delete the completed Job first:

```sh
kubectl -n cert-manager delete job cert-manager-certificate-smoke --ignore-not-found
```

On Proxmox, a direct `kubectl apply -k...` uses the manifest exactly as written and therefore bypasses the GitOps-side `PlatformApps.globalKustomizeImages` rewrite to the local registry mirror. For manual runtime validation there, either:

```sh
kustomize build platform/gitops/components/certificates/cert-manager/tests \
  | sed 's#registry.example.internal/deploykube/validation-tools-core@sha256:babdd8ea44c3f169da4b55458061729329880fdf5c00194906d2dd6cdc655347#198.51.100.11:5010/deploykube/validation-tools-core@sha256:babdd8ea44c3f169da4b55458061729329880fdf5c00194906d2dd6cdc655347#g' \
  | KUBECONFIG=tmp/kubeconfig-prod kubectl apply -f -
```

or create the Job from an Argo-rendered manifest path that already includes the mirror rewrite.

The current `validation-tools-core` push uses the same manifest-list digest in the local registry and the canonical reference, so the same digest works in both places.

For the broader cert-manager recovery drill that pairs this self-signed smoke with Step CA trust regeneration validation, see `docs/toils/cert-manager-restore-drill.md`.

## What it does

- Creates a namespaced `Issuer` (`selfSigned`) and a `Certificate`.
- Waits for `Certificate/Ready=True`.
- Verifies the resulting `Secret` contains `tls.crt` and `tls.key`.
- Cleans up the smoke resources on success (so it is repeatable).
- Runs with explicit non-root security context, bounded resources, and a digest-pinned `validation-tools-core` image.
