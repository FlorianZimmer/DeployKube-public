# Cilium / Hubble Component Issues

Design:
- `docs/design/multitenancy-networking.md`

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
- (none)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved
- **2026-01-07 – `hubble-ui` exposure posture:** switched Stage 0 Cilium defaults to `ClusterIP` and added a GitOps PostSync hook (`Job/hubble-ui-service-posture`) to enforce `kube-system/svc/hubble-ui` is `ClusterIP` (no NodePort).
- **2026-01-08 – Hubble UI authentication:** added a Keycloak OIDC auth proxy (oauth2-proxy) in front of Hubble UI and switched ingress routing to the proxy.
- **2026-01-28 – mac-orbstack Istio routing regression:** enabled Cilium `socketLB` in host namespace only (`socketLB.hostNamespaceOnly=true`) to avoid OrbStack/kind service routing failures with Istio L7 traffic.
