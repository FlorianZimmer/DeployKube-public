# `validation-tools-core` image

DeployKube uses a narrow validation utility image for smoke jobs that only need Kubernetes/TLS/HTTP tooling (`kubectl`, `curl`, `jq`, `openssl`, `bash`).

It exists to keep low-surface validation jobs off the broader `bootstrap-tools` image when they do not need Java, Keycloak tooling, backup clients, database clients, or other unrelated dependencies.

The canonical image reference used by this repo is:

- `registry.example.internal/deploykube/validation-tools-core:0.1.0`

Current first consumers:
- `platform/gitops/components/certificates/cert-manager/tests`
- `platform/gitops/components/certificates/smoke-tests`

## Publish

1) Log in to the canonical registry:

```sh
docker login registry.example.internal
```

2) Build + push multi-arch:

```sh./shared/scripts/publish-validation-tools-core-image.sh
```

Notes:
- Keep this image intentionally small; if a job needs database, backup, or IdP tooling, use or create a different capability-scoped image instead of extending this one indiscriminately.
- For kind/orbstack development, build and load it locally with `./shared/scripts/build-validation-tools-core-image.sh`.
