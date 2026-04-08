# Keycloak IAM Modes (DeploymentConfig-driven)

## Tracking

- Canonical tracker: `docs/component-issues/keycloak.md`

## Scope

DeployKube keeps **Keycloak as the only issuer** for platform consumers (Kubernetes OIDC, Argo CD, Forgejo, Vault, Grafana). `spec.iam` in `DeploymentConfig` selects how Keycloak authenticates/provisions identities:

- `standalone`: Keycloak-local users only.
- `downstream`: upstream identity is integrated through Keycloak (brokering/federation/provisioning).
- `hybrid`: upstream is preferred when healthy; login fails open to local-visible mode when upstream health fails.

Issuer stability contract:
- Client issuer remains `https://<keycloak-host>/realms/<realm>` in all modes.
- Platform consumers never talk directly to upstream IdPs.

## DeploymentConfig Contract

`spec.iam` (v1alpha1):

- `mode`: `standalone|downstream|hybrid` (default `standalone`)
- `primaryRealm` (default `deploykube-admin`)
- `secondaryRealms` (optional)
- `upstream`:
  - `type`: `oidc|saml|ldap|scim`
  - `alias` (default `upstream`)
  - `displayName`
  - protocol blocks (`oidc`, `saml`, `ldap`, `scim`)
  - optional `egress` allowlist metadata
- `hybrid`:
  - `healthCheck` (http/tcp + thresholds)
  - `offlineCredential` (`required`, `method`)
  - `failOpen` (default `true`)

## Runtime Reconciliation

### Bootstrap Job (`platform-keycloak-bootstrap`)

The Keycloak bootstrap job now:

1. Reads `ConfigMap/keycloak/deploykube-deployment-config` (`deployment-config.yaml`).
2. Exports deployment hostnames into env for realm template rendering.
3. Reconciles IAM mode for configured realms:
   - `standalone`: no upstream redirect preference.
   - `downstream`:
     - OIDC/SAML: reconcile upstream IdP and set upstream as default identity provider.
      - OIDC/SAML group mapping: reconcile upstream claim/attribute → Keycloak group mappings (`groupMappings`).
      - LDAP: reconcile LDAP federation component (local login form remains available).
      - SCIM: provisioning bridge client + local login preference (no redirect).
   - `hybrid`:
     - reconcile upstream integration as above,
     - enforce offline-credential required actions,
     - initialize realm in local-visible mode (fail-open baseline).
4. Reconciles IAM handover baseline in each target realm:
   - ensures `dk-iam-admins` group exists,
   - grants realm-management roles needed for user/group onboarding.

### Hybrid Sync CronJob (`keycloak-iam-sync`)

`keycloak-iam-sync` runs every 2 minutes:

1. Reads `spec.iam.hybrid.healthCheck`.
2. Evaluates upstream health by protocol:
   - OIDC: issuer discovery endpoint,
   - SAML: configured SSO URL/health URL,
   - LDAP: TCP reachability,
   - SCIM: not login-gating.
3. Applies thresholds (`successThreshold`, `failureThreshold`).
4. Toggles the browser flow `identity-provider-redirector` execution requirement for `primaryRealm` + `secondaryRealms`:
   - healthy threshold met: prefer upstream,
   - failure threshold met or uncertain with fail-open: local-visible.
5. Writes `ConfigMap/keycloak/keycloak-iam-sync-status` for auditability.
6. For LDAP `operationMode=sync`, `keycloak-ldap-sync` triggers LDAP full sync and writes `ConfigMap/keycloak/keycloak-ldap-sync-status`.

## Upstream Protocol Notes

- OIDC: brokered via Keycloak Identity Provider (`providerId=oidc`).
- SAML: brokered via Keycloak Identity Provider (`providerId=saml`).
- OIDC/SAML group mapping: `spec.iam.upstream.{oidc|saml}.groupMappings` are reconciled into IdP mappers with stable `deploykube-*` mapper names.
- LDAP:
  - `federation`: Keycloak LDAP user federation; online dependency remains.
  - `sync`: preferred for hybrid-friendly local auth posture.
- SCIM: treated as provisioning path (inbound) and does not gate login availability.
  - `platform-keycloak-scim-bridge` (disabled by default) hosts the SCIM endpoint.
  - bootstrap reconciles `deploykube-scim-bridge` client + secret (`Secret/keycloak/keycloak-scim-bridge-client`) for least-privilege admin API calls.

