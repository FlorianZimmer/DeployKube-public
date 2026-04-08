# Keycloak GitOps Design (Mac + OrbStack)

_Last updated: 2026-01-19_

## Tracking

- Canonical tracker: `docs/component-issues/keycloak.md`
- IAM mode contract + hybrid runbook: `docs/design/keycloak-iam-modes.md`

## Goals & Scope
- Rehome Keycloak from the legacy bootstrap script into GitOps-managed components without losing HA, TLS, or SSO integrations.
- Pin the deployment to Keycloak Operator **26.4.4** and Keycloak runtime 26.4.4, inheriting upstream security fixes while preserving today’s realms, groups, and the placeholder `keycloak-dev-user` user.
- Replace imperative steps (CNPG provisioning, TLS mirroring, realm imports, client-secret propagation) with declarative manifests plus a single GitOps bootstrap Job.
- Guarantee a production-ready posture (baseline 2 replicas with CPU-based HPA scale-up, Postgres on `shared-rwo`, TLS everywhere, secrets from Vault/ESO) and call out any missing prerequisites.

## Assumptions & Prerequisites
| Area | Requirement | Status |
| --- | --- | --- |
| Vault / ESO | `ClusterSecretStore vault-core` healthy; Vault contains `secret/keycloak/{admin,dev-user,database,argocd-client,forgejo-client}`. A new Vault policy/role `keycloak-bootstrap` will allow the GitOps Job to write back updated OIDC client secrets. | **Update (Nov 14, 2025):** `secrets-vault-config` still seeds those paths on first run, the policy + role are created by the same job, and the bootstrap Job now authenticates via the Kubernetes auth role (`keycloak-bootstrap`) instead of relying on a long-lived SOPS-managed token. |
| Certificates | Step CA + cert-manager already installed via existing GitOps apps. Need an additional `Certificate` in `keycloak` namespace (operator TLS secret) alongside the existing `istio-system/keycloak-tls` used by the Gateway. | **Done (Nov 12, 2025):** `components/platform/keycloak/ingress/certificate.yaml` now issues `keycloak/keycloak-tls` from the shared `step-ca` ClusterIssuer. |
| Networking | Gateway API + Istio control plane from `platform/gitops/components/networking/istio`. HTTPRoute section `https-keycloak` already reserved. | Ready. |
| Storage | `shared-rwo` StorageClass (from Stage 0) and CNPG operator (from `data-postgres-operator`) ready. | Ready. |
| Tooling | `deploykube/bootstrap-tools:1.4` image exists. We will extend it with Keycloak CLI (`kcadm.sh`) to power the bootstrap Job. | **Update (Nov 14, 2025):** image now bundles OpenJDK 21 + `kcadm.sh`/`keycloak-config-cli` so the PostSync Job satisfies the new class version requirements; rerun Stage 0 to rebuild/load the refreshed image on bootstrap nodes. |
| CRDs | `monitoring.coreos.com/ServiceMonitor` stub stays vendored so the operator’s RBAC remains valid. | Existing stub under legacy tree; will be copied into GitOps component. |

_No additional global prerequisites are required beyond the new Vault policy and bootstrap-tools image update noted above._

## Component Layout (platform/gitops)
The Keycloak design introduces five Argo Applications, each mapped to a Kustomize component so sync order and ownership stay clear.

1. **`platform-keycloak-operator` (wave 0.5)**
   - Namespace `keycloak-operator` + ServiceAccount, RBAC.
   - Vendor the upstream 26.4.4 manifests (Deployment, CRDs `Keycloak`, `KeycloakRealmImport`), pinning `RELATED_IMAGE_KEYCLOAK=quay.io/keycloak/keycloak:26.4.4`.
   - CRDs live under `components/platform/keycloak/operator/crds/` with `argocd.argoproj.io/sync-options: Replace=true,ServerSideApply=true` plus an explicit `deploykube.gitops/apply-force: "true"` annotation so Argo force-replaces them during upgrades.

