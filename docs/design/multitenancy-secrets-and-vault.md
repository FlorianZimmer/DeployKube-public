# DeployKube Multitenancy Secrets + Vault — Path Conventions, Auth, ESO, Rotation, Offboarding

<a id="dk-mtsv-top"></a>

Last updated: 2026-01-15  
Status: **Design (Phase 0/1 foundations exist; tenant-scoped authZ + scoped-store scaffolding implemented)**

## Tracking

- Canonical tracker: `docs/component-issues/multitenancy-secrets-and-vault.md`

## Related docs (inputs / constraints)

- Core tenancy model and label invariants: `docs/design/multitenancy.md`
- Label registry (contract): `docs/design/multitenancy-label-registry.md`
- Tenant lifecycle and deletion semantics: `docs/design/multitenancy-lifecycle-and-data-deletion.md`
- Tenant storage + S3 primitive (Vault/ESO safety gotchas): `docs/design/multitenancy-storage.md`
- Access-plane guardrails + breakglass posture: `docs/design/cluster-access-contract.md`
- RBAC groups/personas (Keycloak `dk-*` contract): `docs/design/rbac-architecture.md`
- Policy engine baseline constraints (tenant namespace scoping): `docs/design/policy-engine-and-baseline-constraints.md`
- DR/backups retention reality: `docs/design/disaster-recovery-and-backups.md`
- Bootstrap-only SOPS material (steady-state uses Vault/ESO): `docs/design/deployment-secrets-bundle.md`
- Component truth (current Vault + ESO wiring):
  - `platform/gitops/components/secrets/vault/README.md`
  - `platform/gitops/components/secrets/external-secrets/README.md`

---

## Scope / ground truth

This design is repo-grounded. It defines:

- the tenant secret path contract in Vault,
- how humans and automation authenticate (Keycloak groups → Vault policies; K8s auth roles/policies),
- how secrets are projected into Kubernetes (ESO patterns and guardrails),
- lifecycle semantics (rotation, revocation, offboarding wipe).

It does **not** claim live cluster state, and it stays honest about shared-cluster limits (Tier S) from `docs/design/multitenancy.md` and `docs/design/multitenancy-lifecycle-and-data-deletion.md`.

MVP scope reminder:
- Queue #11 implements **Tier S (shared-cluster)** guardrails for secrets (Vault path contract + auth/policy model + ESO safety posture).
- Tier D/H (dedicated clusters and/or hardware separation) are out of scope for the MVP, but Tier S work must not block them:
  - keep the tenant subtree contract `tenants/<orgId>/...` tier-agnostic (a dedicated tier may use a separate Vault instance, but the logical shape stays stable),
  - avoid “cluster-specific” IDs in Vault paths (do not bake `deploymentId` into `orgId`/`projectId`).

---

## 1) Goals

1. Prevent cross-tenant secret access (T1/T3) in shared clusters:
   - a tenant cannot read another tenant’s secrets via Kubernetes, Vault, ESO, or GitOps.
2. Maintain a cloud-like org/project mental model:
   - secret ownership and access follow `orgId` and `projectId`.
3. Keep authorization state GitOps-managed:
   - Vault auth methods, roles, policies, and group mappings change by PR (access-plane changes).
4. Make tenant onboarding low-toil:
   - adding an org/project is a PR + automatic reconciliation (no manual Vault auth/policy edits).
5. Define a safe rotation/offboarding story:
   - rotate credentials without ad-hoc drift, revoke fast on compromise/offboarding, and document wipe semantics.

---

## 2) Non-goals

- Storing tenant secret values in Git (SOPS is bootstrap-only).
- Guaranteeing immediate deletion from historical backups for shared-cluster tenants (see §9; also `docs/design/multitenancy-lifecycle-and-data-deletion.md`).
- Shipping a full “Tenant Secret API” (CRDs/controllers) in v1 (this doc stays compatible with adding it later).
- Solving virtual clusters or workload identity federation (SPIFFE, etc.) in this doc.

---

## 3) Terminology and invariants

### 3.1 Tenancy identifiers

This doc reuses the canonical tenancy identifiers from `docs/design/multitenancy.md`:

- `orgId` — stable tenant/org identifier (namespace label `darksite.cloud/tenant-id`)
- `projectId` — stable project identifier (namespace label `darksite.cloud/project-id`, admission-enforced)

Treat identifiers as stable (no in-place rename). Renames are “create new + migrate”. (`docs/design/multitenancy.md#dk-mt-label-immutability`)

