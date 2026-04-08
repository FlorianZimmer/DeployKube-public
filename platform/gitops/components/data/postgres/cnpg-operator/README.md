# Introduction

The `data/postgres/cnpg-operator` component installs the **CloudNativePG operator** in `cnpg-system`. It is the shared backend control plane for the platform's PostgreSQL consumers that now request intent through `data.darksite.cloud/v1alpha1` (`keycloak`, `forgejo`, `dns-system`, `harbor`, `idlab`, and future platform-owned consumers).

It installs the full upstream `postgresql.cnpg.io` CRD surface:
- `Backup`
- `Cluster`
- `ClusterImageCatalog`
- `Database`
- `FailoverQuorum`
- `ImageCatalog`
- `Pooler`
- `Publication`
- `ScheduledBackup`
- `Subscription`

This remains an intentional **third-party API exception** at the backend layer: CNPG still installs the upstream `postgresql.cnpg.io` CRDs, but the platform's stable Postgres contract now lives under `data.darksite.cloud`. Raw CNPG resources remain platform-internal implementation detail and should not be the normal consumer-facing surface.

For open/resolved issues, see [docs/component-issues/cnpg-operator.md](../../../../../docs/component-issues/cnpg-operator.md).

---

## Architecture

```mermaid
flowchart TB
    OP[CNPG Operator<br/>(Deployment)]
    CRD[CRDs<br/>postgresql.cnpg.io]
    API[K8s API]

    OP -->|Watches| API
    API -->|Stores| CRD
    OP -->|Reconciles| CLUSTERS[Postgres Clusters]
```

This component installs the operator only. It does **not** deploy any database clusters itself; `platform-postgres-controller` now owns the backend `Cluster` resources for the migrated consumers, while this component remains the shared CNPG control plane.

---

## Subfolders

| File | Purpose |
|------|---------|
| `manifest.yaml` | Vendored output of the official Helm chart (`cnpg/cloudnative-pg`). This is an upstream input, not the deployable artifact. |
| `crd-patches.yaml` | Post-render CRD patches. Keeps `Replace=true` on large CRDs while Argo's `Application` supplies `ServerSideApply=true`. |
| `patch-ha-deployment-cnpg-operator-cloudnative-pg.yaml` | Sets the production HA posture: `replicas: 2`, preferred hostname anti-affinity, and hostname topology spread. |
| `networkpolicies.yaml` | Default-deny `cnpg-system` traffic policy plus kube-apiserver/DNS and CNPG instance-manager status exceptions for the operator, plus webhook ingress rules. |
| `patch-operator-image-env-deployment-cnpg-operator-cloudnative-pg.yaml` | Keeps `OPERATOR_IMAGE_NAME` aligned with the digest-pinned deployable image reference. |
| `patch-vpa-requests-deployment-cnpg-operator-cloudnative-pg.yaml` | Mandatory resource patch for the operator Deployment. |
| `patch-ha-tier-labels.yaml` | HA tier labels required by the platform contract. |
| `poddisruptionbudget-cnpg-operator-cloudnative-pg.yaml` | Prevents voluntary disruptions from evicting both operator pods at once (`minAvailable: 1`). |
| `kustomization.yaml` | Deployable entrypoint. Applies the vendored manifest, digest-pins the operator image, and applies all required patches. |

---

## Container Images / Artefacts

| Artefact | Version | Source |
|----------|---------|--------|
| CloudNativePG operator image | `1.27.1` | `registry.example.internal/cloudnative-pg/cloudnative-pg:1.27.1@sha256:cfa380de51377fa61122d43c1214d43d3268c3c17da57612ee8fea1d46b61856` |
| CloudNativePG Helm chart | `0.26.1` | `https://cloudnative-pg.github.io/charts` |

