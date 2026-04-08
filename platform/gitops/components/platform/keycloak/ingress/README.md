# Keycloak Ingress

Wave **3** exposes Keycloak through the public Istio gateway:

- `HTTPRoute keycloak` binds to the reserved `https-keycloak` section on `public-gateway`.
- `DestinationRule keycloak` enables ISTIO_MUTUAL traffic once workloads exist (STRICT policies will follow later).
- `Certificate keycloak/keycloak-tls` issues the namespace-local TLS secret consumed by the Keycloak CR. Separately, `istio-system/keycloak-tls` (from `components/certificates/ingress`) covers the Gateway listener.

Additional pieces (Gateway filters, STRICT `PeerAuthentication`, etc.) will be added once the workloads are online.

## DeploymentConfig (Phase 4)

Hostnames are driven by `platform/gitops/deployments/<deploymentId>/config.yaml` and reconciled by the tenant provisioner controller (no repo-side “render then commit” overlays).

```bash./tests/scripts/validate-ingress-adjacent-controller-cutover.sh
```
