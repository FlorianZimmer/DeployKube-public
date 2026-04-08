# Keycloak Base

Wave **2** owns the runtime namespace plus the operator-managed workload objects.

## What ships here

- `Keycloak` CR – baseline **2 instances**, TLS via `keycloak/keycloak-tls`, XA disabled, and mesh integration. Hostnames are patched by `base/overlays/<deploymentId>/`.
- `HorizontalPodAutoscaler` – scales the Keycloak CR between **2–4 instances** based on average CPU usage (resource metrics via metrics-server).
- `Service` – mesh-visible Service (`networking.istio.io/exportTo: "*"`) for in-cluster OIDC consumers and Istio ingress routing.
- `NetworkPolicies` – default deny plus explicit ingress (Istio gateway + monitoring) and egress (CNPG + DNS) rules.
- `PodDisruptionBudget` – `maxUnavailable=1` so voluntary disruptions can proceed while keeping at least one Keycloak pod available.

See `docs/design/keycloak-gitops-design.md` for sizing rationale and `docs/component-issues/keycloak.md` for any follow-up hardening work (STRICT mTLS, Gateway filters, etc.).