Canonical version source in-repo:
- component-local operator/chart version details live here and in `manifest.yaml`
- `target-stack.md` is the human-readable repo-truth summary
- `docs/design/data-services-patterns.md` describes the pattern and points back here instead of duplicating the pin

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `networking-istio/namespaces` | Creates `cnpg-system` with `istio-injection=disabled` and a restricted Pod Security posture. |
| `shared/access-guardrails` | Allows only the narrow CNPG webhook/RBAC mutations the operator needs at runtime. |
| `shared/policy-kyverno` | Denies CNPG resources in tenant namespaces as defense in depth. |

> [!WARNING]
> **Namespace Security**: `cnpg-system` should run with `pod-security.kubernetes.io/enforce: restricted`. Keep it out-of-mesh to avoid coupling CNPG control-plane to Istio init container capabilities and to keep the kube-apiserver → webhook call path simple.

---

## Communications With Other Services

### Kubernetes Service → Service Calls

- **Operator → K8s API**: watches `postgresql.cnpg.io` resources and supporting core resources.
- **Kube-apiserver → Webhook**: reaches `Service/cnpg-webhook-service` on port `443` (`targetPort: 9443`).

### External Dependencies

- **None for the operator itself**: workload clusters it reconciles may depend on backup/object storage targets, but the operator control plane does not.

### Mesh-level Concerns

- **Out of mesh**: the operator runs out-of-mesh by default (`istio-injection=disabled` on `cnpg-system`).
- **Webhook path**: the admission webhook must be reachable by the kube-apiserver; keep CNPG out-of-mesh unless the full webhook path is explicitly proven.

---

## Initialization / Hydration

- **CRDs**: applied from the vendored manifest first. Each CRD gets `argocd.argoproj.io/sync-options: Replace=true` via `crd-patches.yaml`.
- **Argo apply mode**: `Application/data-postgres-operator` sets `ServerSideApply=true`; that Application is the runtime source of truth for CNPG's SSA posture in this repo.
- **Controller bootstrap**: the operator starts, creates/manages its webhook CA + serving certificate, patches the `cnpg-*` webhook configurations, and then waits for `Cluster` resources.

---

## Argo CD / Sync Order

| Application | Sync Wave | Notes |
|-------------|-----------|-------|
| `data-postgres-operator` | `-1` | Must sync before any consuming Postgres overlays. Argo applies this app with `ServerSideApply=true`. |

---

## Operations (Toils, Runbooks)

### Upgrade

1. Record the current chart/app versions before changing anything:
   - chart version from `manifest.yaml` labels (`helm.sh/chart: cloudnative-pg-<version>`)
   - operator version from `manifest.yaml`, this README, and `target-stack.md`
2. Verify the upstream chart source before vendoring a bump:

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-pg/charts/main/provenance.gpg -o tmp/cnpg-provenance.gpg
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg
helm pull cnpg/cloudnative-pg \
  --version <NEW_CHART_VERSION> \
  --verify \
  --keyring tmp/cnpg-provenance.gpg
```

3. Refresh `manifest.yaml` from the verified chart and keep the exact from/to chart + app versions in the evidence note:

```bash
helm template cnpg-operator cnpg/cloudnative-pg \
  --version <NEW_CHART_VERSION> \
  --namespace cnpg-system \
  --include-crds > manifest.yaml
```

4. Re-check `crd-patches.yaml` and the resource patch for drift/conflicts.
5. Resolve and update the digest-pinned operator image from the curated deployment registry path. Prefer the OCI index digest so the ref stays portable across Linux architectures:

```bash
digest="$(skopeo inspect \
  --override-os linux \
  --override-arch amd64 \
  docker://registry.example.internal/cloudnative-pg/cloudnative-pg:<APP_VERSION> \
  | jq -r '.Digest')"
