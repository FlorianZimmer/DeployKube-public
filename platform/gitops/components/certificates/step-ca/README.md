# Step CA (Certificates Stack)

GitOps definition for the Smallstep `step-certificates` deployment that currently provides the platform's internal/private issuer path.

Status note:
- This remains the current simpler issuer path for internal/private certificates.
- External client-facing certificates that require authoritative revocation, CRL, and OCSP are tracked separately on the Vault PKI path. Track: `docs/design/vault-pki-high-assurance-external-certificates.md`.

## Architecture

- **Helm release (`helm/values.yaml`)**: Installs `smallstep/step-certificates` chart `1.28.4`.
  - Runs as a single-pod StatefulSet (pending HA support from upstream).
  - Database persistence via `shared-rwo` storage class.
  - Gateway-neutral networking (ClusterIP only).
- **Vault-backed secrets (`secrets/externalsecrets.yaml`)**: ESO hydrates the entire CA configuration (`ca.json`, keys, certs, passwords) from Vault.
- **Bootstrapping**:
  - `seed/`: A Job decrypts DSB SOPS material and writes the CA config/certs/keys/passwords into Vault KV (intended for initial import and rotations; safe to rerun).
  - `bootstrap/`: A Job extracts the root key from secrets and writes `cert-manager/step-manager-root-ca` for the ClusterIssuer.

Step CA should therefore be read as:
- the current internal/private issuer implementation
- the simpler steady-state issuer path for certificates that do not require CRL/OCSP
- separate from the implemented Vault PKI path for external high-assurance certificates

## Subfolders

| Path | Purpose |
| ---- | ------- |
| `helm/` | Pinned Helm chart + values (storage class, DNS, pod settings). |
| `secrets/` | ExternalSecrets that hydrate the required Kubernetes Secrets out of Vault. |
| `seed/` | SOPS package + job that seeds Vault KV with the CA config/certs/keys/passwords. |
| `bootstrap/` | ServiceAccount/RBAC + `step-ca-root-secret-bootstrap` Job and helper script. |

## Container Images / Artefacts

- **Chart**: `smallstep/step-certificates:1.28.4` (app).
- **Bootstrap**: `registry.example.internal/deploykube/bootstrap-tools:1.4`.

## Dependencies

- **Data Service**: `vault` (must be unsealed and reachable).
- **Storage**: `shared-rwo` PVC provisioner.
- **Consumer**: `certificates/cert-manager` (which uses the output Secret).

## Communications With Other Services

### Kubernetes Service → Service calls
- **Internal**: `step-ca.step-system.svc.cluster.local:443` (GRPC/HTTPS).
- **Clients**: `cert-manager` connects here to sign certificates.

### External dependencies (Vault, Keycloak, PowerDNS)
- **Vault**: Source of truth for all keys and config.
- **Keycloak**: Uses the OIDC trust bundle synced from here.

### Mesh-level concerns (DestinationRules, mTLS exceptions)
- **Namespace posture**: `step-system` is explicitly `istio-injection=disabled` to keep PKI out of the mesh by default (avoids “DNS/TLS depends on mesh” failure chains).
- **Bootstrap job**: Explicitly disables injection (`sidecar.istio.io/inject: "false"`) to avoid sidecar exit issues.
- **Main Pod**: Not sidecar-injected under the namespace posture above. If this is changed in the future, document the required mesh policy and mTLS exceptions explicitly.

## Initialization / Hydration

1.  **Seed (optional / rotations)**: `certificates-step-ca-seed` runs to write Step CA material into Vault from the Deployment Secrets Bundle.
2.  **Hydrate**: ESO (`secrets/`) syncs Vault data to Kubernetes Secrets.
3.  **Preflight**: `PreSync Job/step-ca-preflight` (in the Helm app) validates the expected hydrated Secrets exist and contain required keys before the Step CA Helm release applies.
4.  **Install**: `certificates-step-ca` (Helm) starts the pod.
5.  **Bootstrap**: `step-ca-root-secret-bootstrap` extracts the root CA for cert-manager.

## Argo CD / Sync Order

- **Wave 1.25**: `certificates-step-ca-seed` (seed Vault from DSB).
- **Wave 3**: `certificates-step-ca-secrets` (ESO).
- **Wave 4**: `certificates-step-ca` (Helm, includes the PreSync preflight).
- **Wave 6**: `certificates-step-ca-bootstrap` (write root CA secret for cert-manager and publish OIDC trust bundle into Vault).
- **Order Enforcement**: Sync waves in `apps/base` ensure Secrets exist before the pod starts.

