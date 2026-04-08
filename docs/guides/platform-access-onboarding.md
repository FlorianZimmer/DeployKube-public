# Platform Access Onboarding (OIDC + RBAC)

This guide defines the standard onboarding flow for platform access across DeployKube components with Keycloak as the issuer and `dk-*` groups as the contract.

Related:
- Design and phase plan: `docs/design/platform-identity-and-access-onboarding.md`
- IAM modes (standalone/downstream/hybrid): `docs/design/keycloak-iam-modes.md`
- Cluster bootstrap: `docs/guides/bootstrap-new-cluster.md`

## Scope and contract

Identity source of truth:
- Keycloak is the only OIDC issuer consumed by platform components.
- Upstream IdPs are integrated through Keycloak brokering only.

Authorization contract:
- Group claim is `groups`.
- `groups` claim values are **short group names** (`dk-*`, no leading `/`).
- Canonical human groups:
  - `dk-platform-admins`
  - `dk-platform-operators`
  - `dk-security-ops`
  - `dk-auditors`
  - `dk-iam-admins`
  - `dk-support` (reserved; no default permissions)
- Canonical automation groups:
  - `dk-bot-argocd-sync`
  - `dk-bot-vault-writer`

Breakglass contract:
- Offline-only Kubernetes breakglass kubeconfig.
- No online OIDC breakglass escalation group.

## Onboarding modes

DeployKube supports two onboarding modes:

1. Standalone Keycloak-managed users/groups
- Users are created in Keycloak and assigned to `dk-*` groups directly.
- At least one trusted operator must be in `dk-iam-admins`.

2. Upstream IdP via Keycloak brokering
- Upstream users authenticate to Keycloak.
- Upstream groups are mapped to canonical `dk-*` groups in deployment config.

## Required DeploymentConfig baseline (upstream mode)

Set group mappings so each canonical platform persona is reachable:

- upstream group -> `/dk-platform-admins`
- upstream group -> `/dk-platform-operators`
- upstream group -> `/dk-security-ops`
- upstream group -> `/dk-auditors`
- upstream group -> `/dk-iam-admins`

Note: mapping `target` values are **Keycloak group paths** (`/dk-*`). Runtime consumers authorize based on OIDC token `groups` claim values (`dk-*`).

Use `platform/gitops/deployments/<deploymentId>/config.yaml` and keep mappings in Git.

## Proxmox onboarding workflow

1. Prepare deployment config and secrets
- Edit `platform/gitops/deployments/proxmox-talos/config.yaml`.
- Confirm IAM mode and upstream mappings (if used).
- Ensure Vault seed paths for OIDC users/clients are present via `secrets-vault-config`.

2. Validate repo contracts before rollout
```bash./tests/scripts/validate-deployment-config.sh./tests/scripts/validate-no-temp-identity-markers.sh./tests/scripts/validate-vault-oidc-config.sh./tests/scripts/validate-vault-tenant-rbac-config.sh
```

3. Commit changes and seed Forgejo mirror
```bash
git add -A
DK_ALLOW_MAIN_COMMIT=1 git commit -m "identity: update platform access onboarding wiring"
FORGEJO_FORCE_SEED=true./shared/scripts/forgejo-seed-repo.sh
```

4. Trigger reconciliation
```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite
```

5. Verify root app convergence
```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd get application platform-apps -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```
Expected: `Synced Healthy`

## Component verification checklist

Run the checks below after each onboarding rollout:

1. Kubernetes OIDC groups/RBAC
- `kubectl auth whoami` (OIDC user) shows expected `dk-*` groups.
- `dk-platform-admins` can administer cluster; non-admin personas are constrained.

2. Argo CD
- OIDC login works.
- `dk-platform-admins` has admin rights.
- `dk-bot-argocd-sync` can sync `platform/*` and cannot escalate.

3. Vault (OpenBao)
- OIDC human aliases for `dk-platform-*` and `dk-iam-admins` are present.
- JWT bot role accepts `dk-bot-vault-writer` and issues short-lived token.

4. Forgejo
- Team sync maps `dk-platform-admins`, `dk-platform-operators`, `dk-auditors`.
- No `temp-*` group dependency.

5. Kiali
- OIDC is enabled.
- RBAC is enabled (`disable_rbac: false`).
- TLS verify is enabled (`insecure_skip_verify_tls: false`) with trusted CA bundle.

6. Harbor
- OIDC is enabled (`auth_mode=oidc_auth`).
- `oidc_admin_group=dk-platform-admins`.
- Harbor trusts Keycloak CA (`caBundleSecretName` path wired).

## Breakglass operations

If identity plane is degraded:
- Use the environment's out-of-band emergency access path. The exact procedure is intentionally omitted from this public mirror.
- Recover Keycloak/Vault/Argo GitOps state.
- Exit breakglass and return to normal OIDC + GitOps workflow.

## Evidence requirements

For every onboarding/cutover iteration, add an evidence note under:
- `docs/evidence/YYYY-MM-DD-platform-access-onboarding-<deployment>.md`

Include:
- exact commit seeded to Forgejo
- Proxmox validation command outputs (summarized)
- pass/fail status for each component in the checklist
