# cert-manager (Certificates Stack)

GitOps-managed deployment of cert-manager plus the ClusterIssuers wiring it to the Step CA root.

Status note:
- Step CA is the current internal/private issuer path for the platform.
- Vault PKI is the implemented issuer path for external client-facing platform ingress certificates that require CRL/OCSP-backed revocation. Track: `docs/design/vault-pki-high-assurance-external-certificates.md`.

## Architecture

- **Committed chart render (`helm/rendered-chart.yaml` + `helm/values.yaml`)**:
  - Installs chart `jetstack/cert-manager` `v1.19.4` from a committed render generated from the vendored chart.
  - Configures two replicas for controller/webhook/cainjector for HA.
  - **Startup API Check** is enabled (`startupapicheck.enabled: true`) to ensure the webhook is serving before consumers start.
  - Namespace creation/ownership is left to Argo via `CreateNamespace=true`.
  - Argo no longer executes Helm templating at reconcile time for this component.
- **Issuers bundle (`issuers/`)**:
  - Applied via the `certificates-cert-manager-issuers` Application **after** the controllers report Ready (enforced by sync waves).
  - Ships:
    - `selfsigned-bootstrap`: Breakglass/smoke-only issuer (not used for platform ingress; keep available so we can validate cert-manager even if Step CA is down).
    - `step-ca`: Pointing at the TLS secret created by the `step-ca-root-secret-bootstrap` Job.
    - `vault-external`: Vault-backed issuer for high-assurance external platform ingress certificates.

## Subfolders

| Path | Purpose |
| ---- | ------- |
| `helm/` | Vendored chart, committed rendered manifest, values, and post-render patches. |
| `issuers/` | Kustomize bundle with ClusterIssuers (can grow with DNS01/HTTP01 issuers later). |

## Container Images / Artefacts

- **Chart:** `jetstack/cert-manager` version `v1.19.4`, vendored at `platform/gitops/components/certificates/cert-manager/helm/charts/cert-manager` (upstream source: `https://charts.jetstack.io`; verification metadata: `platform/gitops/components/certificates/cert-manager/helm/upstream-chart-metadata.yaml`).
- **Images** (digest-pinned in `helm/values.yaml`):
  - `quay.io/jetstack/cert-manager-controller@sha256:9cad8065bbf57815cbcfa813b903dd8822bcd0271f7443192082b54e96a55585`
  - `quay.io/jetstack/cert-manager-webhook@sha256:f41b4ac798c8ff200c29756cf86e70a00e73fe489fb6ab80d9210d1b5f476852`
  - `quay.io/jetstack/cert-manager-cainjector@sha256:5d810724b177746a8aeafd5db111b55b72389861bcec03a6d50f9c6d56ec37c0`
  - `quay.io/jetstack/cert-manager-startupapicheck@sha256:8e897895b9e9749447ccb84842176212195f4687e0a3c4ca892d9d410e0fd43e`
  - `quay.io/jetstack/cert-manager-acmesolver@sha256:7688c3e2d7e5338deb630da911fff3752c72a7bf70f94608c223f96af40c8399`
- **Smoke Job:** `registry.example.internal/deploykube/bootstrap-tools@sha256:e7be47a69e3a11bc58c857f2d690a71246ada91ac3a60bdfb0a547f091f6485a`

## Dependencies

- **Namespace:** `cert-manager`.
- **Secrets:** `cert-manager/step-ca-root-ca` (must exist for the `step-ca` ClusterIssuer to be valid).
  - Source of truth: this is a derived Secret created by `Application/certificates-step-ca-bootstrap` from Step CA source Secrets in `step-system` that are hydrated from Vault/ESO.
- **CRDs:** `certificates.cert-manager.io` (installed by the Helm chart).

## Communications With Other Services

### Kubernetes Service → Service calls
- **Webhook:** The API Server calls `cert-manager-webhook` for admission validation/mutation.
- **Controller:** Watches Certificate resources and seeds Secrets; communicates with the Step CA provider (via the ClusterIssuer).

### External dependencies (Vault, Keycloak, PowerDNS)
- **Step CA:** The `step-ca` ClusterIssuer relies on the root CA material.

