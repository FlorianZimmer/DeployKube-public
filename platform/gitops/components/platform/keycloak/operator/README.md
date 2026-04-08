# Keycloak Operator (Wave 0.5)

This component now vendors the upstream **Keycloak Operator 26.4.4** manifests:

- `crds/` mirrors the official `keycloaks.k8s.keycloak.org` and `keycloakrealmimports.k8s.keycloak.org` CRDs from [keycloak/keycloak-k8s-resources@26.4.4](https://github.com/keycloak/keycloak-k8s-resources/tree/26.4.4/kubernetes).  
  Each CRD carries `argocd.argoproj.io/sync-options: Replace=true,ServerSideApply=true` plus `deploykube.gitops/apply-force: "true"` so Argo deterministically replaces them during upgrades.
- `operator-bundle.yaml` includes the ServiceAccount, RBAC, Service, and Deployment exactly as shipped upstream, with the subject namespaces rewritten to `keycloak-operator`. The Deployment pins `RELATED_IMAGE_KEYCLOAK=quay.io/keycloak/keycloak:26.4.4`.

### Refreshing the bundle
1. `rm -rf /tmp/keycloak-k8s-resources && git clone --depth 1 --branch <version> https://github.com/keycloak/keycloak-k8s-resources /tmp/keycloak-k8s-resources`
2. Replace the files under `crds/` and `operator-bundle.yaml` with the new release.
3. Re-run `scripts/fmt-yaml.sh` (if needed), update the README with the new version, and verify `kustomize build components/platform/keycloak/operator`.

Argo Application `platform-keycloak-operator` runs with `syncWave=0.5`, `CreateNamespace`, and `ApplyOutOfSyncOnly` so CRDs land before the rest of the Keycloak stack.
