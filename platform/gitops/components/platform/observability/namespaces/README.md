# Observability Namespaces

Creates the `observability`, `loki`, `tempo`, `mimir`, and `grafana` namespaces with Istio sidecar injection enabled. NetworkPolicies are deny-by-default with explicit allow-lists:

- Intra-namespace ingress/egress for each backend (ring/gRPC/StatefulSet traffic).
- Cross-namespace traffic only via Loki/Mimir gateways and Tempo monolithic service.
- Grafana UI ingress only from the mesh ingress gateway.
- Alloy/tests egress only to required backends + DNS/Istio control plane.
