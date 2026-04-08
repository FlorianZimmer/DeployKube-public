# Cluster Access Contract (OIDC + GitOps RBAC + Admission Guardrails + Breakglass)

Last updated: 2026-02-27  
Status: Implemented (Phase 0 foundations); Planned (follow-ups)

This document turns the access-model idea (`docs/ideas/2025-12-25-cluster-access-rbac-breakglass.md`) and the roadmap requirement (`docs/design/cloud-productization-roadmap.md`) into a single, implementable “access contract” for DeployKube.

## Tracking

- Canonical tracker: `docs/component-issues/access-guardrails.md`

Related:
- Multitenancy lifecycle (support sessions, offboarding): `docs/design/multitenancy-lifecycle-and-data-deletion.md`
- Multitenancy GitOps/Argo boundaries (tenant PR flow + AppProjects): `docs/design/multitenancy-gitops-and-argo.md`

## Goals

DeployKube must treat cluster access as a **product feature** with an explicit contract:

1. **RBAC changes via Git only (four-eyes)**  
   Every permission model change (Kubernetes RBAC, Argo RBAC/projects, Vault policy mappings, Forgejo repo/team governance) is made by PR and approved by a second person.

2. **Prevent kubectl bypass (admission controls)**  
   Even if someone has kubectl access, they must not be able to “self-grant” more privilege by editing RBAC or other access-critical objects directly.

3. **Breakglass entry and rotation**  
   There is always a way in when IAM breaks, but it is auditable, controlled, and does not become the day-to-day access path.

Additional product requirements:
- **One architecture / one workflow** that works from “single admin cluster” → “multi-tenant” → “hosted multi-customer”.
- **Remote support readiness** (a future “one button” support enablement must fit without redesign).
- **Backup + restore** procedures that explicitly cover access state.

## Non-goals (for Phase 0)
- Perfect prevention of all insider threats (cluster-admin can always destroy guardrails if they have it).
- A full “JIT/TTL access grant” controller (we design for it but do not require it to ship Phase 0).
- A full tenant API (CRDs like `Tenant` / `SupportSession`) – this design stays compatible with that future.

## The single architecture (what we standardize on)

### Invariants (apply everywhere)

1. **AuthN: OIDC everywhere for humans**  
   Humans authenticate with Keycloak OIDC; no long-lived kubeconfigs for day-to-day access.

2. **AuthZ: group-based RBAC everywhere**  
   Kubernetes (and other systems) bind **groups**, not individual users.

3. **Change control: Git is the only “authorization change lever”**  
   Access-critical mappings are expressed as code and changed by PR.

4. **Bypass prevention: the cluster enforces “only GitOps may change access”**  
   Admission guardrails block manual edits to access-critical objects.

5. **Breakglass is the only exception**  
   Breakglass credentials exist, are stored out-of-band, and have a rotation + readiness drill.

### What counts as “authorization state” (must be Git-managed)

For Phase 0 we define authorization state as:
- Kubernetes RBAC resources (`Role*`, `ClusterRole*`, `RoleBinding*`, `ClusterRoleBinding*`) and the automation that manages them.
- Admission guardrails that protect the above.
- Argo CD access boundaries (RBAC config + AppProjects) and any “local admin” breakglass enabling/disabling.
- Vault identity/policy mappings that grant platform access.
- Forgejo repo/branch governance that enforces four-eyes for access-critical paths.

Identity state (users, MFA, upstream IdP federation) lives in Keycloak/external IdP. Group membership governance must exist, but **we do not require “all group membership edits are GitOps-managed” in Phase 0** to keep the system deployable in customer environments where identity is external. Instead:
- DeployKube defines **which groups exist** and what they mean (Git-managed).
- The customer/provider defines **who is in those groups** (IdP-governed).

## System architecture (at a glance)

