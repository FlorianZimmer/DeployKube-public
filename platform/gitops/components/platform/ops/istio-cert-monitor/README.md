# istio-cert-monitor

Proactively detects expiring Istio workload certificates (per-pod `istio-proxy` identity cert) and performs a controlled `rollout restart` of selected workloads before expiry. This prevents “surprise outages” when a pod’s cert expires and mTLS handshakes begin failing.

## How it works
- A CronJob runs `kubectl exec … -c istio-proxy -- pilot-agent request GET certs` against one running pod per configured workload.
- It extracts the earliest `notAfter` from the returned certificate chain(s).
- If the remaining lifetime is below `THRESHOLD_SECONDS`, it runs `kubectl rollout restart <kind>/<name>` and annotates the workload with the restart timestamp.
- A `COOLDOWN_SECONDS` guard prevents repeated restarts if something is persistently broken.

## Mesh note (why injection is disabled)
This CronJob needs reliable access to the Kubernetes API server and does not make service-to-service calls that benefit from mTLS policy. In this cluster, Istio-injected batch pods can remain Running (with only `istio-proxy` alive) after the main container exits, so the CronJob explicitly sets `sidecar.istio.io/inject: "false"` for predictable completion.

## Configuration
- `targets.json` in ConfigMap `istio-cert-monitor-config` controls what is checked/restarted.
- Environment variables on the CronJob:
  - `THRESHOLD_SECONDS` (default `7200`)
  - `COOLDOWN_SECONDS` (default `3600`)
  - `DRY_RUN` (`true` logs actions without restarting)

## RBAC
The ServiceAccount uses a ClusterRole that grants:
- read/list pods and create `pods/exec` requests (to query `pilot-agent`)
- patch deployments/statefulsets/daemonsets (to perform rollout restarts + annotations)

## Runbook / Smoke test
Run once on-demand (monitor):
```sh
kubectl -n platform-ops create job --from=cronjob/istio-cert-monitor istio-cert-monitor-manual
kubectl -n platform-ops logs -l job-name=istio-cert-monitor-manual --all-containers=true --tail=200
```

Run once on-demand (smoke; proves parsing + RBAC + target reachability, dry-run):

```sh
kubectl -n platform-ops create job --from=cronjob/istio-cert-monitor-smoke istio-cert-monitor-smoke-manual
kubectl -n platform-ops logs -l job-name=istio-cert-monitor-smoke-manual --all-containers=true --tail=200
```

Verify a controlled restart happened (when expected):
```sh
kubectl -n forgejo get deployment/forgejo -o jsonpath='{.metadata.annotations.deploykube\\.dev/istio-cert-monitor-last-restart}{"\n"}'
```

## Dev → Prod
- **Dev:** Use `DRY_RUN=true` first, validate parsing output, then enable restarts.
- **Prod:** Widen the target list (Argo/Forgejo/Keycloak/Vault), and consider alerting on “restart executed” events/annotations.