2. **`data-postgres-keycloak` (wave 1)**
   - Overlay under `components/data/postgres/keycloak` that imports the shared CNPG base, patches name/storage, and references ESO secret `keycloak-db` for bootstrap + managed roles.
  - Resources: `Cluster` (default 3 instances; dev lowmem overlays may reduce instances), nightly database-only `pg_dump` backup CronJob writing to the `postgres-backup-v2` PVC (default StorageClass: `shared-rwo`), and an `ExternalName` service `keycloak-postgres` pointing to `*-rw`.
   - Pod annotations ensure Istio sidecars stay disabled for the database namespace; `keycloak-postgres-superuser` is now sourced via ESO to keep CNPG happy.

3. **`secrets-keycloak` (wave 0.8)**
   - Lives under `components/secrets/external-secrets/keycloak/`; creates the namespace `keycloak`, ESO `ExternalSecret` objects for admin credentials, developer user, database, and both OIDC client secrets.
  - Mirrors the Step CA root (`secret/data/step-ca/certs`) into the workloads that depend on Keycloak by emitting `argocd-oidc-ca` and `forgejo-oidc-ca`, so Argo CD and Forgejo trust the issuer without bespoke bootstrap steps. Stage 1 also pre-seeds `forgejo-oidc-ca` from `shared/certs/deploykube-root-ca.crt` so the Helm release can consume it before Argo syncs the ExternalSecret.
   - Also creates `Secret` projections consumed by Keycloak CR: `keycloak-db`, `keycloak-admin-credentials`.

4. **`platform-keycloak-base` (wave 2)**
   - Namespace labels (`istio-injection=enabled` + `darksite.cloud/postgres-client=true`), NetworkPolicy (default deny + allow Gateway/monitoring ingress and CNPG/DNS egress), PodDisruptionBudget, ServiceMonitor, `Keycloak` CR.
   - CR specifics:
     - `spec.instances=2` baseline, CPU-based HPA scales to `maxReplicas=4`, `spec.transaction.xaEnabled=false`, `resources` set to `cpu=250m, memory=1Gi` requests with `memory=2Gi` limit.
     - `spec.hostname.*` set to `https://keycloak.dev.internal.example.com`, `strictBackchannel=true`.
     - `spec.http.tlsSecret=keycloak-tls` (secret placed in `keycloak` namespace via Certificate component below).
     - `spec.monitoring.prometheus.reconcileService=true` so the operator emits the Service for scraping once we attach Prometheus later.
   - `Service` annotations (`networking.istio.io/exportTo: "*"`) expose the workload to the mesh and feed both the HTTPRoute and ServiceMonitor.
   - Argo CD ignores `Keycloak/keycloak` `/spec/instances` drift so it does not fight HPA scaling.

5. **`platform-keycloak-realms` (wave 2.5)**
   - Stores plaintext realm templates (`KeycloakRealmImport` shape) for `deploykube-admin` and `deploykube-apps` under `realms/templates/`, each using `${VAR}` placeholders for anything secret or environment-specific.
   - `variable-map.yaml` defines how each placeholder is resolved (`secret:<ns>/<name>:<key>`, `literal:<value>`, or `env:<VAR>`). Secrets originate from ESO-managed resources in the `keycloak` namespace.
   - `configMapGenerator` emits deterministic ConfigMaps (`keycloak-realm-template-*`) that the bootstrap job mounts beneath `/realm-templates`; rendered YAML lives only in the job Pod and its SHA256 hash is recorded in `keycloak-bootstrap-status`.
   - CI enforcement (future) should keep verifying that the templates declare the `keycloak-dev-user` placeholder user and the OIDC clients for Argo CD & Forgejo.

6. **`platform-keycloak-ingress` (wave 3)**
   - Moves the HTTPRoute from legacy manifests into `components/platform/keycloak/ingress`, identical to Argo’s pattern: `HTTPRoute`, `DestinationRule`, and the Certificates:
     - `istio-system/keycloak-tls` (already exists) for the Gateway listener.
     - `keycloak/keycloak-tls` (new) for the operator’s `tlsSecret`, issued by the shared `step-ca` ClusterIssuer so the bootstrap job no longer has to copy secrets.
   - Additional Gateway filters/DestinationRule STRICT mode will follow once workloads are healthy.

7. **`platform-keycloak-bootstrap` (wave 3 PostSync hook)**
   - One-shot Job (detailed below) that replaces the last remaining imperative behavior. The hook now runs on every Argo sync, but exits early once the sentinel ConfigMap confirms TLS/realm/Vault checksums match.

