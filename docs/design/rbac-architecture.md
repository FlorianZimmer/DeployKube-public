# DeployKube Role & Group Architecture (Draft)

_Last updated: 2026-01-06_

## Tracking

- Canonical tracker: `docs/component-issues/shared-rbac.md`

## Purpose & Scope
- Replace ad hoc org membership steps with a unified, least-privilege RBAC model that spans Kubernetes, Argo CD, Forgejo, Vault, and supporting jobs.
- Keep identity authoritative in Keycloak; all other systems consume group/role mappings via OIDC or Jobs, never manual hand edits.
- Serve as the contract before implementing automation or manifest changes. All service-specific READMEs should reference this document once applied.
- Related: four-eyes RBAC changes, Git-based escalation, and breakglass access are captured in `docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`.
- Operational workflow, admission guardrails, and breakglass procedures are specified in `docs/design/cluster-access-contract.md`.

## Guiding Principles
- **Single source of identity**: Keycloak realm `deploykube-admin` issues OIDC tokens with the `groups` claim; systems map these to local roles/teams.
- **Least privilege by default**: start from read-only; elevate per namespace/app; avoid global write except for a small platform set.
- **GitOps-managed**: RBAC/roles/teams/policies expressed as manifests or Job templates under `platform/gitops/`; no long-lived manual changes.
- **Separation of duties**: distinguish cluster/platform ops from app delivery and security/compliance.
- **Auditability**: prefer group-based bindings over user bindings; all automation credentials come from Vault/ESO with short TTLs.

