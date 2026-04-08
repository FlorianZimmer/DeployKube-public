# Hubble UI Exposure

Routes Cilium Hubble UI through the shared Istio Gateway so the dashboard is reachable at `https://hubble.prod.internal.example.com` without port-forwards.

## Contents
- `kustomization.yaml` – applies the HTTPRoute into `kube-system`.
- `httproute.yaml` – binds the `https-hubble` listener on `public-gateway` to the `hubble-auth-proxy` Service (port 80).
- `oauth2-proxy-*.yaml` – deploys oauth2-proxy (Keycloak OIDC auth proxy) in front of `hubble-ui` with group-based allowlist (`dk-platform-admins`, `dk-platform-operators`, `dk-security-ops`).

## Operations
- Sync with `argocd app sync networking-hubble-ui`.
- Verify: `kubectl -n kube-system get deploy hubble-auth-proxy` and open the URL in a browser (Step CA trust required). Logs sit under `kube-system` Deployments `hubble-auth-proxy`, `hubble-ui`, and `hubble-relay`.

## Dependencies
- Cilium installed with Hubble UI/Relay enabled (Stage 0 values).
- Gateway + TLS certificate `hubble-tls` present in `istio-system`.
- Namespace `kube-system` is set to PERMISSIVE mTLS by `mesh-security` so the non-injected Hubble pods remain reachable.

## Follow-ups
- Consider adding a defense-in-depth NetworkPolicy for `hubble-ui` and `hubble-auth-proxy`.