```

6. Update:
   - `platform/gitops/components/data/postgres/cnpg-operator/kustomization.yaml`
   - `platform/gitops/components/data/postgres/cnpg-operator/patch-operator-image-env-deployment-cnpg-operator-cloudnative-pg.yaml`
   - `platform/gitops/artifacts/runtime-artifact-index.yaml`
   - this README if the canonical pinned ref changed
7. Render-check the deployable output:

```bash
PATH="$(pwd)/tmp/tools:$PATH" HELM_NO_PLUGINS=1 kustomize build platform/gitops/components/data/postgres/cnpg-operator
```

8. Let Argo reconcile `Application/data-postgres-operator`, then verify:
   - `Deployment/cnpg-operator-cloudnative-pg` becomes Available
   - `Secret/cnpg-system/cnpg-webhook-cert` exists
   - `MutatingWebhookConfiguration/cnpg-mutating-webhook-configuration` and `ValidatingWebhookConfiguration/cnpg-validating-webhook-configuration` contain non-empty `caBundle` data
   - the live Deployment image and `OPERATOR_IMAGE_NAME` env both use the reviewed digest
   - at least one existing CNPG consumer cluster still reconciles

### Rollback / Downgrade

1. Revert the Git commit that changed the chart render or patches.
2. Re-sync `Application/data-postgres-operator`.
3. Re-run the same verification set as the upgrade path.
4. Reconcile at least one existing CNPG consumer to prove the operator still handles live CRs.

Downgrade constraint:
- Treat CRD downgrades conservatively. If the target rollback would remove fields or schema versions already present in live `postgresql.cnpg.io` resources, do not force a downgrade just to restore an older chart render. Prefer a forward fix unless schema compatibility is explicitly confirmed.

Minimal validation checklist after upgrade or rollback:
- `kubectl -n cnpg-system get deploy cnpg-operator-cloudnative-pg`
- `kubectl -n cnpg-system get networkpolicy,ciliumnetworkpolicy`
- `kubectl -n cnpg-system get pdb cnpg-operator-cloudnative-pg`
- `kubectl -n cnpg-system get deploy cnpg-operator-cloudnative-pg -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}{"\n"}{.spec.template.spec.containers[?(@.name=="manager")].env[?(@.name=="OPERATOR_IMAGE_NAME")].value}{"\n"}'`
- `kubectl -n cnpg-system get secret cnpg-webhook-cert`
- `kubectl get mutatingwebhookconfigurations cnpg-mutating-webhook-configuration -o yaml`
- `kubectl get validatingwebhookconfigurations cnpg-validating-webhook-configuration -o yaml`
- `kubectl -n <consumer-namespace> get clusters.postgresql.cnpg.io`

---

## Customisation Knobs

- **Manifests**: vendored. `manifest.yaml` is not meant to be applied directly with `kubectl apply -f`.
- **Patch discipline**: customizations must stay in `kustomization.yaml` patches, not as manual edits to the vendored manifest.

---

## Oddities / Quirks

1. **Vendoring**: the chart is vendored to keep GitOps input immutable and reviewable, especially for CRD changes.
2. **Fixed sizing, not autoscaling**: the operator runs with explicit requests/limits from `patch-vpa-requests-deployment-cnpg-operator-cloudnative-pg.yaml`. We do not ship HPA/VPA actuation for CNPG itself; a recommendation-only `VerticalPodAutoscaler/cnpg-operator-cloudnative-pg` exists under `platform/ops/vpa-recommendations` to inform future tuning without mutating the workload.

---

## TLS, Access & Credentials

| Concern | Details |
|---------|---------|
| TLS | **Webhook**: CNPG manages its own CA and serving certificate for the admission webhook. The operator owns `Secret/cnpg-webhook-cert`, signs the webhook leaf certificate itself, and patches the `cnpg-*` webhook configurations with the required CA bundle. Upstream CNPG documents operator-managed certificate renewal 7 days before expiry (90-day default validity). |
| Access | **RBAC**: the operator ClusterRole manages `postgresql.cnpg.io` groups plus selected core resources. Access guardrails intentionally allow only the narrow webhook/RBAC mutations CNPG needs at runtime. |
| Credentials | None. |

