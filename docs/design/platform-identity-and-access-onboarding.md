# Design: Platform Identity and Access (OIDC + RBAC + Onboarding)

Last updated: 2026-03-01  
Status: Implemented (Proxmox runtime validated; mac-orbstack-single overlay parity validated)

This document is the **decision log + implementation plan** for fixing DeployKube's temporary OIDC/RBAC shortcuts (the `temp-*` roles/groups) and shipping a durable onboarding model for new clusters/environments.

## Tracking

- Canonical tracker: `docs/component-issues/argocd.md`
- Cluster access contract (guardrails + breakglass): `docs/design/cluster-access-contract.md`
- Keycloak IAM modes (upstream OIDC/SAML/LDAP/SCIM): `docs/design/keycloak-iam-modes.md`
- Related trackers:
  - Argo CD: `docs/component-issues/argocd.md` (temporary RBAC-role mapping closure recorded)
  - Keycloak: `docs/component-issues/keycloak.md` (temporary realm role/group cleanup closure recorded)
  - shared-rbac: `docs/component-issues/shared-rbac.md` (Forgejo `dk-*` group contract closure recorded)
  - Registry (Harbor): `docs/component-issues/registry-harbor.md` (OIDC integration + admin-group mapping closure recorded)

## Problem Statement

Today, multiple components still rely on **temporary identity surfaces** that were intended for dev-only integration testing:

- Keycloak realm ships `temp-*` roles/groups.
- Argo CD RBAC policy includes wildcard temporary roles and test mappings.
- Forgejo team sync maps `temp-*` groups instead of the canonical `dk-*` contract.

This creates onboarding ambiguity and increases risk in production-like environments.

## Non-Negotiable Decisions

1. **Keycloak is the only issuer** for platform consumers.
   - Upstream identity providers are integrated through Keycloak brokering (`spec.iam.upstream.*`).
   - Platform consumers never talk directly to upstream IdPs.

2. **Group-based authorization everywhere.**
   - Kubernetes and all platform UIs map permissions from the `groups` claim.

3. **Canonical group contract is `dk-*` (humans) and `dk-bot-*` (automation).**
   - No non-`dk-*` long-lived groups that downstream systems depend on.

4. **Remove all `temp-*` identities from production posture.**
   - No `temp-*` roles/groups in Keycloak realm templates.
   - No `temp-*` mappings in Argo RBAC or Forgejo team sync.

5. **Breakglass is offline-only (no OIDC breakglass group escalation).**
   - Breakglass entry is via offline kubeconfig + documented runbooks.
   - We do not rely on an IAM-controlled OIDC group like `dk-breakglass` to obtain or bypass privileges.

## Canonical Group Contract

### Group String Shapes (Non-Negotiable)

DeployKube uses Keycloak **groups** as the cross-system authorization contract, but there are two different string representations involved:

- **Keycloak group path (Keycloak admin model):** `/dk-...`
  - Realm templates define groups with a `path` (for example `/dk-platform-admins`).
  - Upstream IdP mapping (`DeploymentConfig.spec.iam.upstream.*.groupMappings[].target`) targets **Keycloak group paths** (standardize on `/dk-*`).
- **OIDC token claim value (runtime contract for consumers):** `dk-...` (no leading `/`)
  - All platform consumers (Kubernetes RBAC, Argo CD, Vault, Grafana, oauth2-proxy, etc.) authorize based on the OIDC `groups` claim values.
  - Realm clients must emit `groups` as **short names** (no leading `/`) via the Keycloak group membership mapper (`full.path=false`).

Changing either representation (for example switching Keycloak protocol mappers to full paths) is a breaking change and must be treated as a migration with docs + evidence.

### Humans (cross-system)

- `dk-platform-admins`
- `dk-platform-operators`
- `dk-security-ops`
- `dk-auditors`
- `dk-iam-admins` (IAM ownership/hand-over; required for upstream modes)
- `dk-support` (reserved; no default permissions, used only by explicit support-session bindings)

### Automation (split, least privilege)

- `dk-bot-argocd-sync`
- `dk-bot-vault-writer`

### Existing patterns (unchanged)

- App teams:
  - `dk-app-<team>-maintainers`
  - `dk-app-<team>-contributors`
- Tenants (from shared-rbac contract):
  - `dk-tenant-<orgId>-...`

## Identity Sources and Onboarding Modes

DeployKube supports two operator-facing onboarding styles (both keep Keycloak as issuer):

1. **Keycloak-managed users/groups (standalone)**
   - Humans are created and assigned to `dk-*` groups in Keycloak.
   - Primary onboarding requirement is to ensure a human owner exists in `dk-iam-admins`.

