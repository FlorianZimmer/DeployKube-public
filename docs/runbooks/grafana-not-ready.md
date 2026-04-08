# Runbook: Grafana not ready (`GrafanaNotReady`)

Alert meaning: Grafana pods are not `Ready` for an extended period.

## Triage (kubectl-only)

```bash
kubectl -n grafana get pods -o wide
kubectl -n grafana describe pod <pod>
kubectl -n grafana logs <pod> --tail=300
kubectl -n grafana get events --sort-by=.lastTimestamp | tail -n 50
```

Common causes:
- missing secrets/config (OIDC, admin credentials)
- ingress/network policy regressions (Grafana reachable but backend deps not)
- datasource provisioning errors

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/grafana/**`.
- Use the component overview: `platform/gitops/components/platform/observability/README.md`.

