# Keycloak Realm Templates

Wave **2.5** now stores placeholder-based templates for the `deploykube-admin` and `deploykube-apps` realms. At runtime the bootstrap job renders them with secrets fetched from ESO and imports the rendered JSON through `keycloak-config-cli`.

- `templates/*.yaml` capture the desired Keycloak export structure without embedding any plaintext secrets. Reference any sensitive/value that must be supplied at runtime via `${VAR}` placeholders and list the requirements in the file header.
- `variable-map.yaml` defines how placeholders map to Kubernetes Secrets or literals. Supported formats today:
  - `secret:<namespace>/<name>:<key>` – base64-decoded value from a Secret.
  - `literal:<value>` – static value that should survive across clusters.
  - `env:<NAME>` – value exported by the bootstrap job (for example from `DeploymentConfig` snapshot hostnames).
- Automation placeholders `KEYCLOAK_AUTOMATION_USERNAME` / `KEYCLOAK_AUTOMATION_PASSWORD` are sourced from the Vault-backed ExternalSecret `keycloak-automation-user`, keeping the Argo CD CLI bot fully declarative.
- The `configMapGenerator` emits deterministic ConfigMaps (`keycloak-realm-template-*`) so Argo can mount the templates into the bootstrap job Pods without manual decrypt steps.

To add a new realm:
1. Create `templates/<realm>.yaml` with placeholders for every sensitive field.
2. Extend `variable-map.yaml` (and, if necessary, the ESO component) so each placeholder can be resolved.
3. Append a `configMapGenerator` entry that exposes the template to the job.
4. Document the realm expectations in `docs/design/keycloak-gitops-design.md`.
