# Certificate Stack Smoke Tests

Automated validation CronJobs for the complete certificate trust path: Step CA issuance → ingress Certificate readiness → Gateway TLS presentation.

The smoke jobs are mode-aware via `DeploymentConfig.spec.certificates`:
- `cert-smoke-step-ca-issuance` auto-skips when neither platform nor tenants use `subCa`.
- `cert-smoke-ingress-readiness` checks wildcard Secret presence when `platformIngress.mode=wildcard`.
- `cert-smoke-gateway-sni` always validates handshake + hostname and conditionally enforces chain verification depending on configured CA bundle.
  - `subCa` and `vault` use the shared cert-manager root CA bundle for strict verification of the full presented TLS chain.
  - `wildcard` and `acme` use an optional configured CA bundle override when present; otherwise they relax chain verification as documented.

## Architecture

Three CronJobs run in the `cert-manager` namespace to validate the cert stack:

| CronJob | Purpose |
|---------|---------|
| `cert-smoke-step-ca-issuance` | Creates ephemeral Certificate via `ClusterIssuer/step-ca`, waits for Ready, verifies chain against root CA |
| `cert-smoke-ingress-readiness` | Ensures all ingress Certificates (labeled `deploykube.certificates/purpose: ingress`) are Ready with valid Secrets |
| `cert-smoke-gateway-sni` | Performs TLS handshakes for each HTTPS hostname on `Gateway/public-gateway`, verifies hostname, and validates the full served chain when a CA bundle is configured |

## Subfolders

| Path | Purpose |
|------|---------|
| `base/` | CronJob definitions plus least-privilege RBAC (`ServiceAccount`, cluster-scoped read `ClusterRole`, namespace-scoped `Role`s with explicit namespaces because this component spans `cert-manager` and `istio-system`) |
| `overlays/mac-orbstack-single/` | Dev schedule (every 15 min) |
| `overlays/proxmox-talos/` | Prod schedule (hourly) |

## Container Images / Artefacts

- **Image:** `registry.example.internal/deploykube/validation-tools-core@sha256:babdd8ea44c3f169da4b55458061729329880fdf5c00194906d2dd6cdc655347` (contains `kubectl`, `bash`, `curl`, `jq`, `openssl`; version line remains `0.1.0`)
- **Rationale:** these jobs do not need the broader `bootstrap-tools` dependency set, so they stay on the narrower validation image to reduce cross-component vulnerability churn.
- **Verification control:** `./tests/scripts/validate-certificates-smoke-tests-contract.sh` enforces the canonical digest-pinned image ref plus the runtime hardening baseline.

## Dependencies

- **cert-manager:** Must be installed and healthy
- **DeploymentConfig singleton:** The jobs require exactly one cluster-scoped `DeploymentConfig`; they fail closed when zero or multiple objects exist so certificate mode selection never becomes ambiguous.
- **ClusterIssuer/step-ca:** Must exist and reference valid `step-ca-root-ca` Secret
- **Gateway/public-gateway:** Must exist in `istio-system` with HTTPS listeners
- **Ingress Certificates:** Must have `deploykube.certificates/purpose: ingress` label

## Communications With Other Services

### Kubernetes Service → Service calls
- Smoke tests connect to `public-gateway-istio.istio-system.svc.cluster.local:443` for TLS handshakes

### External dependencies
- None (all validation is cluster-internal)

### Mesh-level concerns
- Istio sidecar injection **disabled** (`sidecar.istio.io/inject: "false"`) because these jobs validate raw Kubernetes API / TLS consumer behavior, not mesh data-plane behavior.
- They still stay on a least-privilege posture: dedicated ServiceAccount, explicit namespace-scoped read Roles where possible, digest-pinned validation image, non-root runtime, bounded resources, and explicit egress allowlists.
- Egress is restricted to DNS, Kubernetes API, `istio-system` pods for `Gateway/public-gateway`, and `vault-system` pods for Vault CRL/OCSP validation.

## Initialization / Hydration

No initialization required. CronJobs are scheduled automatically after Argo sync.

## Argo CD / Sync Order