### Mesh-level concerns (DestinationRules, mTLS exceptions)
- **Startup Check:** The `startupapicheck` Job has Istio injection disabled (`sidecar.istio.io/inject: "false"`) to avoid race conditions when polling the webhook Service during bootstrap.

## Initialization / Hydration

1.  **Committed render:** Applies the pre-rendered cert-manager chart manifests; waits for `Available` status.
2.  **Startup Check:** `startupapicheck` pod runs to confirm webhook availability.
3.  **Issuers:** Once the controller stack is healthy, the `issuers/` bundle is applied (Sync Wave 7).

## Argo CD / Sync Order

- **Sync Wave 5:** `certificates-cert-manager` (committed chart render).
- **Sync Wave 6:** `step-ca-root-secret-bootstrap` Job (external dependency, but logically ordered between Helm and Issuers).
- **Sync Wave 7:** `certificates-cert-manager-issuers`.
- **Pre/PostSync hooks:** None defined in this component, but relies on the `startupapicheck` logic inside the Helm chart.

## Operations (Toils, Runbooks)

See `docs/guides/` for general cert-manager debugging.

- **Install/Upgrade:** Sync `certificates-cert-manager` first. Argo waits for health. Then sync `certificates-cert-manager-issuers`.
- **Verify CRDs:** `kubectl get crd certificates.cert-manager.io` must succeed before applying issuers.
- **Trust Step CA:** Ensure `kubectl -n cert-manager get secret step-ca-root-ca` exists. If missing, rerun the bootstrap job.
- **Alerting / runbook:** Mimir rules watch for missing `cert-manager/step-ca-root-ca` and stale/failed `cert-smoke-step-ca-issuance`; see `docs/runbooks/certificates-smoke-alerts.md`.
- **Recovery drill:** Use `./scripts/ops/cert-manager-restore-drill.sh` for a repeatable regeneration drill; the recommended routine path is `--mode scratch`, with `--mode live` reserved for explicit maintenance windows. Detailed flow: `docs/toils/cert-manager-restore-drill.md`.

### Upgrade / Rollback

For chart bumps or values changes:

1. Update `platform/gitops/components/certificates/cert-manager/helm/values.yaml` and, when chart content changes, refresh the vendored chart plus `platform/gitops/components/certificates/cert-manager/helm/rendered-chart.yaml`.
2. Regenerate the committed render before merge:
   `PATH="$(pwd)/tmp/tools:$PATH" HELM_NO_PLUGINS=1 helm template cert-manager platform/gitops/components/certificates/cert-manager/helm/charts/cert-manager --namespace cert-manager --include-crds -f platform/gitops/components/certificates/cert-manager/helm/values.yaml > platform/gitops/components/certificates/cert-manager/helm/rendered-chart.yaml`
3. Validate the committed manifest output:
   `PATH="$(pwd)/tmp/tools:$PATH" kustomize build platform/gitops/components/certificates/cert-manager/helm`
4. Validate the supply-chain contract before merge:
   `./tests/scripts/validate-cert-manager-supply-chain-contract.sh`
5. Verify the vendored chart against the upstream signed release before any chart bump:
   `./tests/scripts/verify-cert-manager-chart-vendor.sh`
6. Run the image scan review step for the pinned cert-manager images and smoke image:
   `./tests/scripts/scan-cert-manager-images.sh`
   If the canonical smoke image registry is not resolvable from the workstation, pass a reachable mirror/tag via `SMOKE_IMAGE_OVERRIDE=...` for the scan step only.
7. Sync `certificates-cert-manager` and wait for the controller, webhook, and cainjector Deployments to report `Available=True`.
8. Sync `certificates-cert-manager-issuers` after the controller app is healthy.
9. Run the functional smoke validation:
   `kubectl apply -k platform/gitops/components/certificates/cert-manager/tests`
   `kubectl -n cert-manager wait --for=condition=complete job/cert-manager-certificate-smoke --timeout=10m`
   `kubectl -n cert-manager logs job/cert-manager-certificate-smoke`