Identifier value constraints (must be safe for Kubernetes resource names, Keycloak group names, and Vault paths):
- `orgId`, `projectId`, `appId` must be valid DNS labels:
  - `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
  - max length 63
  - no `/`, `.`, `_`, or uppercase
- `env` should be a small controlled set (`dev`, `staging`, `prod`).

### 3.2 Vault KV v2 path notation (important)

DeployKube uses a KV v2 mount at `secret/` (enabled by the `vault-configure` Job).

Current ESO wiring:
- `ClusterSecretStore/vault-core` sets:
  - `path: secret`
  - `version: v2`
  - so `ExternalSecret.spec.data[].remoteRef.key` is **relative to the mount**, e.g. `garage/s3` → `secret/data/garage/s3`.

This doc uses:

- **Logical key path** (Vault UI/CLI and ESO `remoteRef.key`): `tenants/<orgId>/...`
- **Policy/API path** (Vault ACL policy): `secret/data/tenants/<orgId>/...` and `secret/metadata/...` for list

### 3.3 Authorization state vs secret values (GitOps boundary)

- **Authorization state** (who can access what): GitOps-managed (PR-reviewed), because it is part of the access plane.
  - Examples: Vault auth methods, roles, policies, identity/group mappings; ESO store objects and guardrails.
- **Secret values**: operational state inside Vault (not stored in Git).
  - Secret *references* (e.g., which key is projected into which namespace) are Git-managed.

This aligns with `docs/design/cluster-access-contract.md` and the repo’s “Vault + ESO” steady-state posture.

### 3.4 Boundary statement (tenant workloads vs Vault)

Default tenant workload pattern is:

**Vault → ESO → Kubernetes Secret → workload**

Direct Vault access from tenant workloads is an exception (see §6.4) and must be justified (dynamic secrets, very frequent rotation, etc.).

### 3.5 Tenant UX boundary (humans vs Vault)

- Vault is the system-of-record for **tenant secret values**.
- Tenant humans (org/project admins; optionally developers) authenticate via Keycloak and may use the Vault UI/CLI to create/update secrets **only within their allowed tenant subtree**.
- Tenants must not be able to change Vault authorization state (auth methods, roles, policies, group mappings); those are GitOps-managed access-plane changes.
- Secret projection into Kubernetes remains platform-owned by default (Phase 0/1), and tenants must not be able to create ESO resources in tenant namespaces (see §7).

---

## 4) Tenant Vault path conventions (contract)

### 4.1 Top-level tenant subtree

All tenant-owned secrets live under:

- `tenants/<orgId>/...`  (logical key path)

This subtree is the canonical “tenant boundary” for Vault policies and automation.

### 4.2 Org-level vs project-level scopes

Recommended hierarchy:

- **Org scope** (shared across projects):
  - `tenants/<orgId>/shared/<name>`
  - `tenants/<orgId>/s3/<bucketName>` (tenant-facing S3 credentials; aligns with `docs/design/multitenancy-storage.md`)

- **Project scope**:
  - `tenants/<orgId>/projects/<projectId>/shared/<name>`
  - `tenants/<orgId>/projects/<projectId>/env/<env>/<name>` (optional)
  - `tenants/<orgId>/projects/<projectId>/apps/<appId>/<name>` (optional)

Notes:
- Keep `env` in a small controlled set (e.g. `dev`, `staging`, `prod`).
- Only introduce `apps/<appId>` when a project has enough workloads that secrets become unreviewable without further structure.

### 4.3 Reserved subpaths (do not use for arbitrary apps)

To keep future automation and wipe semantics unambiguous, reserve:

- `tenants/<orgId>/sys/*` — future: tenant-scoped system material (wrapper keys, metadata)
- `tenants/<orgId>/projects/<projectId>/sys/*` — future: project-scoped automation metadata

### 4.4 Policy path mapping (KV v2)

The above maps to Vault ACL paths:

- data:
  - `secret/data/tenants/<orgId>/*`
- metadata/list:
  - `secret/metadata/tenants/<orgId>/*`

---

## 5) Vault auth + policies for humans (Keycloak groups → Vault)

### 5.1 Group contract (source of truth)

Keycloak group naming follows `docs/design/multitenancy.md#8-1-keycloak-groups`:

- Org level:
  - `dk-tenant-<orgId>-admins`
  - `dk-tenant-<orgId>-viewers` (optional)
  - `dk-tenant-<orgId>-support` (reserved)

- Project level:
  - `dk-tenant-<orgId>-project-<projectId>-admins`
  - `dk-tenant-<orgId>-project-<projectId>-developers`
  - `dk-tenant-<orgId>-project-<projectId>-viewers`
  - `dk-tenant-<orgId>-project-<projectId>-support` (reserved)

### 5.2 Auth method direction (OIDC vs JWT)

Preferred: Vault **OIDC** auth bound to Keycloak (human-friendly UI login). (`docs/design/rbac-architecture.md`)

Repo reality today:
- Vault **JWT** auth mount exists for automation (`auth/jwt`; see `platform/gitops/components/secrets/vault/config/scripts/jwt-config.sh`).
- Vault **OIDC** auth mount exists for human login (`auth/oidc`, JWT auth backend in OIDC mode; see `platform/gitops/components/secrets/vault/config/oidc-config.yaml`).
- Tenant-scoped policies and Keycloak group alias mapping are reconciled from the tenant registry (see `platform/gitops/components/secrets/vault/config/tenant-rbac.yaml`).

This design assumes group membership is available in a token claim (`groups`) either way.

Operational note (human OIDC):
- Vault’s OIDC role must whitelist **explicit** redirect URIs (no wildcards), including the local Vault CLI callback:
  - `http://127.0.0.1:8400/oidc/callback` (and optionally `http://localhost:8400/oidc/callback`)
  - Vault UI callback(s) under `https://vault.<env>.internal.example.com/...`
- See `docs/toils/vault-cli-oidc-login.md` for the supported CLI login flow.

### 5.3 Policy model (recommended defaults)

Define Vault policies as the primitive, and map Keycloak groups to them.

Recommended policy set:

- Org admin policy `tenant-<orgId>-rw`
  - `create, read, update, delete, list` on `secret/data/tenants/<orgId>/*`
  - `read, list` on `secret/metadata/tenants/<orgId>/*`

- Project admin policy `tenant-<orgId>-project-<projectId>-rw`
  - same, but scoped to `secret/data/tenants/<orgId>/projects/<projectId>/*`

- Project developer policy `tenant-<orgId>-project-<projectId>-wo` (write-only by default)
  - `create, update, delete, list` on `secret/data/...`
  - `read, list` on `secret/metadata/...`
  - **no `read` on `secret/data/...`**

If a tenant wants developers to read secrets, introduce a parallel `-ro` policy and bind it to the `viewers` group (do not silently broaden `developers` by default).

### 5.4 Evidence and audit expectations

- Authorization state changes (policies, auth roles, group mappings) follow `docs/design/cluster-access-contract.md` evidence discipline.
- Secret values remain in Vault and are not stored in Git.

---

## 6) Vault auth + policies for Kubernetes/automation (K8s auth)

### 6.1 Principle: jobs get narrow policies, short TTL

In-cluster automation authenticates via Vault Kubernetes auth (`auth/kubernetes`) and receives tokens with:

- short TTLs for Jobs/CronJobs (≤ 1h preferred),
- narrow policies scoped to:
  - a tenant org/project subtree, and
  - the operation (read-only vs writer).

Long-running controllers (e.g. ESO) may use longer TTLs for operational stability, but must remain narrowly scoped and treated as a high-value compromise target. (Repo reality today: the ESO role token TTL is `24h`.)

### 6.2 Role naming convention (stable, predictable)

Vault Kubernetes auth roles use:

- `k8s-tenant-<orgId>-project-<projectId>-reader`
- `k8s-tenant-<orgId>-project-<projectId>-writer`
- `k8s-tenant-<orgId>-project-<projectId>-<purpose>` (when splitting further, e.g. `s3-provisioner`)

### 6.3 ESO store patterns (phased)

#### Phase 0 (repo reality): one broad store, tenants must not author ESO resources

Current implementation:
- `ClusterSecretStore/vault-core` uses Vault role `external-secrets` with policy:
  - `read` on `secret/data/*`
  - `list` on `secret/metadata/*`
  (created in `platform/gitops/components/secrets/vault/config/scripts/configure.sh`)

Security implication:
- `ExternalSecret` becomes a “read-anything” capability if a tenant can create it.
- Therefore, in Phase 0/1: tenants must not be able to create/modify ESO CRDs (see §7).

#### Phase 1+ (repo reality: scaffolding exists): scoped stores per org/project (blast radius reduction)

Introduce scoped stores so an `ExternalSecret` can only read within one org/project boundary.

Decision: **ClusterSecretStore per project**
- Store name: `vault-tenant-<orgId>-project-<projectId>`
- Vault role: `k8s-tenant-<orgId>-project-<projectId>-eso`
  - bound to the ESO ServiceAccount (`external-secrets/external-secrets`)
  - policy can only read:
    - `secret/data/tenants/<orgId>/projects/<projectId>/*`

Why:
- avoids per-namespace ServiceAccount sprawl,
- keeps a clear and enforceable “store name ↔ tenant labels” contract (Kyverno/Argo).

Repo reality today:
- Vault reconciliation exists to ensure per-project ESO policies + K8s auth roles (`platform/gitops/components/secrets/vault/config/tenant-eso.yaml`).
- A smoke fixture scoped store exists to prove in-boundary reads (`ClusterSecretStore/vault-tenant-smoke-project-demo` in `platform/gitops/components/secrets/external-secrets/config/clustersecretstore-tenant-smoke-project-demo.yaml`).
- Tenant-wide capabilities can use the same pattern at the tenant boundary instead of the project boundary. Current repo reality: Cloud DNS tenant RFC2136 projection uses `ClusterSecretStore/vault-tenant-<orgId>-cloud-dns` with Vault role `k8s-tenant-<orgId>-cloud-dns-eso`, scoped to `secret/data/tenants/<orgId>/sys/dns/rfc2136`.

Default TTL guidance for these scoped ESO roles:
- `token_ttl: 1h`
- `token_max_ttl: 4h`

Deferred alternative (only if we need namespaced scoping): namespaced `SecretStore` per tenant namespace.

### 6.4 Direct Vault access from tenant workloads (exception)

Allowed only when explicitly required (dynamic credentials, very frequent rotation) and must be product-scoped:

- Use a dedicated ServiceAccount and Vault Kubernetes auth role with the narrowest possible policy.
- Prefer “no Vault in app pods” (ESO) unless we have clear baseline constraints for Vault Agent/CSI patterns compatible with PSS restricted posture.

---

## 7) External Secrets Operator (ESO) in tenant namespaces — allowed / forbidden

### 7.1 Core safety rule

Tenants must not be able to use ESO to materialize secrets outside their tenancy boundary.

How we enforce this depends on phase:

- Phase 0 (broad `vault-core` store): forbid tenant creation of ESO CRDs.
- Phase 1+ (scoped stores): may allow tenant-authored `ExternalSecret` with strict constraints.

### 7.2 Forbidden (Phase 0/1; required for shared-cluster tenants)

In namespaces labeled `darksite.cloud/rbac-profile=tenant`:

- Forbidden resources:
  - `external-secrets.io/*` `ExternalSecret`
  - `external-secrets.io/*` `SecretStore`
  - `external-secrets.io/*` `ClusterSecretStore`
  - `external-secrets.io/*` `PushSecret` (and similar write-back features)

Rationale: with a broad store, these are privilege escalation/exfiltration objects. This is called out explicitly in `docs/design/multitenancy-storage.md`.

Enforcement (planned, belt-and-suspenders):
- Argo AppProject resource allow/deny lists for tenant repos.
- Kubernetes RBAC: tenant personas must not have permissions to create/update ESO CRDs (defense against kubectl/breakglass mistakes).
- Kyverno validate policies scoped to tenant namespaces (per `docs/design/policy-engine-and-baseline-constraints.md`), denying ESO CRDs.
- Optionally, VAP for cluster-scoped ESO objects if needed for “hostile tenant” tiers.

### 7.3 Allowed pattern (platform-owned projection)

Platform GitOps authors ExternalSecret objects and projects secrets into tenant namespaces.

Recommended ExternalSecret defaults for tenant projections:

- `refreshInterval: 1h` (or tighter when rotating)
- `target.creationPolicy: Owner`
- `target.deletionPolicy: Delete` (avoid orphaned Secrets when a projection is removed)
- Avoid broad fetch patterns (`dataFrom.find`, etc.); prefer explicit `spec.data[]` mappings to keep review surface narrow.

### 7.4 Phase 1+ optional: tenant-authored `ExternalSecret` with scoped store

If we implement scoped stores (§6.3), we may allow tenants to author `ExternalSecret`, but only if all of the following are enforced:

- Kind restrictions:
  - allow `ExternalSecret` only
  - forbid `SecretStore`, `ClusterSecretStore`, `PushSecret` (and any write-back features)
- Store-name contract:
  - `spec.secretStoreRef.kind` must be `ClusterSecretStore`
  - `spec.secretStoreRef.name` must equal `vault-tenant-<orgId>-project-<projectId>` derived from the namespace labels
- Key-path contract:
  - every `spec.data[].remoteRef.key` must start with `tenants/<orgId>/projects/<projectId>/`
- Fetch-surface restrictions:
  - forbid broad fetch patterns (`spec.dataFrom.*`, generators, find, extract)
  - prefer explicit `spec.data[]` mappings (reviewable surface)
- Budgets:
  - enforce max ExternalSecrets per namespace/project (Kyverno + quotas)

Default remains “platform-owned” until budgets + guardrails exist.

---

## 8) Rotation and revocation

### 8.1 Static KV secrets (default)

Rotation mechanism:

1. Write a new version to the relevant Vault key.
2. ESO refreshes the Kubernetes Secret on its next reconcile.
3. Workloads pick up the new value:
   - preferred: apps read secrets dynamically or have a restart mechanism,
   - otherwise: trigger a rollout restart via a GitOps-approved mechanism (tracked/evidenced).

Revocation:
- remove secret material from Vault (KV v2 metadata delete when you require permanent deletion),
- rotate/revoke downstream credentials in the backing system (S3 keys, DB users, etc.).

### 8.2 Leaked token response (Vault access tokens)

If a Vault token is suspected compromised:

- revoke the token immediately (by accessor if available),
- rotate the auth role or bound service account if the attacker likely has the login JWT,
- rotate impacted secrets/credentials.

Short TTLs are the primary mitigation; do not rely on “we will notice”.

---

## 9) Offboarding and wipe semantics (Vault + ESO)

Deletion terminology (logical disable vs physical wipe vs cryptographic deletion) is defined in `docs/design/multitenancy-lifecycle-and-data-deletion.md#3-3-deletion-terminology`. This section specifies what that means for Vault and ESO.

### 9.1 Offboarding sequence (shared cluster)

1. **Logical disable**
   - remove users from `dk-tenant-<orgId>-*` Keycloak groups,
   - remove/disable Vault mappings and Kubernetes auth roles/policies for that tenant (Git-managed).
2. **Stop projection**
   - remove/disable platform-owned ExternalSecrets targeting tenant namespaces (Git-managed).
3. **Delete Kubernetes tenant namespaces**
   - remove tenant manifests from Git; Argo prunes (namespace deletion removes projected K8s Secrets).
4. **Physical wipe (Vault primary)**
   - permanently delete all KV v2 keys under `tenants/<orgId>/` (KV v2 metadata deletion, not just version delete),
   - delete tenant-scoped Vault policies and Kubernetes auth roles.
   - note: KV v2 deletion is not recursive; an offboarding job must list keys under `secret/metadata/tenants/<orgId>/` and execute `vault kv metadata delete` per key.

### 9.2 What “wipe” does and does not guarantee (shared cluster)

In shared-cluster tenancy (Tier S):

- “Wipe” guarantees:
  - no future access is possible via Vault policies/auth,
  - tenant KV keys are deleted from **active** Vault storage,
  - projected Kubernetes Secrets are deleted with namespace deletion.

- “Wipe” does **not** guarantee:
  - immediate removal from historical Vault raft snapshots or off-cluster backup artifacts (governed by backup retention; `docs/design/disaster-recovery-and-backups.md`),
  - physical zeroization at the storage medium level.

If a tenant requires cryptographic erasure semantics, the recommended offering is Tier D/H (dedicated cluster and/or dedicated Vault instance), or a future design that wraps tenant secrets with per-tenant transit keys and supports key destruction.

---

## 10) Budgets + switch thresholds (required before productizing)

Before enabling shared-cluster onboarding for “real tenants”, record budgets:

- max tenants/orgs/projects per cluster that require Vault policies/stores
- max ESO store objects (ClusterSecretStore/SecretStore) and ExternalSecrets per tenant
- token TTLs vs reconcile load (ESO/Vault)
- acceptable blast radius if the ESO controller is compromised

If budgets are exceeded, switch thresholds are:

- move tenant to dedicated cluster (Tier D/H),
- or allocate a dedicated Vault instance/mount with stricter boundaries.

---

## Appendix A: Example policy snippets (KV v2)

Org admin policy (`tenant-acme-rw`):

```hcl
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/tenants/acme/*" {
  capabilities = ["read", "list"]
}
```

Project developer write-only policy (`tenant-acme-project-payments-wo`):

```hcl
path "secret/data/tenants/acme/projects/payments/*" {
  capabilities = ["create", "update", "delete", "list"]
}

path "secret/metadata/tenants/acme/projects/payments/*" {
  capabilities = ["read", "list"]
}
```

---

## Appendix B: Example ExternalSecret (tenant projection, platform-owned)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: payments-stripe
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-tenant-acme-project-payments
  target:
    name: payments-stripe
    creationPolicy: Owner
    deletionPolicy: Delete
  data:
    - secretKey: STRIPE_API_KEY
      remoteRef:
        key: tenants/acme/projects/payments/env/prod/stripe
        property: apiKey
```