2. **Upstream IdP via Keycloak (downstream/hybrid)**
   - Keycloak brokers upstream identity (OIDC/SAML/LDAP/SCIM) and maps upstream groups into `dk-*` groups.
   - DeploymentConfig must ensure canonical `dk-*` membership is reachable:
     - If upstream already emits `groups` with `dk-*` values, no additional mapping is required.
     - Otherwise provide `spec.iam.upstream.*.groupMappings` targeting the Keycloak group paths (`/dk-*`).

Reference: `docs/design/keycloak-iam-modes.md`.

## Component Mapping (What Each System Consumes)

### Kubernetes API (kubectl)

- AuthN: OIDC with Keycloak issuer.
- AuthZ: Kubernetes RBAC binds `dk-*` groups to ClusterRoles/RoleBindings.
- Guardrails: admission blocks RBAC mutations outside GitOps identities and offline breakglass identities.

### Argo CD

- OIDC: `groupsFieldName: groups`.
- RBAC source of truth: `argocd-rbac-cm` policy.csv (patched by a GitOps-managed job).
- Required behavior:
  - No `temp-*` roles or mappings.
  - `dk-platform-admins` is full Argo admin.
  - `dk-platform-operators` can operate applications under the `platform` Argo project (`platform/*` app name scope).
  - `dk-bot-argocd-sync` is a constrained sync-only identity.
  - `dk-auditors` is read-only (get/list) across applications and projects.

### Vault (OpenBao)

- Human login: OIDC auth mount uses Keycloak and consumes `groups` claim.
- Human authZ: Vault identity group aliases map OIDC group names (`dk-*`) to Vault policies.
- Bot login: JWT auth mount binds automation tokens to Keycloak-issued claims:
  - `bound_claims.groups=dk-bot-vault-writer`
  - `bound_claims.azp=<vault client id>` (prevents client confusion)
  - short TTL tokens only (no long-lived bot tokens)

### Forgejo

- Human login: OIDC via Keycloak.
- Team membership governance: CronJob syncs Keycloak groups to Forgejo teams.
- Required behavior:
  - No dependency on `temp-*` or non-`dk-*` group names.
  - Owners team = `dk-platform-admins`.
  - Operators/auditors map to explicit teams with scoped permissions.
  - Optional (recommended): app-team groups map to Forgejo teams for repo governance consistency.

### Grafana

- Auth: Keycloak OIDC.
- AuthZ: map Grafana roles from `groups` claim using `dk-*` personas.

### Hubble (oauth2-proxy)

- Auth: oauth2-proxy OIDC with Keycloak.
- AuthZ: oauth2-proxy allowlist by `groups` claim (only selected `dk-*` groups).

### Kiali

- Auth: Kiali OpenID with Keycloak.
- AuthZ: enable Kiali RBAC enforcement (avoid `disable_rbac=true`).
- TLS trust: do not rely on `insecure_skip_verify_tls=true` long-term; mount/use Step CA trust bundle.
- Kubernetes API access requirement:
  - Kiali uses a user token to call the Kubernetes API server.
  - Tokens must be accepted by the API server's OIDC audience; if the API server uses `--oidc-client-id=kubernetes-api`, ensure Kiali-issued tokens include `kubernetes-api` in `aud` (via a Keycloak audience mapper on the `kiali` client).

### Harbor

- Human login: OIDC via Keycloak (Harbor config via Harbor API).
- AuthZ: Harbor uses an OIDC admin group (set to `dk-platform-admins`) plus Harbor-native projects/roles for everything else.
- TLS trust: Harbor chart supports `caBundleSecretName` to inject a custom CA bundle file into core/jobservice/exporter/registry containers; use it to trust the Step CA root.

## Breakglass (Offline-Only)

Breakglass is defined as:

- Entry: **offline Kubernetes kubeconfig** (exact runbook intentionally omitted from this public mirror).
- Recovery goal: restore OIDC + GitOps workflows, not to become a steady-state admin path.

Implementation requirements:

- Remove the OIDC breakglass group binding:
  - delete `ClusterRoleBinding/breakglass-cluster-admin`
  - remove `dk-breakglass` exemptions from access-guardrails ValidatingAdmissionPolicies
  - remove `dk-breakglass` from Keycloak realm templates

## Current Status (2026-03-01, Proxmox + mac-orbstack-single overlays)

- Phase 1 runtime cleanup completed and validated (temp-role/group removal, breakglass offline-only posture, guardrail alignment).
- Phase 2 completed:
  - split bot group contract is live (`dk-bot-argocd-sync`, `dk-bot-vault-writer`)
  - Vault platform persona alias/policy reconciler is implemented and validated on Proxmox
- Phase 3 implementation completed:
  - Grafana Keycloak role mapping now uses canonical `dk-*` personas
  - Hubble oauth2-proxy now enforces a `dk-*` allowed-group gate
  - Kiali RBAC/TLS verification hardening in proxmox overlay
  - Harbor Keycloak OIDC integration + admin group mapping
