# `scim-bridge` image

Minimal SCIM v2 bridge image for the optional Keycloak upstream-provisioning component.

Canonical ref:

- `registry.example.internal/deploykube/scim-bridge:0.1.0`

Common tasks:

- Publish to the canonical registry: `./shared/scripts/publish-scim-bridge-image.sh`
- Build and load into kind: `./shared/scripts/build-scim-bridge-image.sh`

For Proxmox validation and mirrored scan paths, rewrite the canonical ref to the local registry mirror (`198.51.100.11:5010/deploykube/scim-bridge:0.1.0`).