```mermaid
flowchart TB
  subgraph Git["Authoritative Git (Forgejo in product mode)"]
    PR["PR with required approvals"]
    Main["main branch (protected)"]
  end

  subgraph IAM["Identity"]
    KC["Keycloak (OIDC issuer)"]
  end

  subgraph GitOps["GitOps Control Plane"]
    Argo["Argo CD (applies desired state)"]
  end

  subgraph K8s["Kubernetes API (cluster)"]
    APIServer["kube-apiserver\n(OIDC enabled)"]
    VAP["ValidatingAdmissionPolicy\n(access guardrails)"]
    RBAC["RBAC objects\n(groups → roles)"]
  end

  Human["Human operator / tenant admin"] -->|OIDC login| KC
  Human -->|kubectl (OIDC token)| APIServer
  KC -->|JWT/claims| APIServer

  PR --> Main
  Main --> Argo
  Argo -->|apply| APIServer

  VAP --> APIServer
  RBAC --> APIServer
```

Key point: **The cluster enforces that only the GitOps controller identity can change access-critical objects**, so a human with kubectl cannot bypass four-eyes by directly editing RBAC.

## The single workflow (apply to “everything”)

### Day-to-day authorization change
1. Open a PR that changes access state under the “RBAC-critical” paths (see below).
2. Obtain the required approvals (at least two-person review; CODEOWNERS recommended).
3. Merge to `main`.
4. Argo CD reconciles the change.
5. Evidence is captured (Argo Synced/Healthy + a smoke check for the access guardrails).

### Emergency (“breakglass”) workflow
1. Declare an incident + start evidence capture (ticket/ID + who opened breakglass).
2. Retrieve breakglass credential via the custody process.
3. Use it only to restore the normal workflow (OIDC, GitOps, guardrails).
4. Close incident and rotate the breakglass credential (or complete a scheduled rotation if no use occurred).

## RBAC-critical paths (four-eyes enforcement)

These paths are “access-contract critical” and MUST require two approvals in the authoritative Git server:
- `platform/gitops/components/shared/rbac/**`
- `platform/gitops/components/platform/argocd/**` (RBAC/OIDC and breakglass toggles)
- `platform/gitops/components/platform/keycloak/**` (OIDC issuer behavior, groups/claims)
- `platform/gitops/components/secrets/**` and `platform/gitops/components/shared/**` where Vault/ESO policies and access-related Jobs live
- New in this design: `platform/gitops/components/shared/access-guardrails/**` (admission policies)

Implementation note: in product mode, this is enforced by Forgejo protected branches + required approvals (and ideally CODEOWNERS). In the current “GitHub → Forgejo mirror” workflow, the same rule must be enforced in the upstream system that produces the mirrored `main` snapshot.

## Kubernetes access: authentication (OIDC)

### Default: OIDC is the only human auth path

Humans use OIDC tokens issued by Keycloak; we stop distributing “admin kubeconfig” files for day-to-day use.

**Keycloak requirements**
- A Keycloak client for Kubernetes API auth (suggested client ID: `kubernetes-api`).
- Recommended realm: `deploykube-admin`.
- The client must include a `groups` claim in the ID/access token (already used elsewhere).
- MFA must be enforced at the realm/policy level for admin roles (customer/provider policy).

**kube-apiserver requirements**
- Configure OIDC issuer + client ID + claims:
  - issuer: `https://keycloak.<env>.<baseDomain>:8443/realms/<realm>`
  - client ID: `kubernetes-api`
  - username claim: `preferred_username` (or `email`, but keep stable)
  - groups claim: `groups`
- Ensure the API server trusts the Keycloak TLS chain (Step CA root already exists in-repo).

**kubectl UX**
- Standardize on a single kubeconfig style: `exec` plugin to fetch tokens (no static tokens).
- Ship a helper script in `shared/scripts/` to generate kubeconfigs from the deployment contract:
  - reads Keycloak issuer URL + Kubernetes API endpoint
  - renders a kubeconfig skeleton that uses the chosen exec plugin
  - implementation: `shared/scripts/generate-oidc-kubeconfig.sh` (uses a fixed loopback callback port 18000, prints the auth URL, and does not auto-open a browser)
- Ship a repeatable workstation-side runtime smoke:
  - `shared/scripts/smoke-kubernetes-oidc-runtime.sh` verifies end-to-end OIDC auth + `groups` claim visibility via `kubectl auth whoami`.