- Phase 4 deliverables implemented:
  - onboarding guide (`docs/guides/platform-access-onboarding.md`)
  - CI regression guard against `temp-*` reintroduction (`tests/scripts/validate-no-temp-identity-markers.sh`)
- Validation boundary:
  - Proxmox has full runtime validation evidence across Phases 1-4.
  - `mac-orbstack-single` has overlay/render/contract closure evidence for Phase 3 identity hardening.
  - In current `kind-deploykube-dev` profile snapshots, `networking-hubble-ui` and `platform-observability-grafana` are not present, so direct runtime auth-flow checks for those apps are N/A there.

Evidence:

### Phase 1: Remove Temporary Identity Surfaces

1. Keycloak
   - Delete `temp-*` roles/groups and any non-`dk-*` contract groups from realm templates.
   - Add `dk-bot-argocd-sync` and `dk-bot-vault-writer` groups.
   - Ensure all relevant clients emit `groups`.

2. Argo CD
   - Remove `role:temp-*` and any `temp-*` mappings from Argo RBAC policy generation.
   - Fix any project name patterns to match runtime AppProject names (e.g. `platform/*`).
   - Add bot role mapping for `dk-bot-argocd-sync` with sync-only permissions.

3. shared-rbac (Forgejo team sync)
   - Replace `temp-*` group mappings with `dk-*` persona mappings.
   - Optionally extend to app-team groups.

### Phase 2: Bots and Vault AuthZ

1. Split automation users (least privilege)
   - Replace the single `argocd-automation` identity with two bots:
     - Argo bot: member of `dk-bot-argocd-sync`
     - Vault bot: member of `dk-bot-vault-writer`
   - Back both by Vault-managed secrets projected via ESO.

2. Vault platform RBAC reconciler
   - Add a GitOps-managed CronJob to reconcile Vault identity group aliases and policies for:
     - `dk-platform-admins`
     - `dk-platform-operators`
     - `dk-security-ops`
     - `dk-auditors`
     - `dk-iam-admins`

### Phase 3: Close the Remaining UI Gaps

1. Grafana: map roles from `dk-*` groups (remove legacy observability group names).
2. Hubble: restrict access via oauth2-proxy allowed groups; require Keycloak hubble client to emit `groups`.
3. Kiali:
   - enable RBAC (remove `disable_rbac: true`)
   - stop skipping TLS verification by mounting Step CA trust bundle
   - ensure token audience is accepted by the API server (`aud` includes `kubernetes-api`)
4. Harbor:
   - create Keycloak Harbor client with correct redirect URI(s)
   - add a PostSync job to configure OIDC via Harbor API and set `oidc_admin_group=dk-platform-admins`
   - inject Step CA trust via chart `caBundleSecretName`

### Phase 4: Onboarding Guide + CI Regression Gates

1. Write `docs/guides/platform-access-onboarding.md`:
   - How to onboard a new cluster/env with:
     - standalone Keycloak-managed users
     - upstream OIDC via groupMappings to `dk-*`
   - Required `DeploymentConfig.spec.iam.upstream.*.groupMappings` baseline:
     - upstream group -> `/dk-platform-admins`
     - upstream group -> `/dk-platform-operators`
     - upstream group -> `/dk-security-ops`
     - upstream group -> `/dk-auditors`
     - upstream group -> `/dk-iam-admins`

2. Add CI checks to prevent reintroducing `temp-*`:
   - A repo-level script that fails if `temp-*` appears in runtime manifests/scripts/toils (excluding historical evidence files).

## Validation and Evidence (Required When Implementing)

Implementation PR(s) must ship:

- Manifests/scripts changes under `platform/gitops/**` and `shared/**`.
- Docs updates (this design doc, component READMEs, toils).
- Evidence: `docs/evidence/YYYY-MM-DD-platform-access-onboarding.md` proving:
  - `kubectl auth whoami` shows `groups` and RBAC works for `dk-platform-admins`
  - Argo UI/CLI RBAC works for `dk-platform-admins` and bot is sync-only
  - Vault OIDC policies attach correctly by group alias
  - Forgejo team membership reflects Keycloak groups
  - Grafana role mapping matches dk personas
  - Hubble/Kiali are not world-readable (group-gated and/or RBAC-enforced)
  - Harbor OIDC enabled and admin group mapping works

## Notes for Future Compactions (Why This Exists)

- The highest-risk failures in this space are partial renames and dual-taxonomy drift:
  - If any component still consumes `temp-*` or non-`dk-*` names, onboarding becomes non-deterministic.
  - If any component consumes realm roles (`realm_access.roles`) instead of `groups`, upstream mappings become inconsistent.
- Order matters for GitOps jobs that patch OIDC/RBAC config:
  - Jobs must wait for Keycloak bootstrap and OIDC CA trust projections (avoid bootstrap deadlocks).
- Avoid IAM-dependent breakglass escalation:
  - If IAM is broken, an OIDC “breakglass group” is not reliable and is also an escalation lever outside Git.
