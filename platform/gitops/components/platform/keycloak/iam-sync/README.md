# Keycloak IAM Sync

This component ships two GitOps-managed CronJobs:
- It also owns `ConfigMap/keycloak/istio-native-exit-script`, which both CronJobs mount so Istio-injected runs can terminate cleanly.

1. `keycloak-iam-sync` (hybrid redirect toggling):
- Reads `ConfigMap/keycloak/deploykube-deployment-config`.
- Evaluates `spec.iam.hybrid.healthCheck`.
- Applies fail-open switching on `primaryRealm` and `secondaryRealms` by toggling browser flow `identity-provider-redirector` requirement:
  - healthy threshold met: redirector `REQUIRED` (prefer upstream),
  - unhealthy/uncertain: redirector `DISABLED` (local login visible).
- Writes status to `ConfigMap/keycloak/keycloak-iam-sync-status`.

2. `keycloak-ldap-sync` (LDAP sync mode):
- Runs only when `spec.iam.upstream.type=ldap` and `spec.iam.upstream.ldap.operationMode=sync`.
- Triggers Keycloak LDAP full sync for `primaryRealm` and `secondaryRealms`.
- Writes status to `ConfigMap/keycloak/keycloak-ldap-sync-status`.

This component does not replace Keycloak bootstrap. Bootstrap remains responsible for creating/updating upstream providers, offline credential policy, and baseline handover groups.

## Mode Matrix E2E

- Live matrix runner: `tests/scripts/e2e-iam-modes-matrix.sh`
- Runbook: `docs/toils/keycloak-iam-mode-matrix-e2e.md`
- CI split:
  - PR quick sanity (`profile=quick`) for fast regression signal.
  - Nightly/manual full matrix (`profile=full`) for broader behavior coverage.