- Ship a continuous in-cluster runtime smoke:
  - `platform/gitops/components/shared/access-guardrails/smoke-tests/base/cronjob-oidc-runtime-validation.yaml`.
  - Runs in `access-guardrails-system`, obtains an OIDC token via `client_credentials` (client secret from `Secret/k8s-oidc-runtime-smoke-client`), then validates `kubectl auth whoami` group mapping and representative `kubectl auth can-i` checks.
  - Evidence should be captured per environment under `docs/evidence/YYYY-MM-DD-oidc-runtime-validation-{dev,prod}.md`.

Dev/Prod note: OIDC is configured in Stage 0 inputs because it is an API server flag, not a GitOps resource. This is one of the few acceptable Stage 0 responsibilities because it defines the cluster’s access plane.

## Kubernetes access: authorization (RBAC)

### Group model (canonical)

Use the `dk-*` groups as the cross-system contract. The current cluster already carries these in `platform/gitops/components/shared/rbac/base/clusterrolebindings.yaml`.

At minimum (Phase 0):
- `dk-platform-admins`
- `dk-platform-operators`
- `dk-security-ops`
- `dk-auditors`
- `dk-support` (reserved; no access by default until explicitly bound)

For multi-tenant, extend with namespaced groups:
- `dk-tenant-<tenantId>-admins`
- `dk-tenant-<tenantId>-developers`
- `dk-tenant-<tenantId>-viewers`
- `dk-tenant-<tenantId>-support` (support scoped to a tenant)

Roles and personas are defined in `docs/design/rbac-architecture.md`. This document focuses on enforcing the workflow/guardrails.

### Namespace scoping (single pattern)

We keep one scalable pattern for namespace access:
- Namespaces are labeled with:
  - `darksite.cloud/rbac-profile={platform,app,tenant}`
  - if `rbac-profile=app`: `darksite.cloud/rbac-team=<team>`
  - if `rbac-profile=tenant`: `darksite.cloud/tenant-id=<orgId>` and `darksite.cloud/project-id=<projectId>`
- The existing `rbac-namespace-sync` CronJob (Git-managed) applies RoleBindings based on those labels and is scale-safe (hash-annotated RoleBindings; unchanged namespaces are skipped).

This keeps the “access change lever” small:
- To create a new tenant namespace: add the namespace manifest (with labels) by PR.
- To change who can access it: change group membership in IdP (or later via Git-managed `Tenant` objects).
- To change what access means: change the RBAC template logic by PR (four-eyes).

## Preventing kubectl bypass (admission guardrails)

### Principle

Humans may have kubectl access, but they must not be able to:
- create/modify RBAC objects directly
- grant `cluster-admin` (or equivalent “superuser”) outside breakglass
- disable/modify the guardrails themselves

### Implementation choice (low complexity)

Use Kubernetes **built-in** admission controls:
- `admissionregistration.k8s.io/v1` `ValidatingAdmissionPolicy`
- `ValidatingAdmissionPolicyBinding`

This avoids introducing Kyverno/Gatekeeper in Phase 0 just to protect RBAC.

### Policy set (Phase 0)

1) **RBAC mutation lock**
- Deny create/update/delete of:
  - `rbac.authorization.k8s.io/{clusterroles,clusterrolebindings,roles,rolebindings}`
- Allow only if the request comes from:
  - Argo CD application controller ServiceAccount (GitOps apply identity)
  - the RBAC automation ServiceAccount (`rbac-system/rbac-namespace-sync`)
  - required control-plane controllers:
    - `system:kube-controller-manager` for `ClusterRole` aggregation-rule `UPDATE` and namespace-teardown `DELETE` of namespaced RBAC objects
    - `system:serviceaccount:kube-system:namespace-controller` for namespace-teardown `DELETE` of namespaced RBAC objects
  - scoped operator exceptions required for bootstrap/reconciliation:
    - `system:serviceaccount:istio-operator:istio-operator` to `CREATE`/`UPDATE` Istio RBAC objects in `istio-system` with `istio*`/`istiod*` names
    - `system:serviceaccount:cnpg-system:cnpg-operator-cloudnative-pg` to `CREATE`/`UPDATE` namespaced RBAC objects carrying `cnpg.io/cluster` labels
  - breakglass identities (see below)

