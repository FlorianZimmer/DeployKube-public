# Runbook: Mimir Alertmanager not ready (`MimirAlertmanagerNotReady`)

Alert meaning: Mimir Alertmanager pods are not ready; alert notifications may be delayed or dropped.

## Triage (kubectl-only)

```bash
kubectl -n mimir get pods -o wide
kubectl -n mimir describe pod <pod>
kubectl -n mimir logs <pod> --tail=300
```

If this is a notification delivery issue, also validate the projected notification config:

```bash
kubectl -n mimir get externalsecret mimir-alertmanager-notifications -o wide || true
kubectl -n mimir get secret mimir-alertmanager-notifications -o jsonpath='{.data}' | jq. || true
```

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/mimir/**`.

