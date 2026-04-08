# Keycloak Realm Rendering via keycloak-config-cli

_Last updated: 2025-11-14_

## Tracking

- Canonical tracker: `docs/component-issues/keycloak.md`

## Summary

We replaced SOPS-encrypted `KeycloakRealmImport` manifests with placeholder-based realm templates (ConfigMaps) plus the declarative Jobs/Secrets required to render them. At runtime, a GitOps-managed bootstrap Job invokes [`keycloak-config-cli`](https://github.com/adorsys/keycloak-config-cli) to merge the template with secrets fetched through External Secrets Operator (ESO) and then imports the resulting realm through the Keycloak Admin API. This keeps sensitive values in Vault/ESO, preserves declarative Git workflows, and eliminates the manual “decrypt realm files” step.

## Background & Problem Statement

- The current design keeps full realm CRs (`KeycloakRealmImport`) encrypted in Git (SOPS). Humans must decrypt them locally and create ConfigMaps manually before Argo can sync, which violates the GitOps-only mandate and caused bootstrap failures when ConfigMaps weren’t updated.
- We want to reuse the existing Vault + ESO stack for all secret distribution, avoid enabling KSOPS on Argo CD, and still keep realms defined in Git.
- `KeycloakRealmImport` resources cannot reference Secrets; the operator imports exactly what is in the CR. Therefore, we need a preprocessing step that injects runtime secrets into the realm definition before import.

## Goals

1. Realm definitions stay in Git (templated, no plaintext secrets).
2. Sensitive data (client secrets, initial user passwords) continues to originate from Vault via ESO.
3. Argo CD remains stock—no KSOPS/Helm secrets plugins or extra repo-server permissions.
4. The bootstrap automation becomes deterministic: every Argo sync runs the same rendering/import logic, with drift detection recorded in `keycloak-bootstrap-status`.

## Non-goals

- Replacing the existing Keycloak bootstrap Job’s TLS/client reconciliation (it still handles TLS sync and Vault updates).
- Removing Vault/ESO; they remain the source of truth for secret material.
- Handling non-Keycloak workloads. This plan is scoped to the Keycloak realms.

## Proposed Architecture

### 1. Realm Templates in Git

- `platform/gitops/components/platform/keycloak/realms/templates/` stores YAML templates (ConfigMaps) containing `${VAR}` placeholders for every sensitive field.
- Templates document required variables in their headers (e.g., `requiredEnv: KEYCLOAK_ARGOCD_CLIENT_SECRET`).
- `variable-map.yaml` captures `PLACEHOLDER -> literal|secret|env` mappings so the bootstrap job knows how to resolve every placeholder.
- The component’s `configMapGenerator` emits deterministic ConfigMaps so Argo can detect drift and mount the templates into Jobs/Pods without manual steps.
- Templates remain shaped like `KeycloakRealmImport` resources (with `apiVersion/kind/metadata/spec`) for parity with existing manifests, but the bootstrap job now strips the Kubernetes wrapper by projecting `.spec.realm` before passing the rendered file to `keycloak-config-cli`.

### 2. Secret Seeding & Injection via ESO

- **Seeding pipeline:** `platform/gitops/components/secrets/vault/config/scripts/configure.sh` already seeds `secret/keycloak/{admin,dev-user,database,argocd-client,forgejo-client}` whenever those paths are empty, keeping the data declarative for new clusters.
- **ESO projections:** `components/secrets/external-secrets/keycloak/` now creates Secrets in the `keycloak` namespace (`keycloak-admin-credentials`, `keycloak-dev-user`, `keycloak-db`, `keycloak-argocd-client`, `keycloak-forgejo-client`) so the bootstrap job can read values locally, while the existing `argocd-secret` / `forgejo-oidc-client` resources continue to update the workloads in their own namespaces.
- **Variable map:** `keycloak-realm-variable-map` (same component) defines how each placeholder is resolved. Supported formats today:
  - `secret:<namespace>/<name>:<key>` – base64-decoded data from a Kubernetes Secret (namespace defaults to `keycloak` when omitted).
  - `literal:<value>` – static, non-secret values committed in Git.
  - `env:<VAR>` – passthrough from the Job’s environment.
- The bootstrap job reads this map, exports the variables, and never logs the resolved secrets.

### 3. Runtime Rendering with keycloak-config-cli

- `platform-keycloak-bootstrap` (PostSync hook) now runs on `deploykube/bootstrap-tools:1.4`, which bundles `keycloak-config-cli` alongside `kubectl`, `yq`, the Keycloak Admin CLI, and OpenJDK 21 so the CLI binary targeting class version 65 can execute inside the Job.
  - Flow:
    1. Load the variable map and fetch Kubernetes Secrets for each placeholder, exporting the resolved environment variables in-memory only.
    2. Run `envsubst` over `/realm-templates/*.yaml`, convert the rendered `KeycloakRealmImport` into pure realm JSON via `yq '.spec.realm'`, write the result to `/rendered-realms`, and track SHA256 hashes.
  3. Execute `keycloak-config-cli --import.files.locations=file:///rendered-realms/*.yaml --keycloak.url=http://keycloak.keycloak.svc.cluster.local:8080 --keycloak.user=$KEYCLOAK_ADMIN_USERNAME` so Keycloak reconciles the realms declaratively. Exit codes are captured in `keycloak-bootstrap-status`.
  4. Reuse the existing logic for readiness checks, TLS mirroring, admin synchronization, and Vault/Argo/Forgejo propagation.

### 4. GitOps Considerations

- Because the Job, ConfigMaps, and variable mappings live under `platform/gitops/components/...`, Argo remains the only actor applying them. The loop is now:
## Component Changes

| Component | Change |
| --- | --- |
| `components/platform/keycloak/realms` | Stores placeholder templates + `variable-map.yaml`; `configMapGenerator` exposes templates to the bootstrap job. |
| `components/platform/keycloak/bootstrap-job` | Renders templates, invokes `keycloak-config-cli`, records rendered hashes/exit codes, and preserves TLS/admin/Vault automation. |
| `components/secrets/external-secrets/keycloak` | Adds in-namespace ESO Secrets for the Keycloak ↔️ Argo/Forgejo OIDC clients plus the variable-map ConfigMap. |
| `components/secrets/vault/config` | Seeds the `secret/keycloak/*` paths deterministically so ESO always has data to project. |
| `deploykube/bootstrap-tools` image | Bundles `keycloak-config-cli` v6.4.0, OpenJDK 21, and supporting tooling; version bumped to `deploykube/bootstrap-tools:1.4`. |

## Risks & Mitigations

- **Template drift vs. live realm:** Mitigated by storing rendered checksum + config-cli reconciliation logs; bootstrap Job fails fast if substitution variables are missing.
- **Secrets exposure within Job logs:** Ensure scripts never echo substituted values; scrub debug output.
- **Image bloat:** Keep `keycloak-config-cli` in the bootstrap-tools image we already control; document version pinning.

Implementation status, open questions, and evidence live in `docs/component-issues/keycloak.md`.