All Applications will be registered under `platform/gitops/apps/base/` with explicit `syncWave` annotations to keep ordering deterministic (operator → data → secrets → workloads → ingress → job).

## GitOps Bootstrap Job
`components/platform/keycloak/bootstrap-job` defines a ServiceAccount, Role, RoleBinding, ConfigMap, and Job. The Job image is `deploykube/bootstrap-tools:1.4` **with** the Keycloak CLI added. Hook annotations: `argocd.argoproj.io/hook: PostSync`, `...hook-delete-policy: HookSucceeded`, `...hook-weight: 10` (runs after ingress). Retry behaviour: we keep `spec.backoffLimit: 1`, so Kubernetes may spawn a second Pod when the CLI exits non-zero (the first Pod stays in `Error`). This looks like “two jobs” in the logs but represents the single Job retrying once.
To prevent noisy `CreateContainerConfigError` churn during clean bootstraps, the Job does **not** depend on ESO Secrets via env `secretKeyRef` at Pod creation time; the script waits for `keycloak-admin-credentials` and reads it via `kubectl` instead. A `ttlSecondsAfterFinished` is also set so failed hook Jobs/Pods don’t linger indefinitely.

Responsibilities:
1. **Readiness gates**
   - Wait for `Keycloak/keycloak` status Ready == True.
   - Wait for `HTTPRoute/keycloak` Accepted == True.
   - Fetch `Certificate/keycloak-tls` in both namespaces and ensure the Secret exists. If `keycloak/keycloak-tls` is missing, the Job copies data from `istio-system` → `keycloak` and annotates the Secret with a checksum so Argo can detect drift.
2. **Realm reconciliation**
   - Render the mounted templates with `envsubst` (variables provided by the ConfigMap-driven resolver) and run `keycloak-config-cli` against the resulting files. On success, persist rendered SHA256 hashes plus the CLI exit code in `keycloak-bootstrap-status`. Fail fast if required placeholders are missing or the CLI import errors.
3. **Master admin reconciliation**
   - Read `keycloak-admin-credentials` (ESO backed by `secret/keycloak/admin`) and ensure a matching master realm user exists with that username/password. The job removes the temporary `temp-admin` account after the first successful run so humans always authenticate with the Vault secret.
4. **Developer user synchronization**
- Pull `keycloak-dev-user` from ESO and ensure the shared developer account (currently `keycloak-dev-user`) exists in both `deploykube-admin` and `deploykube-apps` realms with the Vault-managed password so clean/preserve bootstraps behave identically.
5. **OIDC client secret sync**
   - Query the Keycloak Admin REST API for the `Forgejo` and `Argo CD` client secrets.
  - Compare with the Vault values stored at `secret/data/keycloak/argocd-client` and `secret/data/keycloak/forgejo-client` using the Job’s short-lived Kubernetes-auth token. If they differ, update Vault and patch the downstream Kubernetes Secrets (`argocd/argocd-secret`, `forgejo/forgejo-oidc-client`) to trigger pods to reload env vars.
6. **Sentinel**
   - Create ConfigMap `keycloak-bootstrap-status` recording:
     - Checksums of realm manifests.
     - TLS certificate serials.
     - Timestamp of last Vault sync.
    - The Job exits early (idempotently) when the ConfigMap checksum matches, letting Argo report Synced without rerunning expensive steps.

The script now lives at `components/platform/keycloak/bootstrap-job/scripts/bootstrap.sh` and runs with elevated RBAC in `keycloak`, `istio-system`, `argocd`, and `forgejo`. Sentinel keys follow the pattern `realm.<name>.sha256`, `tls.(gateway|keycloak).checksum`, `admin.username`, `vault.<client>.version`, `secret.<client>.lastPatched`, and a `job.lastRun` timestamp to make future debugging straightforward.

