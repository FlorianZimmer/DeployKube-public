# multitenancy-secrets-and-vault design issues

Canonical issue tracker for:
- `docs/design/multitenancy-secrets-and-vault.md`

Related trackers:
- Multi-tenancy core: `docs/component-issues/multitenancy.md`
- Multi-tenant lifecycle: `docs/component-issues/multitenancy-lifecycle-and-data-deletion.md`
- Multi-tenant storage: `docs/component-issues/multitenancy-storage.md`
- Vault core: `docs/component-issues/vault.md`
- External Secrets Operator: `docs/component-issues/external-secrets.md`
- Access guardrails: `docs/component-issues/access-guardrails.md`
- Kyverno baseline constraints: `docs/component-issues/policy-kyverno.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### guardrails-must-have-before-hostile-tenants
- Ensure Argo AppProjects for tenant repos deny cluster-scoped resources and ESO CRDs as appropriate. (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:d75c54fb02455d23d18972eb74b0dfc57ee9562d55e12744c09f76096fb4963c`)

- If allowing tenant-authored ExternalSecret (Phase 1+), enforce: (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:18f03913ceb2edfd7c6f6981bcea9510c916cec5d57f143b70b7468562f9350a`)

#### offboarding-wipe-semantics
- Implement a tenant offboarding job/runbook that: (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:af44d95448dcbebcccdd0e4abe5f8fb0e89871fc658649b3b1928729eee95f9d`)

#### rotation-revocation-workflows
- Define S3 (Garage/RGW) and DB rotation jobs that write into tenant paths. (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:b8d7e081c5a85298d6c310e490588ba2b1e13c3114b9cc143c652dcb6c52d788`)

#### scoped-eso-stores-blast-radius-reduction
- Decide if/when tenants may author ExternalSecret resources (Phase 1+). (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:15970ce61bcb549ec6e703fbd1f372448ddc087255ede48e5e4149bddec4f8e8`)

#### vault-human-auth-keycloak-vault
- Ensure tenants can manage KV values in their subtree but cannot modify Vault authorization state (auth methods, roles, policies). (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:0c6058890a725f77694048442657c332c03cf0d624525e39854c9cdbb7107d22`)

- Prove end-to-end human login to Vault (OIDC) yields the expected policies from group alias mapping (admin/dev/viewer personas). (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:4dc1e48edd25de6833016a602c8577c12a773d67d4905b24fa24e6e02bfa09eb`)

### Medium

#### renderer-retirement-tenant-api-as-source-of-truth
- Stop treating platform/gitops/apps/tenants/base/tenant-registry.yaml as the primary tenant index for Keycloak/Vault/ESO reconcilers. (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:580b9fcf3da5100fad6c44860040479f0684088ea01849946ed896ae3d0a451f`)

#### rotation-revocation-workflows
- Define leaked-token response steps and automation (token revocation, role disable). (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:618b14233a5425dad622ff2c7fda4de562d2bceb0ca16e168b54ac4b3454d6d2`)

- Standardize secret rotation UX (Vault write + rollout), including evidence capture. (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:2d1029c991020e60b5c41f059b062071d99950c8babe0e592ef437385fc51e69`)

#### tenant-facing-kms-future
- Decide whether a “KMS gateway” is required for compatibility with cloud client SDKs (e.g., AWS KMS API surface) or if exposing transit directly is sufficient. (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:e2874f0fa17b37a13c29b66086486cbb6da971b8998770017ca37bc836b73209`)

