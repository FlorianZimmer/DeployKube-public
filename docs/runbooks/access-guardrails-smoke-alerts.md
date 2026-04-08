# Runbook: Access guardrails smoke alerts (RBAC GitOps-only enforcement)

These alerts exist to keep the **cluster access contract** safe:
- RBAC mutations are **GitOps-only**
- Admission guardrails are continuously proven by smoke CronJobs

Related:
- Design: `docs/design/cluster-access-contract.md`
- Component: `platform/gitops/components/shared/access-guardrails/README.md`
- OIDC runtime validation: `docs/toils/kubernetes-oidc-runtime-validation.md`

## Alerts

### `AccessGuardrailsSmokeJobFailed` (critical)

Meaning: a smoke Job created by one of these CronJobs failed:
- `rbac-system/access-guardrails-smoke-allow-rbac-mutations`
- `access-guardrails-system/access-guardrails-smoke-deny-rbac-mutations`

This is high-risk because it implies either:
- **deny path broke** (humans may be able to bypass “GitOps-only RBAC”)
- **allow path broke** (the RBAC automation identity can’t reconcile namespace RoleBindings)

### `AccessGuardrailsSmokeStale` (warning)

Meaning: the CronJob has not reported a successful run within the expected interval.

This typically indicates:
- CronJob is suspended, not scheduled, or blocked
- Jobs are created but never reach success (timeouts, API issues)

## Triage (kubectl-only)

## Verify alerting hooks (Mimir)

These alerts are evaluated by Mimir Ruler (tenant `platform`) and forwarded to Mimir Alertmanager.

```bash
# List loaded rule groups (evaluation API)
kubectl -n mimir port-forward svc/mimir-ruler 18080:8080
curl -sS -H 'X-Scope-OrgID: platform' http://127.0.0.1:18080/prometheus/api/v1/rules \
  | jq -r '.data.groups[].name' | rg -n '^access\\.guardrails\\.smoke$'

# Alertmanager reachable + current alerts (may be empty)
kubectl -n mimir port-forward svc/mimir-alertmanager 19093:8080
curl -sS -H 'X-Scope-OrgID: platform' http://127.0.0.1:19093/alertmanager/api/v2/status | jq.
curl -sS -H 'X-Scope-OrgID: platform' http://127.0.0.1:19093/alertmanager/api/v2/alerts | jq.
```

1) Inspect CronJobs:

```bash
kubectl -n rbac-system get cronjob access-guardrails-smoke-allow-rbac-mutations -o yaml | rg -n \"schedule:|suspend:|lastSuccessfulTime|lastScheduleTime\" || true
kubectl -n access-guardrails-system get cronjob access-guardrails-smoke-deny-rbac-mutations -o yaml | rg -n \"schedule:|suspend:|lastSuccessfulTime|lastScheduleTime\" || true
```

2) Inspect recent Jobs and logs:

```bash
kubectl -n rbac-system get job --sort-by=.metadata.creationTimestamp | tail -n 20
kubectl -n access-guardrails-system get job --sort-by=.metadata.creationTimestamp | tail -n 20

# Pick the most recent Job name for each, then:
kubectl -n rbac-system logs job/<job-name>
kubectl -n access-guardrails-system logs job/<job-name>
```

3) Confirm the admission objects exist (guardrails applied):

```bash
kubectl get validatingadmissionpolicy | rg -n \"access-guardrails|rbac\" || true
kubectl get validatingadmissionpolicybinding | rg -n \"access-guardrails|rbac\" || true
```

4) If Jobs fail due to denied admission unexpectedly:
- Treat as an access-plane regression.
- Fix via GitOps by adjusting allow-lists/guardrails logic.
- If GitOps itself cannot recover, use the environment's out-of-band emergency access path. The exact breakglass procedure is intentionally omitted from this public mirror.