## Sync Waves & Ordering
| Wave | Component | Notes |
| --- | --- | --- |
| -2 | Gateway API, Istio control plane, Step CA, cert-manager | Already in place. |
| 0.5 | `platform-keycloak-operator` | CRDs before anything else. |
| 1 | `data-postgres-keycloak` | Database before ESO/CR. |
| 0.8 | `secrets-keycloak` | Must sync before CNPG bootstrap Secrets are consumed. |
| 2 | `platform-keycloak-base` | Keycloak CR + namespace scaffolding. |
| 2.5 | `platform-keycloak-realms` | Realm imports depend on CR readiness. |
| 3 | `platform-keycloak-ingress` | HTTPRoute + Certificates + DestinationRule. |
| 3 (hook) | `platform-keycloak-bootstrap` Job | Ensures TLS copy + secret sync. |
| 4 | Mesh security hardening (global component) | Once bootstrap sentinel exists, we can enforce STRICT PeerAuthentication. |

## Security, HA, and Ops Notes
- **HA posture**: baseline 2 Keycloak pods with CPU-based HPA scale-up, `topology.kubernetes.io/zone` anti-affinity, PDB (`maxUnavailable=1`), readiness gating on Infinispan.
- **NetworkPolicies**: Deny-all + allow from Istio ingress gateway namespace, Prometheus (future), and CNPG service. Job uses same namespace so automatically permitted.
- **Secrets**: All user/client/database passwords originate in Vault; no plaintext secrets live in Git. Realm templates stay plaintext with `${VAR}` placeholders, and the bootstrap Job resolves each placeholder from ESO-managed Secrets at runtime. Vault policy `keycloak-bootstrap` scopes writes strictly to `secret/data/keycloak/*`, and the Job logs in through Kubernetes auth every run so no long-lived Vault token sits in Git.
- **Realm templates**: The templates remain shaped like `KeycloakRealmImport` resources so we can reuse familiar Kubernetes manifests, but the bootstrap Job now strips `apiVersion/kind/metadata/spec.keycloakCRName` by projecting `.spec.realm` before calling `keycloak-config-cli`. This keeps Git diffs readable while guaranteeing the CLI only receives valid `RealmImport` documents.
- **TLS**: Dual Certificates prevent hand-copied secrets. Operator references local secret; Gateway references `istio-system` secret. Bootstrap Job merely validates parity.
- **Ingress hardening**: DestinationRule currently uses `ISTIO_MUTUAL` with baseline settings; the Gateway filters/mTLS enforcement still need to be tightened (tracked in `docs/component-issues/keycloak.md`).
- **Observability**: Enable operator-managed ServiceMonitor; actual Prometheus scrape config will reuse the shared monitoring stack once available.
- **Image provenance**: Document digest pins for operator/controller and Step CA certificate fingerprint in the component README.

## Migration Plan
1. Land this design note and update `docs/component-issues/keycloak.md` with the new tracking checklist.
2. Create the GitOps components + Argo Applications described above.
3. Extend `deploykube/bootstrap-tools` image with Keycloak CLI utilities; rerun Stage 0 to load it into the cluster registry. **Update (Nov 14, 2025):** image v1.2 now bundles `keycloak-config-cli` plus OpenJDK 21 so the PostSync Job can execute CLIs compiled for class version 65.
4. Introduce Vault policy `keycloak-bootstrap` and issue a SOPS-encrypted Kubernetes Secret so the Job can authenticate. **Done (Nov 11, 2025).**
5. Stage a dry run:
   - Disable legacy Keycloak section in the bootstrap script.
   - Run Stage 1 to install Forgejo/Argo (HTTP mode) + GitOps root.
   - Allow Argo to sync Keycloak components; observe the bootstrap Job logs and confirm secrets/TLS/realm checks succeed.
6. Legacy `envs/mac-orbstack/platform/keycloak/` overlays have been removed; bootstrap now relies solely on GitOps components.

## Follow-ups
1. Add automated tests (e.g., `just verify-keycloak`) that port-forward through the Gateway, run an OIDC login, and confirm TLS chain uses Step CA.
2. Evaluate replacing `KeycloakRealmImport` with dedicated CRDs (`KeycloakRealm`) once the operator GA’s them; current plan sticks to imports for parity.
3. When the central monitoring stack lands, enable the ServiceMonitor and wire Grafana dashboards plus alerts (admin login spikes, failed auth).
4. Long-term: externalize user management (SCIM) and rotate the placeholder `keycloak-dev-user` account once real IdM is in place.