## Offline Credential Strategy (No Password Sync)

Hybrid mode must avoid password sync across trust boundaries.

Recommended pattern:

1. User authenticates upstream.
2. Keycloak requires local offline credential enrollment (`offlineCredential` policy):
   - `password`, or
   - `webauthn`, or
   - `password+otp` (recommended default).
3. During upstream outage, local credential unlocks platform access while issuer remains stable.

Automation users (`keycloak-automation-user`, bootstrap-managed users) are explicitly reconciled with `requiredActions=[]` to preserve non-interactive password-grant workflows.

## Secrets, Custody, and Rotation

- All upstream secrets are projected via ESO into `keycloak` namespace:
  - `keycloak-upstream-oidc`
  - `keycloak-upstream-saml`
  - `keycloak-upstream-ldap`
  - `keycloak-upstream-scim`
- Source of truth remains Vault (`secret/keycloak/upstream-*`).
- No plaintext upstream credentials are committed to Git.
- Expected Vault keys:
  - `secret/keycloak/upstream-oidc`: `clientSecret` (required), `clientId` (optional), `ca.crt` (optional, used by hybrid HTTPS health checks).
  - `secret/keycloak/upstream-saml`: `signingCert` (required when SAML mode is used).
  - `secret/keycloak/upstream-ldap`: `bindDn`, `bindPassword` (required when LDAP bind is used).
  - `secret/keycloak/upstream-scim`: `token` (or equivalent auth payload consumed by your bridge path).
- Rotation model:
  - rotate at Vault path,
  - ESO refreshes Secret,
  - bootstrap/iam-sync reconcile picks up updated values.

Hybrid HTTPS trust:
- `spec.iam.hybrid.healthCheck.caRef` can point to a Kubernetes Secret key containing a PEM CA bundle for health probe TLS verification.
- For OIDC, `spec.iam.upstream.oidc.caRef` and `keycloak-upstream-oidc/ca.crt` are also accepted fallback sources.

## Network + Security Considerations

Current baseline enables Keycloak egress to protocol ports required for upstream IAM integrations (443, 389, 636). This is intentionally port-scoped, but still broad by CIDR.

Follow-up hardening target:

1. enforce explicit CIDR allowlists from `spec.iam.upstream.egress.allowedCidrs` (controller-managed `NetworkPolicy/keycloak-upstream-egress-managed`),
2. enforce upstream CA pinning per protocol,
3. alert on repeated hybrid flip/flop events.

## Human IAM Handover

Bootstrap now guarantees a minimum handover baseline (`dk-iam-admins` in each IAM target realm), but human ownership transfer is an explicit step.

Runbook helper:

`shared/scripts/keycloak-iam-handover.sh`

- `audit`:
  - validates current mode/realms,
  - ensures `dk-iam-admins` exists,
  - warns when upstream mappings do not target `dk-iam-admins`.
- `provision-owner`:
  - creates/updates the first human IAM owner in each target realm,
  - assigns them to `dk-iam-admins`,
  - sets a temporary password for first-login rotation.

Recommended cutover sequence:

1. Run `audit`.
2. Run `provision-owner` with a dedicated human IAM account.
3. Confirm user/group admin operations in Keycloak admin console.
4. For upstream mode, verify upstream group mapping to `dk-iam-admins`.
5. Remove bootstrap-era human admin access once ownership is confirmed.

## Failure Modes and Breakglass

- Upstream IdP outage: hybrid mode falls back to local-visible login (fail-open), no issuer change.
- Keycloak outage: this is outside IAM mode scope; follow cluster access breakglass procedures in `docs/design/cluster-access-contract.md`.
- Misconfigured upstream redirect: disable upstream preference via `keycloak-iam-sync` status-driven reconciliation and verify local auth.

## Evidence Expectations

Mode or upstream changes must ship with:

- GitOps manifests,
- docs updates,
- evidence run showing:
  - issuer stability,
  - downstream login success,
  - hybrid fail-open/failback behavior,
  - automation token flows (`argocd-token.sh`, `vault-token.sh`) still functioning.

Operational runbook for repeatable mode checks:
- `docs/toils/keycloak-iam-mode-matrix-e2e.md`
