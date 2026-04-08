# `bootstrap-tools` image

DeployKube uses a small “bootstrap tools” container image for hook Jobs/CronJobs that need a consistent toolchain (`kubectl`, `curl`, `jq`, `sops`, `openssl`, `psql`, …).

## Why this needs publishing

- On **kind/orbstack**, Stage 0 builds the image locally and loads it into the kind nodes.
- On **Proxmox/Talos**, nodes must **pull** the image from a registry. There is no kind-style side-loading.

The canonical image reference used by this repo is:

- `registry.example.internal/deploykube/bootstrap-tools:1.4`

Notable tools included (non-exhaustive):
- `rclone` (required by `backup-system` S3 mirror; avoid runtime `apk add` so the backup plane does not depend on internet access)

## Publish

1) Log in to the canonical registry:

```sh
docker login registry.example.internal
```

2) Build + push multi-arch:

```sh./shared/scripts/publish-bootstrap-tools-image.sh
```

Notes:
- The image must be available under the canonical domain used by manifests (`registry.example.internal`).
- For maximum stability, pin manifests to an image digest after publishing.