2) **Guardrail self-protection**
- Deny create/update/delete of:
  - `admissionregistration.k8s.io/{validatingadmissionpolicies,validatingadmissionpolicybindings}`
  - `admissionregistration.k8s.io/{mutatingwebhookconfigurations,validatingwebhookconfigurations}`
  - `apiextensions.k8s.io/customresourcedefinitions`
- Allow GitOps controller identity and breakglass, plus narrow controller exceptions required for webhook/CRD reconciliation:
  - `system:serviceaccount:policy-system:kyverno-admission-controller` to `UPDATE` Kyverno webhook configurations named `kyverno-*`
  - `system:serviceaccount:external-secrets:external-secrets-cert-controller` to `UPDATE` validating webhook configurations named `externalsecret-validate` and `secretstore-validate`
  - `system:serviceaccount:cnpg-system:cnpg-operator-cloudnative-pg` to `UPDATE` CNPG webhook configurations named `cnpg-*`
  - `system:serviceaccount:metallb-system:metallb-controller` to `UPDATE` `*.metallb.io` CRDs and `metallb-webhook-configuration`
  - `system:serviceaccount:istio-operator:istio-operator` to `CREATE`/`UPDATE` `*.istio.io` CRDs and Istio webhook configurations (`istio-*`, `istiod-*`, `istio-sidecar-injector`)
  - `system:serviceaccount:istio-system:istiod` to `UPDATE` Istio webhook configurations (`istio-*`, `istiod-*`, `istio-sidecar-injector`)
  - `system:serviceaccount:cert-manager:cert-manager-cainjector` to `UPDATE` cert-manager webhook configurations (`cert-manager-webhook`)
  - Keep this exception set minimal and audit-friendly; the policy manifest under `platform/gitops/components/shared/access-guardrails/base/` is runtime truth.

3) **No accidental cluster-admin**
- Deny `CREATE`/`UPDATE` of RoleBindings/ClusterRoleBindings that reference `cluster-admin`, unless:
  - the actor is breakglass, or
  - the actor is Argo CD and both conditions hold:
    - label `deploykube.gitops/allow-cluster-admin=true`
    - binding name is explicitly allow-listed (`platform-admins-cluster-admin`)

### Breakglass identities (for admission purposes)

Admission allows bypass only for:
- `system:masters` (offline client cert kubeconfig)
- `kubeadm:cluster-admins` (offline client cert kubeconfig on kubeadm-style clusters; treat with the same custody/rotation discipline as breakglass)

## Breakglass (entry, custody, rotation, readiness)

Breakglass exists to recover from IAM or GitOps failure, not to do normal work.

### Breakglass identity

DeployKube breakglass is offline-only:

- A Kubernetes admin kubeconfig (client cert) stored out-of-band.
- Admission recognizes the offline breakglass group (typically `system:masters`, and on kubeadm-style clusters `kubeadm:cluster-admins`) as bypass.
- This is the “last resort”.

### Custody model (recommendation)

To keep the process simple but meaningful:
- Store offline breakglass kubeconfig in a system that supports two-person access (e.g., split custody in a password manager / offline vault / physical envelope).
- Require an incident/ticket ID for retrieval.

Hosted multi-customer note: prefer split custody between provider and customer for regulated environments.

### Bootstrap custody acknowledgement (enforced on prod)

For Proxmox/Talos, Stage 0 writes the offline Kubernetes breakglass kubeconfig to `tmp/kubeconfig-prod`. Immediately after deployment, the operator must:

1. store `tmp/kubeconfig-prod` out-of-band, and
2. record an operator attestation with `shared/scripts/breakglass-kubeconfig-custody-ack.sh` (writes evidence under `docs/evidence/`).

The Proxmox/Talos bootstrap orchestrator refuses to run Stage 1 until this acknowledgement exists and matches the current kubeconfig SHA256.

### Rotation and readiness

Minimum bar:
- Document a rotation cadence (e.g., quarterly) and perform at least one rotation drill per year.
- Perform a readiness drill after each rotation:
  - retrieve credential via custody process
  - run a read-only command (`kubectl get nodes`)
  - re-seal / re-store