- Offer a “cloud-like KMS” primitive to tenants using OpenBao transit: (ids: `dk.ca.finding.v1:multitenancy-secrets-and-vault:a11005b845fdc7c7b22ead3c41896a18edbe3444785cc15b3f997191755b5f0e`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- Stop treating `platform/gitops/apps/tenants/base/tenant-registry.yaml` as the primary tenant index for Keycloak/Vault/ESO reconcilers.\n  - Target API: `Tenant` + `TenantProject` CRDs authored via GitOps (cluster-scoped) are the only inputs; the controller(s) reconcile Keycloak groups, Vault policies/aliases, and per-project ESO stores from those CRs.\n  - Migration: keep publishing a legacy \u201ctenant registry\u201d ConfigMap as a **compatibility output** during cutover, then delete the file-driven path once all consumers are migrated.\n  - Dependency: `docs/component-issues/tenant-provisioner.md` (Tenant API + controllers).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:580b9fcf3da5100fad6c44860040479f0684088ea01849946ed896ae3d0a451f", "last_seen_at": "2026-02-25", "recommendation": "Stop treating platform/gitops/apps/tenants/base/tenant-registry.yaml as the primary tenant index for Keycloak/Vault/ESO reconcilers.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Stop treating platform/gitops/apps/tenants/base/tenant-registry.yaml as the primary tenant index for Keycloak/Vault/ESO reconcilers.", "topic": "renderer-retirement-tenant-api-as-source-of-truth"}
{"class": "actionable", "details": "- Prove end-to-end human login to Vault (OIDC) yields the expected policies from group alias mapping (admin/dev/viewer personas).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:4dc1e48edd25de6833016a602c8577c12a773d67d4905b24fa24e6e02bfa09eb", "last_seen_at": "2026-02-25", "recommendation": "Prove end-to-end human login to Vault (OIDC) yields the expected policies from group alias mapping (admin/dev/viewer personas).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Prove end-to-end human login to Vault (OIDC) yields the expected policies from group alias mapping (admin/dev/viewer personas).", "topic": "vault-human-auth-keycloak-vault"}
{"class": "actionable", "details": "- Ensure tenants can manage KV values in their subtree but cannot modify Vault authorization state (auth methods, roles, policies).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:0c6058890a725f77694048442657c332c03cf0d624525e39854c9cdbb7107d22", "last_seen_at": "2026-02-25", "recommendation": "Ensure tenants can manage KV values in their subtree but cannot modify Vault authorization state (auth methods, roles, policies).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Ensure tenants can manage KV values in their subtree but cannot modify Vault authorization state (auth methods, roles, policies).", "topic": "vault-human-auth-keycloak-vault"}
{"class": "actionable", "details": "- Decide if/when tenants may author `ExternalSecret` resources (Phase 1+).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:15970ce61bcb549ec6e703fbd1f372448ddc087255ede48e5e4149bddec4f8e8", "last_seen_at": "2026-02-25", "recommendation": "Decide if/when tenants may author ExternalSecret resources (Phase 1+).", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide if/when tenants may author ExternalSecret resources (Phase 1+).", "topic": "scoped-eso-stores-blast-radius-reduction"}
{"class": "actionable", "details": "- If allowing tenant-authored `ExternalSecret` (Phase 1+), enforce:\n  - store name matches tenant labels,\n  - remoteRef key prefix matches tenant boundary,\n  - no `dataFrom` / broad fetch patterns,\n  - no store creation and no write-back features.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:18f03913ceb2edfd7c6f6981bcea9510c916cec5d57f143b70b7468562f9350a", "last_seen_at": "2026-02-25", "recommendation": "If allowing tenant-authored ExternalSecret (Phase 1+), enforce:", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "If allowing tenant-authored ExternalSecret (Phase 1+), enforce:", "topic": "guardrails-must-have-before-hostile-tenants"}
{"class": "actionable", "details": "- Ensure Argo AppProjects for tenant repos deny cluster-scoped resources and ESO CRDs as appropriate.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:d75c54fb02455d23d18972eb74b0dfc57ee9562d55e12744c09f76096fb4963c", "last_seen_at": "2026-02-25", "recommendation": "Ensure Argo AppProjects for tenant repos deny cluster-scoped resources and ESO CRDs as appropriate.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Ensure Argo AppProjects for tenant repos deny cluster-scoped resources and ESO CRDs as appropriate.", "topic": "guardrails-must-have-before-hostile-tenants"}
{"class": "actionable", "details": "- Standardize secret rotation UX (Vault write + rollout), including evidence capture.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:2d1029c991020e60b5c41f059b062071d99950c8babe0e592ef437385fc51e69", "last_seen_at": "2026-02-25", "recommendation": "Standardize secret rotation UX (Vault write + rollout), including evidence capture.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Standardize secret rotation UX (Vault write + rollout), including evidence capture.", "topic": "rotation-revocation-workflows"}
{"class": "actionable", "details": "- Define leaked-token response steps and automation (token revocation, role disable).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:618b14233a5425dad622ff2c7fda4de562d2bceb0ca16e168b54ac4b3454d6d2", "last_seen_at": "2026-02-25", "recommendation": "Define leaked-token response steps and automation (token revocation, role disable).", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define leaked-token response steps and automation (token revocation, role disable).", "topic": "rotation-revocation-workflows"}
{"class": "actionable", "details": "- Define S3 (Garage/RGW) and DB rotation jobs that write into tenant paths.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:b8d7e081c5a85298d6c310e490588ba2b1e13c3114b9cc143c652dcb6c52d788", "last_seen_at": "2026-02-25", "recommendation": "Define S3 (Garage/RGW) and DB rotation jobs that write into tenant paths.", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Define S3 (Garage/RGW) and DB rotation jobs that write into tenant paths.", "topic": "rotation-revocation-workflows"}
{"class": "actionable", "details": "- Implement a tenant offboarding job/runbook that:\n  - revokes group mappings and Kubernetes auth roles,\n  - KV v2 metadata-deletes all keys under `tenants/<orgId>/`,\n  - tears down external credentials/buckets,\n  - records evidence and notes backup retention limitations.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:af44d95448dcbebcccdd0e4abe5f8fb0e89871fc658649b3b1928729eee95f9d", "last_seen_at": "2026-02-25", "recommendation": "Implement a tenant offboarding job/runbook that:", "severity": "high", "status": "open", "template_id": "legacy-component-issues.md", "title": "Implement a tenant offboarding job/runbook that:", "topic": "offboarding-wipe-semantics"}
{"class": "actionable", "details": "- Offer a \u201ccloud-like KMS\u201d primitive to tenants using **OpenBao transit**:\n  - per-tenant/per-project transit keys,\n  - policies/roles bound to Keycloak groups (Git-managed authorization state),\n  - key rotation and key destruction (cryptographic erasure semantics).", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:a11005b845fdc7c7b22ead3c41896a18edbe3444785cc15b3f997191755b5f0e", "last_seen_at": "2026-02-25", "recommendation": "Offer a \u201ccloud-like KMS\u201d primitive to tenants using OpenBao transit:", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Offer a \u201ccloud-like KMS\u201d primitive to tenants using OpenBao transit:", "topic": "tenant-facing-kms-future"}
{"class": "actionable", "details": "- Decide whether a \u201cKMS gateway\u201d is required for compatibility with cloud client SDKs (e.g., AWS KMS API surface) or if exposing transit directly is sufficient.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:multitenancy-secrets-and-vault:e2874f0fa17b37a13c29b66086486cbb6da971b8998770017ca37bc836b73209", "last_seen_at": "2026-02-25", "recommendation": "Decide whether a \u201cKMS gateway\u201d is required for compatibility with cloud client SDKs (e.g., AWS KMS API surface) or if exposing transit directly is sufficient.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Decide whether a \u201cKMS gateway\u201d is required for compatibility with cloud client SDKs (e.g., AWS KMS API surface) or if exposing transit directly is sufficient.", "topic": "tenant-facing-kms-future"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- Vault KV v2 mount `secret/` exists; Kubernetes auth is enabled. (`platform/gitops/components/secrets/vault/config/scripts/configure.sh`)
- ESO `ClusterSecretStore/vault-core` is wired to Vault KV v2. (`platform/gitops/components/secrets/external-secrets/config/clustersecretstore.yaml`)
- Decision: tenant KV subtree is `tenants/<orgId>/...` with reserved `sys/*` subpaths. (`docs/design/multitenancy-secrets-and-vault.md`)
- Decision: default tenant personas are admin `rw`, developer `wo` (default), viewer `ro` (optional). (`docs/design/multitenancy-secrets-and-vault.md`)
- Decision: scoped ESO stores use a per-project `ClusterSecretStore` (`vault-tenant-<orgId>-project-<projectId>`). (`docs/design/multitenancy-secrets-and-vault.md`)
- Phase 1 guardrail: tenant namespaces are denied ESO CRDs (`ExternalSecret`, `SecretStore`, `PushSecret`) via Kyverno `ClusterPolicy/tenant-deny-external-secrets`.
- Keycloak tenant group scaffolding exists: groups `dk-tenant-*` are reconciled from `platform/gitops/apps/tenants/base/tenant-registry.yaml`.
- Vault human auth baseline exists: `auth/oidc` (JWT auth backend in OIDC mode) is configured against Keycloak with a `groups` claim and a default role.
- Vault tenant authZ scaffolding exists: tenant-scoped policies plus `dk-tenant-*` identity group alias mapping are reconciled from the tenant registry.
- Scoped ESO stores scaffolding exists: per-project Vault policies + K8s auth roles are reconciled, and the smoke fixture store (`vault-tenant-smoke-project-demo`) proves in-boundary reads.
