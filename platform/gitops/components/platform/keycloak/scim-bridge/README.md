# Keycloak SCIM Bridge

This component hosts a minimal SCIM v2 bridge that translates inbound SCIM Users/Groups calls into Keycloak Admin API operations.

## Scope

- Supports SCIM Users and Groups CRUD.
- Supports SCIM PATCH for:
  - users (`active`, `userName`, `name`, `emails`),
  - groups (`displayName`, `members` add/replace/remove).
- Uses a dedicated Keycloak service-account client (`deploykube-scim-bridge`) reconciled by `platform-keycloak-bootstrap`.

## Secrets

- `Secret/keycloak-scim-bridge-client` (managed by bootstrap):
  - `clientId`, `clientSecret`, `realm`, `tokenRealm`
- `Secret/keycloak-upstream-scim` (managed by ESO):
  - `token` (bearer token accepted by bridge)

## Security posture

- Token-authenticated SCIM endpoints only.
- Read-only root filesystem and dropped Linux capabilities.
- NetworkPolicy restricts ingress to mesh/system namespaces and egress to Keycloak + DNS.
- Canonical packaged image: `registry.example.internal/deploykube/scim-bridge:0.1.0` (mirrored to the local Proxmox registry for validation/runtime rewrites).

## Runtime URL

- Cluster-internal: `http://keycloak-scim-bridge.keycloak.svc.cluster.local:8080/scim/v2`
