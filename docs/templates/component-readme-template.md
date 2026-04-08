# Template: Component README (DeployKube)

Use this template for `platform/gitops/components/<area>/<component>/README.md`.

Rules:
- Keep TODO/open points out of the README; track them in `docs/component-issues/<component>.md` and link to the tracker from the README.
- Pass 1: do **not** assess Smoke/HA/Security/Backup; leave a one-liner: “Not assessed in Pass 1.”

## Skeleton

```md
# Introduction

## Architecture

## Subfolders

## Container Images / Artefacts

## Dependencies

## Communications With Other Services

### Kubernetes Service → Service calls

### External dependencies (Vault, Keycloak, PowerDNS)

### Mesh-level concerns (DestinationRules, mTLS exceptions)

## Initialization / Hydration

## Argo CD / Sync Order

## Operations (Runbooks, Toils)

## Customisation Knobs

## Oddities / Quirks

## TLS, Access & Credentials

## Dev → Prod

## Smoke Jobs / Test Coverage
Not assessed in Pass 1.

## HA Posture
Not assessed in Pass 1.

## Security
Not assessed in Pass 1.

## Backup and Restore
Not assessed in Pass 1.
```
