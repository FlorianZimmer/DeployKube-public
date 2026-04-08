# Ingress Substrate Smoke Tests

Automated validation CronJobs for the ingress substrate:

- L4: An ingress `Service` (`public-gateway-istio`, fallback `istio-ingressgateway`) has a LoadBalancer IP and the VIP is reachable (`:443` accepts connections).
- L7: `HTTPRoute`s attached to `Gateway/public-gateway` are `Accepted=True` and `ResolvedRefs=True`.
- Minimal end-to-end request checks against the VIP using SNI/Host (TLS verification intentionally skipped here; cert correctness is covered by `certificates/smoke-tests`).

This component is intentionally **cross-cutting**: it validates “ingress works” across MetalLB + Istio + Gateway API.

For upstream ordering context, see master queue item **#6** in `docs/component-issues/master-delivery-queue.md`.

---

## Subfolders

| Path | Purpose |
|------|---------|
| `base/` | CronJob + RBAC |
| `overlays/dev/` | Faster schedule for dev |
| `overlays/prod/` | Prod schedule (base defaults) |

---

## Dependencies

- MetalLB must assign a VIP to one of:
  - `istio-system/Service/public-gateway-istio`
  - `istio-system/Service/istio-ingressgateway`
- Istio control-plane + gateway must be healthy:
  - `Gateway/public-gateway` exists in `istio-system`.
  - HTTPRoutes are applied by dependent components.
- DNS is not required for the VIP probes (uses `curl --resolve`), but is required for control-plane health in general.

---

## Operations

Create a one-off Job from the CronJob:

```bash
kubectl -n istio-system create job --from=cronjob/ingress-smoke-substrate test-ingress-smoke-$(date +%s)
kubectl -n istio-system logs -l job-name=test-ingress-smoke-* --tail=200
```

Note:
- This CronJob intentionally runs under PSA `baseline` (no `hostNetwork`). It may still emit warnings under PSA `restricted` depending on the cluster policy configuration.

---

## Smoke Jobs / Test Coverage

| CronJob | Purpose |
|---------|---------|
| `ingress-smoke-substrate` | VIP reachability + HTTPRoute acceptance + basic HTTPS request via VIP |

Schedule note:
- The base CronJob schedule is intentionally offset from `:00` to avoid top-of-hour kube-apiserver contention (dev overlays may run more frequently).