- **Sync Wave:** 15 (after all cert infrastructure is healthy)
- **Pre/PostSync hooks:** None
- **Sync dependencies:** Requires `certificates-cert-manager`, `certificates-cert-manager-issuers`, `certificates-platform-ingress`, `networking-istio-gateway` to be healthy

## Operations (Toils, Runbooks)

### Manual smoke test run

```bash
# Create one-off Jobs from CronJobs
kubectl -n cert-manager create job --from=cronjob/cert-smoke-step-ca-issuance test-step-ca-$(date +%s)
kubectl -n cert-manager create job --from=cronjob/cert-smoke-ingress-readiness test-ingress-$(date +%s)
kubectl -n cert-manager create job --from=cronjob/cert-smoke-gateway-sni test-gateway-$(date +%s)

# Watch for completion
kubectl -n cert-manager get jobs -l app.kubernetes.io/name=cert-smoke -w

# View logs
kubectl -n cert-manager logs job/test-step-ca-... -f
```

### Full mode-matrix smoke (live)

For end-to-end coverage across `subCa|acme|wildcard`, use:

```bash./tests/scripts/e2e-cert-modes-matrix.sh --modes subCa,acme,wildcard --ack-config-mutation yes
```

Runbook: `docs/toils/certificates-mode-matrix-e2e.md`

### Interpreting failures

- **Step CA issuance fails:** Check `ClusterIssuer/step-ca` status, verify `step-ca-root-ca` Secret exists
- **Ingress readiness fails:** Check specific Certificate status (`kubectl describe certificate -n istio-system <name>`)
- **Gateway SNI fails:** Verify Gateway listener configuration, check that Secrets are bound correctly
- **Alerting:** Mimir rules alert on missing `step-ca-root-ca` and stale/failed `cert-smoke-step-ca-issuance`; see `docs/runbooks/certificates-smoke-alerts.md`

## Customisation Knobs

- **Schedule:** Override in overlays (`/spec/schedule`). Base schedules are intentionally offset from `:00` to avoid top-of-hour kube-apiserver contention.
- **Timeouts:** `activeDeadlineSeconds` defaults to 900s; jobs wait for prerequisites (Step CA root/issuer, cert readiness) to avoid false negatives right after bootstrap.
- **Placement:** Default scheduler placement is intentional for these singleton periodic jobs; they should remain schedulable on single-node dev clusters rather than carrying HA-oriented affinity/spread rules.

## Oddities / Quirks

- Gateway SNI extracts only the leaf cert for hostname matching, then uses `openssl s_client -verify_return_error` against the configured CA bundle so the full presented chain is validated.
- This component intentionally avoids a kustomize-wide `namespace:` transformer because the smoke RBAC needs resources in both `cert-manager` and `istio-system`.
- Gateway SNI resolves the gateway service internally; DNS must work for the cluster service

## TLS, Access & Credentials

- **No credentials needed:** Uses ServiceAccount with minimal RBAC
- **RBAC scope:** cluster-scoped read for `DeploymentConfig` and `ClusterIssuer`, explicit namespace-scoped Roles in `cert-manager` and `istio-system`, plus create/delete for ephemeral test Certificates in `cert-manager`
- **Runtime hardening:** pod-level non-root security context, `RuntimeDefault` seccomp, dropped capabilities, read-only root filesystem with writable `/tmp`, and bounded CPU/memory requests/limits

## Dev → Prod

- **Promotion:** Base manifests are shared; only schedule differs between overlays
- **Verify:** `kustomize build overlays/{mac-orbstack-single,proxmox-talos}` should generate valid manifests

## Smoke Jobs / Test Coverage

This component **is** the smoke test infrastructure for the cert stack.

## HA Posture

N/A — these are periodic validation jobs, not HA workloads.

## Security

- Least-privilege RBAC
- Selector-scoped `NetworkPolicy` and `CiliumNetworkPolicy` constrain out-of-mesh smoke-job egress to the specific in-cluster dependencies they exercise
- No persistent data or credentials stored
- Ephemeral test Certificates are cleaned up on exit

## Backup and Restore

N/A — no persistent state.