Rotation mechanics depend on the cluster substrate (Talos vs kind). This design requires a documented substrate-specific SOP under `docs/toils/` once implemented.

## Remote access & future “one button support”

### Network stance (Phase 0)
- Kubernetes API is not exposed to the public internet.
- Remote access happens only via an authenticated network path (customer VPN, provider VPN, or a dedicated support tunnel).

### Future: support access as a first-class workflow (no redesign)

We make “support access” fit the same architecture:
- Authorization is a group binding (e.g., `dk-tenant-<id>-support` bound to that tenant’s namespaces).
- Enablement is a PR (four-eyes) authored by a UI later.
- Network access is a separately controlled “support tunnel” component (likely WireGuard) that can be enabled/disabled per session.

Design constraints for the future VPN/tunnel component:
- Default-off.
- Produces short-lived credentials (session-limited peers).
- Can be enabled by committing a single object (future: `SupportSession`) that a controller reconciles.
- Supports a customer approval action that results in a Git change (the “button press” creates a PR).

## Backup and restore (access plane)

Access recovery must work even if the cluster is rebuilt.

### What must be backed up
- **Git**: the authoritative Git repository containing `platform/gitops/**` (Forgejo DB + repositories if Forgejo is in-cluster).
- **Keycloak**: Keycloak Postgres (CNPG backups) + realm templates in Git.
- **Vault**: Vault Raft snapshots + unseal/transit recovery material (already has a backup job baseline).
- **Argo CD**: Argo CD configuration and critical Secrets (but should be reconstructible from Git + Vault).
- **Breakglass**: offline kubeconfig stored out-of-band (not inside the cluster).

### Restore outline (Phase 0)
1. Restore base cluster + GitOps control plane (Stage 0/1).
2. Restore Vault (or re-bootstrap and then restore data) so ESO can project secrets.
3. Restore Keycloak DB (or re-bootstrap realms/clients if DB is new) so OIDC works.
4. Restore Forgejo (if in-cluster) so Argo has the repo.
5. Trigger Argo to resync (`platform-apps`).
6. Validate:
   - OIDC login works
   - Admission guardrails are enforcing
   - RBAC group bindings exist

## Implementation plan (repo changes)

This section is intentionally concrete and low-complexity.

### Step 0 — Decide the “authoritative Git” for approvals (product requirement)
- **Product mode**: Forgejo is authoritative; protect `main`, require 2 approvals for RBAC-critical paths.
- **Current repo mode**: GitHub PR approvals must be enforced upstream **and** the Forgejo seeding mechanism must be treated as privileged (only a small ops/security set can run it).

### Step 1 — Add Kubernetes OIDC client in Keycloak
- Extend the `deploykube-admin` realm template to include a `kubernetes-api` OIDC client.
- Ensure the groups claim is present.
- Document expected issuer URL and client ID in this doc and in `docs/design/rbac-architecture.md` if needed.

### Step 2 — Enable OIDC on the Kubernetes API (Stage 0 inputs)
- **Dev (kind)**: patch `bootstrap/mac-orbstack/cluster/kind-config.yaml` (or `bootstrap/mac-orbstack/cluster/kind-config-single-worker.yaml`) to configure API server OIDC flags.
- **Prod (Talos)**: update Talos machine config generation to set kube-apiserver OIDC flags and CA trust for the issuer.

### Step 3 — Ship admission guardrails as GitOps manifests
- Create new component: `platform/gitops/components/shared/access-guardrails/`
  - `ValidatingAdmissionPolicy` + bindings for:
    - RBAC mutation lock
    - guardrail self-protection
    - cluster-admin binding restrictions
- Ensure Argo CD and `rbac-namespace-sync` are allowed identities.
- Add a small smoke Job (or validation script) proving:
  - a non-privileged identity cannot create a RoleBinding
  - GitOps controller identity can

### Step 4 — Breakglass SOPs and evidence hooks
- Add a private operational runbook for offline breakglass access (intentionally omitted from the public mirror).
- Add a “breakglass readiness drill” runbook and schedule.
- For Argo/Vault/Keycloak/Forgejo, ensure existing component breakglass mechanisms are documented and have rotation steps (tracked in component issues where missing).

