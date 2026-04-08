This component is fully overlay-driven: all deployable manifests (targets, CA, and VIP-specific NetworkPolicy) are deployment-specific.

The `base/` directory exists to satisfy the repo overlay layout contract (base + deploymentId overlays).
