# Runbook: Mimir Ruler not evaluating (`MimirRulerNotEvaluating`)

Alert meaning: rule evaluations are not occurring; alerting may be degraded.

## Triage (kubectl-only)

```bash
kubectl -n mimir get pods -o wide
kubectl -n mimir logs -l app.kubernetes.io/component=ruler --tail=300 --all-containers || true
```

Also verify Alertmanager is reachable (Ruler → Alertmanager path):

```bash
kubectl -n mimir get svc | rg -n 'alertmanager' || true
```

## Remediation (preferred)

- Fix via GitOps under `platform/gitops/components/platform/observability/mimir/**`.
- If this is part of a wider observability smoke failure, consult:
  - `docs/runbooks/observability-smoke-alerts.md`

