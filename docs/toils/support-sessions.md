# Toil: Support sessions (Tier S multitenancy)

Support sessions are DeployKube’s **preferred** mechanism for time-bound troubleshooting access without turning breakglass into day-to-day operations.

Design: `docs/design/multitenancy-lifecycle-and-data-deletion.md#9-support-sessions-breakglass-hooks-without-breaking-gitops`

## Contract (Git surface)

Support sessions are Git folders under tenant intent:

```
platform/gitops/tenants/<orgId>/support-sessions/<sessionId>/
  metadata.yaml
  kustomization.yaml
  rbac/rolebinding-*.yaml
  # netpol/*.yaml (optional)
```

Activation is explicit: a session is only applied when referenced from the tenant project env kustomization:

```
platform/gitops/tenants/<orgId>/projects/<projectId>/namespaces/<env>/kustomization.yaml
```

Example (from the env dir, reference the org-level support session folder):

```yaml
resources:
  -../../../../support-sessions/<sessionId>
```

Template: `platform/gitops/tenants/_templates/support-session/`

## Access levels

The cluster ships bounded support ClusterRoles:
- `tenant-support-l1` (read-only triage)
- `tenant-support-l2` (debug: includes exec/portforward/ephemeralcontainers)
- `tenant-support-l3` (debug + read secrets)

These are intended to be bound to platform groups (Keycloak):
- `dk-support` (typical support sessions)
- `dk-security-ops` (rare; for data-export-like situations)

## TTL enforcement (required)

Two controls exist by contract:

1) **Pre-merge TTL gate** (CI)
   - Script: `tests/scripts/validate-support-sessions.sh`
   - Default max TTL: `72h` (override: `DK_SUPPORT_SESSION_MAX_TTL_HOURS=<n>`)

2) **Git-driven cleanup**
   - Scheduled PR (GitHub): `.github/workflows/support-session-cleanup.yml`
   - Manual cleanup (local): `scripts/toils/support-sessions/cleanup-expired.sh`

Cleanup must happen in Git (not just in-cluster), otherwise Argo will re-apply expired resources.
