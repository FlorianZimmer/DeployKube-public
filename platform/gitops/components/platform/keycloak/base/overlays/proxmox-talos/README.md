# Keycloak Base

Wave **2** owns the runtime namespace plus the operator-managed workload objects.

## What ships here

- `Namespace keycloak` – labeled for Istio injection + postgres access so shared policies can target it.
- `Keycloak` CR – 3 replicas pinned to `https://keycloak.prod.internal.example.com`, TLS via `keycloak/keycloak-tls`, XA disabled, and CPU/memory bumped per the design.
- `Service` + `ServiceMonitor` – mesh-visible Service (`networking.istio.io/exportTo: "*"`) and a Prometheus scrape definition for when the monitoring stack arrives.
- `NetworkPolicies` – default deny plus explicit ingress (Istio gateway + monitoring) and egress (CNPG + DNS) rules.
- `PodDisruptionBudget` – `minAvailable=2` to keep HA semantics during voluntary disruptions.

See `docs/design/keycloak-gitops-design.md` for sizing rationale and `docs/component-issues/keycloak.md` for any follow-up hardening work (STRICT mTLS, Gateway filters, etc.).