10. Record the chart verification, committed-render refresh, scan output, and smoke path/outcome in the evidence note for the change.
11. If `Application/certificates-cert-manager` wedges during prune with a message like `waiting for deletion of rbac.authorization.k8s.io/Role/cert-manager-startupapicheck:create-cert and 1 more hooks`, inspect the namespace-scoped `Role` and `RoleBinding` named `cert-manager-startupapicheck:create-cert`. On Proxmox we observed stale `foregroundDeletion` finalizers during both rollback and forward upgrade rehearsals; the breakglass recovery was:
   `kubectl -n cert-manager patch role cert-manager-startupapicheck:create-cert --type=merge -p '{"metadata":{"finalizers":[]}}'`
   `kubectl -n cert-manager patch rolebinding cert-manager-startupapicheck:create-cert --type=merge -p '{"metadata":{"finalizers":[]}}'`
   Then force a fresh app reconcile and continue the smoke path. Record the breakglass in evidence when used.

Rollback path:

1. Revert the Git commit that changed the chart version or values.
2. Re-sync `certificates-cert-manager`, then `certificates-cert-manager-issuers`.
3. Re-run `Job/cert-manager-certificate-smoke` and confirm it still creates a self-signed test certificate and cleanup succeeds.

CRD note:

- The chart runs with `installCRDs: true`, so treat version downgrades conservatively. If the target rollback would remove or change CRD schema that live resources already depend on, prefer rolling forward with a compatible fix instead of forcing an incompatible downgrade.

## Customisation Knobs

