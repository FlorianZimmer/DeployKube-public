# Kiali

Installs the Kiali dashboard to visualise Istio traffic and configuration and exposes it through the shared public Gateway with a Step CA certificate.

## Contents
- `kustomization.yaml` – renders the Kiali Helm chart and the HTTPRoute.
- `values.yaml` – chart values tuned for the Proxmox+Talos cluster (OIDC auth, no built-in ingress).
- `httproute.yaml` – routes `kiali.prod.internal.example.com` to the Kiali service on port 20001 via the Istio public Gateway.
- `patch-login-token-signing-key-init.yaml` – stabilizes Kiali’s `login_token.signing_key` to stop Argo-driven rollout churn (see “Auth & Security”).

## Operations
- Sync with `argocd app sync networking-istio-kiali`.
- Verify pods and sidecars: `kubectl -n istio-system get pods -l app.kubernetes.io/name=kiali`.
- Check reachability: browse `https://kiali.prod.internal.example.com` (Step CA trust required on the client) or run `kubectl -n istio-system port-forward svc/kiali 20001:20001` if the Gateway is still converging.

## Auth & Security
- Auth strategy is Keycloak OIDC (`auth.strategy: openid`). The client secret is sourced from Vault (`secret/keycloak/kiali-client`) and projected into `Secret/istio-system/kiali` as `oidc-secret`.
- OIDC TLS verification is enforced (`auth.openid.insecure_skip_verify_tls: false`) using `ConfigMap/istio-system/kiali-cabundle` (`openid-server-ca.crt`) for issuer trust.
- Kiali’s Helm chart generates a random `login_token.signing_key` when left empty (render-time `randAlphaNum`), which makes Argo CD continuously “see” drift and roll the Deployment. The overlay pins a stable placeholder in `values.yaml` and replaces it at runtime (init container) using `Secret/istio-system/kiali:oidc-secret` as the signing key source.
  - The init container writes a rendered config into a writable `emptyDir` volume and mounts it at `/kiali-configuration` for the Kiali container. The Helm-rendered `ConfigMap/istio-system/kiali` stays mounted as the template at `/kiali-configuration-template`.
- Sidecar injection is forced via pod annotation so Kiali participates in mesh-wide STRICT mTLS.
- Certificate `kiali-tls` is issued by the shared `step-ca` ClusterIssuer and mounted on the ingress Gateway listener `https-kiali`.

## Dependencies
- Istio control plane + Gateway (`public-gateway` listener present).
- cert-manager/Step CA for the `kiali-tls` certificate.
- Prometheus endpoint at `http://prometheus.istio-system:9090` (not yet shipped here; Kiali will degrade gracefully until telemetry is available).

## HA Posture
- Kiali runs with 2 replicas and a PodDisruptionBudget (`minAvailable: 1`) to tolerate single-pod disruptions.

## Follow-ups
- Add a managed Prometheus deployment and point `external_services.prometheus.url` at it so graphs populate.