Webhook secret lifecycle:
- `cnpg-webhook-cert` is **operator-owned runtime state**, not a GitOps-managed input.
- Recovery procedure if the secret or webhook bundle is missing/stale:
  1. confirm the operator pod is healthy,
  2. restart/reconcile the operator if needed,
  3. verify the secret is recreated/populated,
  4. verify both CNPG webhook configurations have current `caBundle` data.

Tenant model:
- CNPG resources are **platform-owned only** in this repo.
- Tenant AppProjects do not whitelist `postgresql.cnpg.io` kinds.
- Tenant namespace RBAC roles do not grant CNPG verbs.
- Kyverno denies CNPG resources in namespaces labeled `darksite.cloud/rbac-profile=tenant`, so tenants cannot bypass the GitOps boundary with direct `kubectl` use.

---

## Dev → Prod

Identical. The operator is a shared cluster service.

---

## Smoke Jobs / Test Coverage

- **Health checks**: standard liveness/readiness probes on the operator pod.
- **Webhook**: `cnpg-webhook-service` must be reachable by the kube-apiserver.
- **Smoke plan**:

```bash
kubectl -n cnpg-system get pods -l app.kubernetes.io/name=cloudnative-pg
kubectl -n cnpg-system logs -l app.kubernetes.io/name=cloudnative-pg
kubectl -n cnpg-system get secret cnpg-webhook-cert
kubectl get validatingwebhookconfigurations cnpg-validating-webhook-configuration
```

---

## HA Posture

- **Tier**: the operator is labeled `darksite.cloud/ha-tier=tier-1` and runs with `replicas: 2`.
- **Leadership**: CNPG keeps leader election enabled, so one pod reconciles while the second stays hot-standby for failover.
- **Placement resilience**: the deployable path adds preferred hostname `podAntiAffinity` plus hostname `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway`, so Proxmox prefers node spread without breaking single-node/dev scheduling.
- **Voluntary disruptions**: `PodDisruptionBudget/cnpg-operator-cloudnative-pg` sets `minAvailable: 1`, so drains and rollouts must leave one operator pod available.
- **Disruption**: if the operator is down, existing Postgres clusters continue to run (data path is unaffected), but reconciliation/failover management is unavailable.
- **Recovery**: node loss or pod failure should now leave one operator instance serving while Kubernetes reschedules the replacement.
- **Sizing**: enforced requests/limits are `15m` CPU / `96Mi` memory request with `144Mi` memory limit. Future tuning should use the recommendation-only VPA object as input, not live autoscaling actuation.

---

## Security

- **Namespace posture**: `cnpg-system` enforces `restricted` Pod Security and stays out-of-mesh.
- **ServiceAccount**: `cnpg-operator-cloudnative-pg` has broad cluster access to manage CNPG resources and selected core resources. This blast radius remains tracked as open work in the component issue tracker.
- **Tenant isolation**: tenant GitOps, tenant RBAC, and tenant admission all deny direct CNPG usage in tenant namespaces; current CNPG consumers remain platform-owned overlays only.
- **Supply chain**: the deployable operator image is digest-pinned in `kustomization.yaml`; `platform/gitops/artifacts/runtime-artifact-index.yaml` carries the same pinned ref, and centralized Trivy CI covers that runtime-artifact catalog (`./tests/scripts/validate-security-scanning-contract.sh`).
- **NetworkPolicies**: `networkpolicies.yaml` makes `cnpg-system` default-deny, allows DNS + kube-apiserver egress and HTTPS status checks to CNPG instance-manager pods (`cnpg.io/podRole=instance` on `8000/TCP`), and allows kube-apiserver/kubelet-sourced webhook ingress via a paired Kubernetes `NetworkPolicy` + `CiliumNetworkPolicy`.

---

## Backup and Restore

- **Stateless operator**: runtime state is CRD/webhook-driven; the operator Deployment itself is stateless.
- **Restore source**: Git restores the operator install and patches. Recovery of the runtime-owned webhook secret/config relies on operator-driven regeneration rather than a Git-managed secret input.
