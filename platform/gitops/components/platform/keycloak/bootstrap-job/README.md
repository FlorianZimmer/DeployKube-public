# Keycloak Bootstrap Job (Wave 3 hook)

`platform-keycloak-bootstrap` is a PostSync Argo hook that finalises the Keycloak deployment once the operator, Postgres, realms, and ingress have converged.

## Responsibilities
1. **Readiness gates** – waits for the `Keycloak/keycloak` CR, the `HTTPRoute/keycloak`, and the `Certificate/keycloak-tls` copies (in both `istio-system` and `keycloak`) to report `Ready`.
2. **TLS mirroring** – copies/refreshes `istio-system/keycloak-tls` into `keycloak/keycloak-tls`, annotating the secret checksum so Argo notices future cert rotations.
3. **Realm enforcement** – mounts the placeholder ConfigMap templates (`/realm-templates/*.yaml`), renders them with secrets fetched via the variable map, and feeds the rendered YAML to `keycloak-config-cli`. Each rendered file’s checksum is recorded so future runs only re-import when Git or Vault inputs change.
4. **DeploymentConfig snapshot consumption** – reads `ConfigMap/keycloak/deploykube-deployment-config` and exports deployment hostnames (`argocd`, `forgejo`, `vault`, `grafana`, `kiali`, `hubble`) into env vars so realm templates stay overlay-free.
5. **Master admin sync** – reads the Vault-backed `keycloak-admin-credentials` secret (ESO) and ensures a matching user exists in the `master` realm with the desired password, plus assigns both the `realm-management/realm-admin` client role and the realm-level `admin` role so the account can load the admin console. The job also removes the operator’s temporary `temp-admin` account so humans always log in with the audited credential.
6. **IAM mode reconciliation** – reads `spec.iam` from DeploymentConfig and reconciles standalone/downstream/hybrid behavior (upstream IdP setup for OIDC/SAML, LDAP federation wiring, offline-credential required actions, and hybrid default local-visible posture for fail-open safety).
7. **Developer user sync** – reads `keycloak-dev-user` and forces the `deploykube-admin` / `deploykube-apps` realm account (currently `keycloak-dev-user`) to exist with the Vault-managed password so preserve bootstraps and clean bootstraps share credentials.
8. **OIDC propagation** – queries the live Keycloak client secrets (`argocd`, `forgejo`, `vault-cli`), writes them back to Vault (`secret/data/keycloak/*-client`), and patches the downstream Kubernetes Secrets so Argo CD + Forgejo reload immediately instead of waiting for ESO to refresh.
9. **Sentinel ConfigMap** – records deployment context, IAM mode, TLS serials, realm checksums, Vault versions, admin username, and timestamp metadata in `keycloak-bootstrap-status`.

## Notes
- The pod runs as `registry.example.internal/deploykube/bootstrap-tools:1.4`, which bundles OpenJDK 21 alongside `kubectl`, `curl`, `yq`, `keycloak-config-cli`, and the Keycloak Admin CLI. For kind/orbstack, Stage 0 builds and loads this image; for Proxmox/Talos ensure it’s published/pullable (see `shared/scripts/publish-bootstrap-tools-image.sh`).
- The script reads `keycloak-admin-credentials` via `kubectl` (instead of env `secretKeyRef`) and waits for it to appear. This avoids `CreateContainerConfigError` pods during clean bootstraps when ESO is still materialising the Secret.
- Templates mounted at `/realm-templates/*.yaml` keep the Kubernetes `KeycloakRealmImport` structure for readability; the script renders them, then writes only the `.spec.realm` document into `/rendered-realms/*.yaml` so `keycloak-config-cli` receives a valid `RealmImport` payload (no `apiVersion`/`metadata`).
- RBAC now spans four namespaces:
  - `keycloak` – manage configmaps/secrets and watch the `Keycloak` CR.
  - `istio-system` – read the Gateway-facing TLS secret/certificate.
  - `argocd` / `forgejo` – patch the OIDC client secrets immediately after Vault is updated.
- Vault authentication happens dynamically via the Kubernetes auth role `keycloak-bootstrap`; the pod reads its ServiceAccount JWT, exchanges it for a short-lived Vault token, and never relies on a long-lived credential stored in Git/SOPS.
- `spec.backoffLimit` is intentionally low (1). The script retries Keycloak admin login in-process to avoid churning multiple failed Pods while the API finishes warming up.
- `spec.ttlSecondsAfterFinished` is set so failed Jobs/Pods don’t linger forever if something truly goes wrong.

To rerun the workflow manually, delete the `keycloak-bootstrap-status` ConfigMap (or change a realm manifest), then re-sync the `platform-keycloak-bootstrap` Application in Argo.