## Personas and Rights Matrix
| Persona | Kubernetes | Argo CD | Forgejo | Vault | Notes |
| --- | --- | --- | --- | --- | --- |
| Platform Admin | bound directly to built-in `cluster-admin`; may mutate bootstrap namespaces | admin on all projects | org owner | `sudo`, policy author | Requires MFA; changelog review for risky ops |
| Platform Operator (SRE) | manage platform namespaces/apps; install/upgrade operators and their CRDs; no node-level ops | maintain platform projects; sync/rollback; no Argo RBAC edits | platform team maintainer | read/write platform secrets; no sys/* enable/disable | Runs rotations, patch waves |
| App Maintainer (`app:<team>`) | admin within team namespaces | project admin for team | repo maintainer on team projects | write-only to `secret/data/apps/<team>` | Own day-2 for their apps |
| App Contributor | edit within team namespaces; no RBAC changes | contributor (create apps under team project) | repo writer | read to `secret/data/apps/<team>` | Cannot change Argo projects |
| Auditor | view-only cluster-wide; **no Secrets** by default | read-only on all projects | read on org | read-only to `secret/data/audit/*` if approved; default none | Used by compliance/PII reviews |
| Automation/Bot | namespace-scoped ServiceAccount; custom | service account tokens per project | bot account per repo | narrow policy per job | Tokens via Vault + ESO |

## Keycloak Group Model (authoritative)
- Prefix all platform-managed groups with `dk-` to avoid collision with future B2C realms.
- Core groups:
  - `dk-platform-admins`
  - `dk-platform-operators`
  - `dk-security-ops` (owns Vault policy authoring, audit)
  - `dk-auditors`
- App/team groups (pattern):
  - `dk-app-<team>-maintainers`
  - `dk-app-<team>-contributors`
- Bot groups (pattern):
  - `dk-bot-<name>` (mapped to Vault policies + Forgejo robots)
- Group of groups may be used inside Keycloak to nest external IdPs later, but exported claims should remain flat for downstream simplicity.

## System-Specific Mapping Plan

### 1) Kubernetes API
- **AuthN**: OIDC with Keycloak client `kubernetes-api`. kubeconfigs use the `kubectl oidc-login` (kubelogin) exec plugin; short-lived tokens only. Helper: `shared/scripts/generate-oidc-kubeconfig.sh`.
- **Roles** (ClusterRoles, GitOps-managed):
  - Bind `dk-platform-admins` directly to built-in `cluster-admin` (auditable, explicit).
  - `platform-operator` (cluster-scoped read; write on namespaces labeled `darksite.cloud/rbac-profile=platform`; may manage CRDs, webhooks, and shared operator deployments).
  - `app-namespace-admin`, `app-namespace-edit`, `app-namespace-view` (scoped to namespaces labeled `darksite.cloud/app-team=<team>`).
  - `auditor-readonly` (no `secrets`, `serviceaccounts/token` verbs).
- **Bindings / labels**:
  - Namespaces carry `darksite.cloud/rbac-profile={platform,app,tenant}`.
    - App namespaces use `darksite.cloud/rbac-team=<team>`.
    - Tenant namespaces use `darksite.cloud/tenant-id=<orgId>` and `darksite.cloud/project-id=<projectId>`.
    - Optional: `darksite.cloud/platform=true` for core infra namespaces.
  - Generators emit `RoleBinding`s per namespace from those labels (`dk-app-<team>-maintainers` → admin; contributors → edit; auditors → view).
  - Platform namespaces (`istio-system`, `vault`, `forgejo`, `argocd`, `dns`, `cert-manager`, `step-system`, `cnpg-system`, `external-secrets`) bind `dk-platform-operators` to edit and `dk-security-ops` to secret read where applicable.
- **Machine access**: Jobs run as dedicated ServiceAccounts with namespace-scoped Roles; no token reuse.

#### Kubernetes API Rights Table (summary)
`write*` = namespace-scoped; `write†` = cluster-scoped but limited to platform operators.

| API Group/Resource | Platform Admin | Platform Operator | App Maintainer | Contributor | Auditor |
| --- | --- | --- | --- | --- | --- |
| core/v1 pods,deployments,svc | write* all namespaces | write* platform namespaces | write* team ns | write* team ns (no RBAC edits) | read |
| core/v1 secrets | write all | write platform ns; read platform secrets | write team ns | read team ns | none |
| rbac.authorization.k8s.io | write all | write Roles/Bindings in platform ns | write Roles/Bindings in team ns | none | read |
| apiextensions.k8s.io CRDs | write | write† (operator CRDs) | none | none | read |
| admission webhooks | write | write† when tied to platform operators | none | none | read |
| networking (NetPol/Gateway) | write | write platform ns; no cluster default change | write team ns | read | read |
| nodes/pods/eviction | write | read | none | none | read |

### 2) Argo CD
- **OIDC**: client `argocd` in Keycloak; claim `groups` used directly.
- **Policy defaults**:
  - `role:platform-admin` → `applications,projects,accounts,certificates,clusters,*` full allow; mapped to `dk-platform-admins`.
  - `role:platform-operator` → `applications/*` (get, create, update, delete, sync, override, exec=false) limited to `platform-*` projects; cannot edit RBAC/SSO.
  - `role:app-admin:<team>` → `applications/*` (create/delete/sync/override, exec=false) inside `apps-<team>` project; `projects/get` only.
  - `role:app-contrib:<team>` → `applications/{get,sync}` inside `apps-<team>`; no create/delete; exec=false; cannot override hooks.
  - `role:auditor` → read-only everywhere; mapped to `dk-auditors`.
- **Enforcement (repo reality)**:
  - `policy.default=role:readonly` (built-in Argo role for unaffiliated users).
  - local accounts disabled except breakglass flows; see `docs/design/cluster-access-contract.md`.

### 3) Forgejo
- **Org**: `platform` remains root org.
- **Teams**:
  - `owners` reserved for `dk-platform-admins`.
  - `platform-ops` ← `dk-platform-operators`.
  - `security-ops` ← `dk-security-ops`.
  - `auditors` ← `dk-auditors` (read-only).
  - App-scoped teams: `app-<team>-maintainers` (Maintain), `app-<team>-contributors` (Write), `app-<team>-readers` (Read).
- **Automation**: Argo-managed CronJob `forgejo-team-sync` (runs in `forgejo` namespace, image `deploykube/bootstrap-tools:1.4`) that:
  - Fetches Keycloak group membership via client credentials (scope `groups`).
  - Calls Forgejo API with a PAT stored in Vault secret `forgejo/team-sync` projected via ESO.
  - Converges team membership (add missing, remove stale) and writes a status ConfigMap for audit.
  - Idempotent and safe to rerun after wipes (replaces the legacy Stage 1 membership loop).

### 4) Vault
- **Auth**: Prefer OIDC auth method bound to Keycloak; retain Kubernetes auth for in-cluster Jobs.
- **Identity mapping**: create Vault identity groups matching Keycloak `dk-*` groups via OIDC group-alias; no local user mappings.
- **Policies**:
  - `vault-platform-admin` (sys*, pki, auth enable/disable) ← `dk-platform-admins`.
  - `vault-security-policy-admin` (write policies under `secret/*`, `auth/*`, pki roles; cannot disable audit) ← `dk-security-ops`.
  - `vault-security-audit` (read audit devices, list tokens, no write) ← optional subgroup of `dk-security-ops`.
  - App policies per team: `apps-<team>-rw` (paths `secret/data/apps/<team>/*`, transit keys scoping) ← `dk-app-<team>-maintainers`; `apps-<team>-ro` for contributors.
  - Break-glass tokens live in Vault transit, released via short-lived operator-run Job; documented in Vault README.
- **ESO alignment**: ExternalSecrets reference these policies; no wildcard `default` policy bindings.

### 5) Supporting Components
- **CI/CD & Bots**: Each bot gets:
  - Keycloak client + group `dk-bot-<name>`.
  - Forgejo bot user with PAT kept in Vault.
  - Kubernetes ServiceAccount with namespace-scoped Role; mapped through ESO to the Job/Workflow.
- **Observability/Monitoring (future)**: Auditors gain Grafana read-only; Platform Ops maintain alert rules. Will wire when stack lands.

### 6) Service UIs (Kiali, Hubble, Keycloak Admin)
- **Kiali**: enforce OIDC login with Keycloak client `kiali`; map `dk-platform-operators` → server admin, `dk-auditors` → read-only (`kiali.viewer`). Namespace filters follow existing K8s RBAC so app teams only see their namespaces.
- **Hubble (UI/Relay)**: protect with `gateway.networking.k8s.io` + OIDC AuthPolicy. `dk-platform-operators` get full flow visibility; `dk-auditors` get read-only. Disable anonymous access; rely on mesh mTLS for backend authz.
- **Keycloak Admin Console**: restrict to `dk-platform-admins` and `dk-security-ops` via realm admin fine-grained permissions; operators get `manage-realm`?=no to prevent accidental client edits. Document break-glass admin token rotation in Keycloak README.

## GitOps Folder Topology (target)
```
platform/gitops/
  apps/                  # Argo Applications (app-of-apps)
  components/
    platform/
      keycloak/
      argocd/
      forgejo/
      vault/
    networking/
    secrets/
    shared/
      rbac/              # k8s RBAC + namespace/team sync jobs
      rbac-secrets/      # ExternalSecret + bootstrap job (syncs after ESO)
  clusters/              # per-env overlays (dev/mgmt/prod)
docs/design/
  rbac-architecture.md
  gitops-operating-model.md
docs/component-issues/
```

## Onboarding / Offboarding Flow
1. Add/remove user from Keycloak groups (`dk-*`). No direct changes elsewhere.
2. Argo syncs:
   - Kubernetes `RoleBinding`s (per-namespace generators).
   - Argo CD RBAC ConfigMap.
   - Forgejo team sync CronJob (runs and reconciles membership).
   - Vault group aliases → policies.
3. Verify via checklists: `kubectl auth can-i`, `argocd account get-user-info`, Forgejo team list, Vault `whoami` (`vault token lookup` with OIDC).

## Implementation Roadmap (not executed yet)
1. Agree on group prefixes and personas (this doc).
2. Create Keycloak groups/clients + realm mapper updates under `platform/gitops/components/platform/keycloak` (realm config + bootstrap job).
3. Add Kubernetes RBAC bases (`components/shared/rbac/`) and secrets/bootstrap (`components/shared/rbac-secrets/`) to bind the groups.
4. Update Argo CD RBAC ConfigMap + OIDC settings to honor the group names.
5. Add Forgejo team-sync CronJob, PAT secret, and status ConfigMap template; document runbook in component README.
6. Add Vault OIDC auth method + group alias manifests; adjust policies per team.
7. Smoke test onboarding/offboarding and record evidence under `docs/evidence/` (new folder if needed).

## Open Questions / Decisions to Ratify
- Confirm Kubernetes API is (or will be) OIDC-enabled; otherwise schedule the API server flag change and kubeconfig migration.
- Do we require SCIM for future external IdP integration, or are Keycloak groups sufficient near-term?
- Which teams should exist on day one (`app-core`, `app-demo`, etc.)? Populate a seed list before enabling automation to avoid dangling bindings.
- Are auditors ever allowed Secret read? Current plan: **no Secrets by default**; introduce temporary read via time-bound policy if compliance requires.

## Threat Model Considerations
- **Token leakage**: use short TTL OIDC tokens; kubeconfigs rely on exec plugin not static tokens; Argo/Forgejo/Vault PATs stored in Vault with rotation Jobs.
- **Privilege escalation**: no wildcard `*` for non-admin roles; platform-operator cannot alter RBAC or Argo SSO; Keycloak admin console restricted to admin/security groups; auditors have zero Secret read unless explicitly time-bound.
- **Drift**: all bindings converge via Argo; Forgejo membership reconciled by CronJob; Vault group-alias ensures OIDC group changes take effect on next login.
- **Break-glass**: admin tokens (Argo, Keycloak, Vault) issued via dedicated short-lived Jobs; rotation and access logged; SOP to disable after use.

## Automated Bootstrap Workflow (planned)
Goal: zero manual secrets during Stage 1. Everything seeds itself except assigning humans to groups and labeling namespaces.

### Target design (detailed)
1) **Prereq: Vault roles/policies**
   - Policy `forgejo-team-sync-writer` with `create/update/read/list` on `secret/data/forgejo/team-sync` + metadata.
   - K8s auth role `forgejo-team-sync-writer` bound to SA `forgejo-team-bootstrap` in namespace `forgejo`, issuing short TTL tokens.
   - Provisioned during the existing vault-configure job so it’s ready before Stage 1 finishes.

2) **Forgejo admin credential surfacing**
   - Vault path `secret/data/forgejo/admin` (username/password).
   - `ExternalSecret forgejo-admin-credentials` in namespace `forgejo`; Secret type `Opaque`.

3) **Bootstrap/rotate job (Argo-managed, post-sync)**
   - Runs in `forgejo` namespace as SA `forgejo-team-bootstrap`.
   - Steps:
     - Login to Forgejo using admin secret.
     - Ensure bot user (e.g., `forgejo-bot`) exists; optionally reuse admin.
     - Mint PAT with org/team admin scope.
     - Login to Keycloak using existing admin secret (from `keycloak-admin-credentials`).
     - Ensure client `team-sync` exists with `groups` scope; rotate client secret.
     - Write `{token, keycloakClientId, keycloakClientSecret}` to Vault path `secret/data/forgejo/team-sync` using K8s-auth Vault token; also refresh a Secret in-cluster for immediate use.
     - Record sentinel ConfigMap `forgejo-team-bootstrap-status` with timestamp to stay idempotent.
   - Job gated behind Argo sync wave after Vault + Forgejo + Keycloak are ready (e.g., wave 6).

4) **Consumption**
   - `forgejo-team-sync` CronJob `envFrom` reads Secret projected from ExternalSecret fed by Vault; if missing, it skips gracefully.
   - Namespace RBAC sync is independent, so RBAC stays functional even if PAT generation is delayed.

5) **Rotation**
   - Re-run job (manual Argo sync or CronJob variant) to rotate PAT/client secret. It overwrites Vault path and bumps Secret annotations to force rollout.

6) **Operator inputs reduced to:**
   - Assign humans to Keycloak groups (`dk-*`).
   - Label namespaces `darksite.cloud/rbac-profile` + profile-specific labels:
     - `darksite.cloud/rbac-team=<team>` for `rbac-profile=app`
     - `darksite.cloud/tenant-id=<orgId>` and `darksite.cloud/project-id=<projectId>` for `rbac-profile=tenant`
   - (Optional) choose bot username; defaults provided.

Impact: Stage 1 becomes fully hands-off for secrets/PATs; only identity/group assignment and namespace ownership remain human decisions.

## Glossary
- **Platform namespace**: shared infra namespaces labeled `darksite.cloud/rbac-profile=platform`.
- **App namespace**: workload namespace labeled `darksite.cloud/rbac-profile=app` and `darksite.cloud/rbac-team=<team>`.
- **Tenant namespace**: tenant workload namespace labeled `darksite.cloud/rbac-profile=tenant` and `darksite.cloud/tenant-id=<orgId>` + `darksite.cloud/project-id=<projectId>`.
- **Team-sync**: Forgejo CronJob reconciling Keycloak groups to org teams.
- **Break-glass admin**: time-bound credential issued for emergency use, stored/rotated in Vault.
- **Profile**: RBAC posture indicator (`platform` / `app` / `tenant`) driving RoleBinding generation.

## Historical Note: Deprecated `temp-*` Identity Model (Removed)

This section previously documented a dev-only `temp-*` identity/RBAC fast-path. As of **2026-03-01**, DeployKube removed `temp-*` roles/groups/mappings from the shipped platform posture and added CI regression gates preventing reintroduction.

Current contract and onboarding model:
- Design: `docs/design/platform-identity-and-access-onboarding.md`
- Guide: `docs/guides/platform-access-onboarding.md`

If you find remaining references to `temp-*` in runtime manifests/scripts, treat it as a bug and remove it in the same change (with evidence).