### Step 5 — Multi-tenant extensions (follow-up)
- Standardize tenant labels (`darksite.cloud/tenant-id`) and tenant group naming.
- Define a minimal “tenant access profile” (admin/dev/view) and make `rbac-namespace-sync` support it without exceptions. (Implemented 2026-01-14.)
- Make `rbac-namespace-sync` reconciliation scale-safe (avoid steady-state periodic writes; add backoff under API pressure). (Implemented 2026-01-20; evidence:.)
- Reserve the `dk-support`/`dk-tenant-*-support` groups and document the intended future “SupportSession” workflow.

## Recommendations for open decisions (Phase 0)

| Decision | Recommendation | Why (short) |
| --- | --- | --- |
| Keycloak realm for Kubernetes OIDC | Use `deploykube-admin` | Already the platform realm for Argo/Forgejo/Vault/Grafana; adding one more client is lowest-complexity. |
| kubectl exec plugin standard | Use `kubelogin` via the `kubectl oidc-login` plugin | Matches existing RBAC docs and is a widely used, generic OIDC flow for kubectl. |
| Identities allowed to mutate RBAC | Keep baseline allow-list minimal (Argo CD + `rbac-namespace-sync` + breakglass) and add only narrowly scoped system/operator exceptions required for reconciliation | Supports GitOps-only RBAC changes while avoiding bootstrap/runtime deadlocks from controller-owned RBAC reconciliation. |
| Prevent bypass via `forgejo-seed-repo.sh` | Treat seeding as a privileged deployment action (defense-in-depth) | Mirror seeding can bypass PR controls; product mode must move to “Forgejo is authoritative”. |

### Concrete recommendations

1) **Keycloak OIDC realm**
- Use realm `deploykube-admin`.
- Add a `kubernetes-api` OIDC client to `platform/gitops/components/platform/keycloak/realms/templates/deploykube-admin.yaml`.
- Make it a **public** client using Authorization Code + PKCE (avoid distributing a client secret in kubeconfigs).
- Redirect URIs: loopback + (optional) localhost callback for CLI flows (keep this list tight).

2) **kubectl OIDC plugin**
- Standardize on `kubectl oidc-login` (krew) and generate kubeconfigs that use the exec plugin.
- Use exec API `client.authentication.k8s.io/v1` (fall back to `v1beta1` only if a customer’s kubectl is very old).
- Avoid non-standard “groups scope” flags unless proven necessary; the groups claim should be present via Keycloak protocol mappers.

3) **RBAC mutation allow-list (admission)**

Allowed identities (recommended baseline):
- `system:serviceaccounts:argocd` (GitOps apply identities; group is stable across chart refactors)
- `system:serviceaccount:rbac-system:rbac-namespace-sync` (namespace RoleBinding generator)
- breakglass: `system:masters` (offline cert) and `kubeadm:cluster-admins` (kubeadm-style clusters)
- plus explicit, tightly scoped controller exceptions required for control-plane/operator reconciliation

Example CEL pattern (illustrative baseline; real policy must include scoped controller exceptions):
```cel
request.userInfo.groups.exists(g, g == "system:serviceaccounts:argocd") ||
request.userInfo.username == "system:serviceaccount:rbac-system:rbac-namespace-sync" ||
request.userInfo.groups.exists(g, g == "system:masters") ||
request.userInfo.groups.exists(g, g == "kubeadm:cluster-admins")
```

Important nuance: to keep this meaningful, **normal roles must not be able to mint tokens for the allowed ServiceAccounts** (e.g., via `serviceaccounts/token` or legacy `kubernetes.io/service-account-token` Secrets) in the GitOps/control-plane namespaces.

4) **Seeding bypass (`forgejo-seed-repo.sh`)**

`forgejo-seed-repo.sh` can push arbitrary desired state to the in-cluster Forgejo mirror. In the current “GitHub → Forgejo mirror” workflow, treat seeding as privileged:
- Restrict who can run it (small ops/security set or CI only).
- Require it to be run only from a reviewed `main` commit (PR merged) and capture evidence of who ran it and when.
- Long-term (product mode): Forgejo is authoritative and enforces approvals natively; the mirror seeding path becomes unnecessary.