## Operations (Toils, Runbooks)

- **Initial CA Import**:
  - Populate `platform/gitops/deployments/<deploymentId>/secrets/step-ca-vault-seed.secret.sops.yaml` and sync.
  - The seed Job reads it from `argocd/deploykube-deployment-secrets` (Deployment Secrets Bundle).
- **Rotate CA Material**: Update SOPS, re-run the seed job, wait for ESO refresh, restart Step CA, rerun bootstrap job.
  - **Rerun Bootstrap**: re-sync `certificates-step-ca-bootstrap` (it is an Argo hook job).
  - **Pod Recovery**: StatefulSet usage implies manual delete to restart if stuck.
  - **Preflight failures**: Resync `certificates-step-ca` to rerun `PreSync Job/step-ca-preflight` and inspect the Job logs for which Secret/key is missing.

## Customisation Knobs

- **Helm Values**: `helm/values.yaml` for storage class, resources, DNS.
- **Vault Paths**: `secrets/externalsecrets.yaml` maps Vault KV to files.
- **Job Env**: `STEP_CA_NAMESPACE`, `STEP_CA_TLS_SECRET_NAME` etc. in bootstrap manifests.

## Oddities / Quirks

- **Single Replica**: No HA support upstream yet.
- **Race Conditions**: ESO must be healthy before Step CA syncs.
- **Argo drift guard**: The Step CA StatefulSet PVC template is sensitive to `volumeClaimTemplates` subfields; keep the PVC template fields aligned (see `helm/patch-retention.yaml`) to avoid persistent `OutOfSync` drift.
- **Bootstrap Image**: Uses a custom `bootstrap-tools` image to carry `step` CLI and scripts.

## TLS, Access & Credentials

- **HTTPS**: Served on port 443 with its own intermediate CA.
- **Trust**: `cert-manager/step-ca-root-ca` is the trust anchor for the cluster.
- **Workstation trust**: Operators should trust the public root certificate in `shared/certs/deploykube-root-ca.crt` when accessing platform HTTPS endpoints.
- **RBAC**: Bootstrap job has privileges to write Secrets to `cert-manager` namespace.

## Dev → Prod

- **Differentiation**:
  - Dev uses `shared-rwo` (OrbStack/NFS).
  - Prod uses `shared-rwo` (ZFS/Longhorn).
  - DNS names may differ if configured in values (currently `step-ca.local`).

## Smoke Jobs / Test Coverage

- **Automated:** No dedicated functional smoke job exists in GitOps yet (see `docs/component-issues/step-ca.md`).
- **Bootstrap Verification:** The `step-ca-root-secret-bootstrap` Job implicitly validates availability by connecting to Kubernetes to write the root CA secret, but it *fails* to test if Step CA itself is signing.

## HA Posture

- **Current State:** Single replica (`replicaCount: 1`), ClusterIP service, `shared-rwo` PVC.
- **Failover:**
  - Pod deletion = downtime (seconds to minutes for reschedule).
  - PVC availability is critical; if the node dies, the PVC must be mountable elsewhere (Longhorn/ZFS/NFS behavior).
- **Upstream:** Smallstep has experimental HA support (MySQL/Postgres backend) but it is not configured here.

## Security

- **Secrets:** All private key material is injected from Vault via ESO. No keys in Git.
- **Root Key:** The unencrypted root key exists in `secret/step-ca-root-ca` (Kubernetes secret) but only after bootstrap.
- **Privilege:** The pod runs non-root (check `runAsUser` in chart defaults).

DSB-specific notes:
- `step-ca-vault-seed.secret.sops.yaml` is stored in Git as ciphertext and shipped via a ConfigMap (`argocd/deploykube-deployment-secrets`).
- Placeholder guardrail: the seed job refuses to run if the decrypted file contains `darksite.cloud/placeholder=true`.

## Backup and Restore

- **Configuration:** Restorable from Git (`helm/`) + Vault (ESO source).
- **Identity/Keys:** *Must* be backed up in Vault (the `seed/` job does this initially).
- **State (Issued Certs):** Stored in the `shared-rwo` PVC (badgerdb).
  - **Loss Impact:** If DB is lost, revocation status of existing certs is lost.
  - **Recovery:** New PVC + Redeploy. Certs can be re-issued. Vault usage ensures the CA Identity (signing key) is preserved, so old certs remain valid until expiry.