- **Replica Counts:** Edit `helm/values.yaml` (default: 2 for HA).
- **Feature Flags:** `startupapicheck.enabled`, `prometheus.enabled` (currently false).
- **New Issuers:** Add manifests to `issuers/` (e.g., Let's Encrypt, DNS01).

## Oddities / Quirks

- **Startup API Check:** We explicitly enable this to avoid the "webhook not ready" race that historically plagued bootstrap scripts. It introduces a small delay during upgrades.
- **Argo prune quirk:** During the 2026-03-14 Proxmox upgrade/rollback rehearsal, Argo twice wedged waiting for deletion of `cert-manager-startupapicheck:create-cert` RBAC objects with stale `foregroundDeletion` finalizers. The recovery was to clear the namespace-scoped `Role`/`RoleBinding` finalizers and re-run the sync; keep that breakglass path in the evidence note if it recurs.
- **No Prometheus:** Disabled in `values.yaml` for now; will be enabled when the Observability stack is fully integrated.
- **Committed render discipline:** `rendered-chart.yaml` is generated from the vendored chart plus `values.yaml`; do not hand-edit generated resources there.

## TLS, Access & Credentials

- **Root CA:** The `step-ca-root-ca` Secret is the source of truth for the `step-ca` ClusterIssuer.
- **Lifecycle:** `cert-manager/step-ca-root-ca` is derived from Step CA source secrets in `step-system`; after Step CA root recovery or rotation, rerun `Application/certificates-step-ca-bootstrap`, then rerun `CronJob/cert-smoke-step-ca-issuance`.
- **Degraded mode:** `ClusterIssuer/selfsigned-bootstrap` remains smoke/breakglass-only. If `step-ca-root-ca` is missing or `ClusterIssuer/step-ca` is not ready, treat platform and tenant endpoint issuance/renewal as degraded until the Step CA path is restored.
- **Tenant model:** Tenant endpoint TLS is platform-owned. Tenant repos do not author `Certificate`/`Issuer` resources; today the tenant provisioner reconciles per-org wildcard endpoint certificates, and the target end-state is controller-owned exact-host certificates instead of wildcard certificates.
- **Access:** No user credentials here; the stack is infrastructure plumbing.
- **See also:** `docs/component-issues/cert-manager.md` for open items.

## Dev → Prod

- **Promotion:**
  - Update chart version in the vendored chart metadata/render path or `helm/` values.
  - Promote `issuers/` changes through the standard GitOps flow (Branch -> Review -> Merge).

## Smoke Jobs / Test Coverage

- **Operational Health:** The chart’s `startupapicheck` Job specifically tests that the webhook is answering requests before the release is marked successful.
- **Functional Validation:**
  - Create a test `Certificate` resource and wait for `Ready=True`.
  - Verify the resulting Secret contains `tls.crt` and `tls.key`.
  - **Automated:** `platform/gitops/components/certificates/cert-manager/tests` runs `Job/cert-manager-certificate-smoke` to create a self-signed `Certificate` and wait for `Ready=True`.
  - The smoke Job is hardened with non-root execution, dropped capabilities, bounded resources, and a digest-pinned tools image so upgrade/rollback validation stays reproducible.

## HA Posture

- **Control Plane:** Running with `replicaCount: 2` for cert-manager-controller, webhook, and cainjector.
- **Leadership:** `global.leaderElection` is enabled to ensure only one active controller processes resources.
- **PDBs:** Explicitly enabled in `helm/values.yaml` (`minAvailable: 1`) for controller, webhook, and cainjector to prevent avoidable downtime during voluntary disruptions.
- **Placement resilience:** Each of controller, webhook, and cainjector now uses preferred hostname `podAntiAffinity` plus `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway`, so two replicas prefer different nodes without deadlocking single-node/dev scheduling.

## Security

- **Privileges:** The controllers run with high privileges (managing Secrets and Certificates across the cluster).
- **Supply chain:** The chart-managed controller images are pinned by digest in `helm/values.yaml`; `./tests/scripts/validate-cert-manager-supply-chain-contract.sh` enforces those pins and README coverage, `./tests/scripts/verify-cert-manager-chart-vendor.sh` verifies the vendored chart against the signed upstream release defined in `helm/upstream-chart-metadata.yaml`, and `./tests/scripts/scan-cert-manager-images.sh` is the required vulnerability review step for bumps and periodic revalidation.
- **Network:** The webhook server must be reachable from the API server (TCP 10250/10260).
- **TLS:** Internal components use mTLS for communication. Public-facing certificates are issued via the configured ClusterIssuers.
- **NetworkPolicies:** Selector-scoped `NetworkPolicy` and `CiliumNetworkPolicy` resources now implement a layered policy set for this namespace:
  - controller, webhook, and cainjector egress are restricted to DNS plus Kubernetes API access
  - controller egress is additionally allowed to Step CA (`step-system`, TCP `443`/`9000`)
  - webhook ingress is restricted to Kubernetes API traffic, with Cilium entity allows for `kube-apiserver`, `remote-node`, and `host` to keep Talos control-plane traffic and kubelet probes working without opening the webhook to arbitrary in-cluster pods

## Backup and Restore

- **Component-owned restore scope:** The cert-manager component itself owns the controller install plus GitOps-managed `ClusterIssuer` resources. Platform and tenant endpoint `Certificate` CRs are restored through their owning components/controllers, not here.
- **Runtime state classification:**
  - `ClusterIssuer/*` for this component are GitOps-managed and restorable from repo state.
  - `CertificateRequest`, `Order`, and `Challenge` resources are ephemeral runtime artefacts and are not the backup material for this component.
  - `Secret/cert-manager/step-ca-root-ca` is a derived Secret, not the custody root.
- **Backup Strategy:**
  - GitOps is the restore source for the cert-manager chart render and the component-owned `ClusterIssuer` objects.
  - Step CA source secrets in `step-system` (hydrated from Vault/ESO) are the recovery source for `cert-manager/step-ca-root-ca`.
  - The implemented recovery drill is `./scripts/ops/cert-manager-restore-drill.sh`; see `docs/toils/cert-manager-restore-drill.md`.
- **Disaster Recovery:**
  - If cert-manager is lost: re-sync `certificates-cert-manager`, then `certificates-cert-manager-issuers`.
  - If `cert-manager/step-ca-root-ca` is lost: regenerate it from the Step CA source secrets using the repo bootstrap logic (`./scripts/ops/cert-manager-restore-drill.sh --mode scratch` for the routine drill, `--mode live` only with explicit acknowledgement).
  - Post-recovery validation must include both Step CA issuance smoke and `Job/cert-manager-certificate-smoke`.
