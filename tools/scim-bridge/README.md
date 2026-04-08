# SCIM Bridge

Minimal SCIM v2 bridge for DeployKube Keycloak.

## What it does

- Exposes SCIM endpoints for Users/Groups at `/scim/v2`.
- Translates SCIM CRUD + PATCH requests into Keycloak Admin API calls.
- Uses a Keycloak service-account client credential (`client_credentials`) for admin API auth.

## Required environment variables

- `SCIM_BEARER_TOKEN`
- `KEYCLOAK_CLIENT_ID`
- `KEYCLOAK_CLIENT_SECRET`

## Optional environment variables

- `SCIM_BRIDGE_LISTEN_ADDR` (default `:8080`)
- `KEYCLOAK_URL` (default `http://keycloak.keycloak.svc.cluster.local:8080`)
- `KEYCLOAK_REALM` (default `deploykube-admin`)
- `KEYCLOAK_TOKEN_REALM` (default matches `KEYCLOAK_REALM`)
- `SCIM_BRIDGE_HTTP_TIMEOUT_SECONDS` (default `10`)

## Run locally

```bash
go run./cmd/scim-bridge
```

## Tests

```bash
go test./...
```

## Image build/publish

```bash./shared/scripts/build-scim-bridge-image.sh./shared/scripts/publish-scim-bridge-image.sh
```
