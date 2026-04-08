# Staging Environment Bundle

Placeholder environment for staging deployments.

## Status

**Not yet active** - This environment is scaffolded for future use.

## Configuration

- Inherits from `../../base` (environment-neutral)
- No staging-specific wiring yet defined
- When activated, add a staging `platform-apps-controller` overlay and any staging-only patches.

## Activation Steps

1. Create staging overlays (`overlays/staging`) for components that need staging-specific config
2. Add a staging `platform-apps-controller` overlay (`components/platform/platform-apps-controller/overlays/<deploymentId>`)
3. Patch `Application/platform-platform-apps-controller` in this environment to select that overlay path
4. Update DNS/certificates for staging domains
