# Observability Ingress (Grafana)

Gateway API `HTTPRoute` + Istio `AuthorizationPolicy` for Grafana.

## TLS
- TLS terminates at `istio-system/public-gateway` (`listener: https-grafana`) using Secret `grafana-tls` created by `components/certificates/ingress`.

## Sync Order
1. `certificates-platform-ingress` (creates `grafana-tls` in `istio-system`).
2. `networking-istio-gateway` (adds the `https-grafana` listener).
3. `platform-observability-grafana` (creates `Service/grafana`).
4. This component (`platform-observability-ingress`).

## Runbook
- If Argo shows `Degraded`, inspect `HTTPRoute` status:
  - `kubectl -n grafana get httproute grafana -o yaml | rg -n "Accepted|ResolvedRefs|NoMatchingParent|BackendNotFound"`

## Dev → Prod
- Keep listener/Secret names consistent; hostnames are driven by DeploymentConfig and reconciled by the tenant provisioner controller (Phase 4).
- Note: avoid strategic-merge patches that touch `AuthorizationPolicy.spec.rules` (list replacement can clobber required allow rules, including the in-mesh smoke principal).

```bash./tests/scripts/validate-ingress-adjacent-controller-cutover.sh
```
