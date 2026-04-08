# Introduction

This component installs **Kyverno** and the **Phase 0 tenant baseline constraints** defined in `docs/design/policy-engine-and-baseline-constraints.md`.

Open items live in: `docs/component-issues/policy-kyverno.md`.

## Architecture

- **Kyverno** runs in the `policy-system` platform namespace and enforces baseline constraints for **tenant namespaces only** (label-scoped).
- **VAP** is used for the tenant namespace label + identity contracts (A1/A2) to keep cluster-scoped validation small and Kyverno webhook scope tight.
- **Kyverno ClusterPolicies** enforce:
  - B1/B2: baseline NetworkPolicies (generated + drift-reconciled)
  - B3: NetworkPolicy guardrails (validate; safe cross-namespace selectors + platform allowlists)
  - C1/C2: baseline ResourceQuota/LimitRange (generated + drift-reconciled)
  - D1/D2: forbidden pod patterns + required pod security context (validate)
  - E1: Service type restrictions (validate)
  - E2: tenant Gateway API ingress guardrails + tenant gateway attachment contract (validate; route hijack prevention)
  - E3: deny direct cert-manager API usage in tenant namespaces (endpoint TLS is platform-owned)
  - E4: deny direct CloudNativePG API usage in tenant namespaces (Postgres clusters are platform-owned)
- A single **smoke suite CronJob** continuously proves enforcement and drift reconciliation.

## Subfolders

- `base/`: `policy-system` namespace + Kyverno Helm install + baseline policies + VAP A1/A2
- `policies/`: ClusterPolicies for the Phase 0 baseline
- `vap/`: ValidatingAdmissionPolicies for the tenant namespace label + identity contracts (A1/A2)
- `smoke-tests/`: suite CronJob and required RBAC
- `overlays/`: per-deployment wiring (smoke schedule tuning)
  - `overlays/mac-orbstack/`
  - `overlays/mac-orbstack-single/`
  - `overlays/proxmox-talos/`

## Container Images / Artefacts

- Kyverno Helm chart `3.6.1` (app `v1.16.1`) is vendored under `platform/gitops/components/shared/policy-kyverno/base/helm/charts/kyverno` (source upstream: `https://kyverno.github.io/kyverno/`).
- Controller images are pinned by chart app version and now distributed through the darksite runtime surface:
  - `registry.example.internal/kyverno/kyverno:v1.16.1`
  - `registry.example.internal/kyverno/kyvernopre:v1.16.1`
  - `registry.example.internal/kyverno/background-controller:v1.16.1`
  - `registry.example.internal/kyverno/cleanup-controller:v1.16.1`
  - `registry.example.internal/kyverno/reports-controller:v1.16.1`
- Smoke suite image: `registry.example.internal/deploykube/bootstrap-tools:1.4` (prod is patched to the local registry; the suite reuses its own running image for any test pods it creates).

## Dependencies

- `shared-access-guardrails` must allow the Kyverno admission controller ServiceAccount to manage Kyverno-owned admission objects (webhook configurations; and Kyverno-generated admission policies if enabled).
- CNI must enforce Kubernetes NetworkPolicy semantics (Cilium is installed by Stage 0).

## Communications With Other Services

### Kubernetes Service → Service calls

- Smoke suite calls the Kyverno metrics Service (`kyverno-svc-metrics`) in `policy-system`.

### External dependencies (Vault, Keycloak, PowerDNS)

- None.

### Mesh-level concerns (DestinationRules, mTLS exceptions)

- Kyverno and smoke tests run with Istio injection disabled in `policy-system`.

## Initialization / Hydration

- Kyverno is installed via Helm (Kustomize `helmCharts`) from a vendored chart (`helmGlobals.chartHome`) and self-manages its webhook configuration resources.
- Baseline resources for tenant namespaces are generated from `Namespace` events (and reconciled with `synchronize: true`).

## Argo CD / Sync Order

- `policy-system` namespace: sync wave `-10`.
- Kyverno Helm install: sync wave `-5` (includes CRDs, controllers, and config).
- VAP A1/A2: sync wave `-4` (cluster-scoped tenant namespace label + identity contracts).
- Baseline ClusterPolicies: sync wave `0`.
- Smoke suite CronJob + RBAC: sync wave `5`.

## Operations (Toils, Runbooks)

- Check Kyverno health:
  - `kubectl -n policy-system get deploy`
  - `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | rg '^kyverno'`
- Run smoke suite manually:
  - `kubectl -n policy-system create job --from=cronjob/policy-kyverno-smoke-baseline policy-kyverno-smoke-baseline-manual`
  - `kubectl -n policy-system logs -f job/policy-kyverno-smoke-baseline-manual`

## Customisation Knobs

- Webhook scope and match conditions: `platform/gitops/components/shared/policy-kyverno/base/helm/values.yaml`.
- Baseline quota/limits defaults: `platform/gitops/components/shared/policy-kyverno/policies/clusterpolicy-tenant-baseline-generate.yaml`.
- Enforced constraints and messages: `platform/gitops/components/shared/policy-kyverno/policies/`.
- Smoke suite runtime knobs (CronJob env vars):
  - `SMOKE_KEEP_NAMESPACES=true` leaves `policy-smoke-*` namespaces behind for manual debugging.
  - `SMOKE_STALE_NAMESPACE_TTL_SECONDS` controls the stale-namespace janitor threshold (default: 7200 seconds).

## Oddities / Quirks

- Kyverno webhooks are created/managed at runtime by Kyverno; the access guardrails must allow that narrow set of mutations.
- Kyverno’s chart binds controller ServiceAccounts to aggregated `ClusterRole`s; on clusters where `ClusterRole` aggregation is delayed/disabled, Kyverno can crash-loop on startup sanity checks. We ship explicit `*-:core` `ClusterRoleBinding`s in `base/` to avoid relying on aggregation.
- The Kyverno chart also ships a Helm-hooked `kyverno-migrate-resources` migration Job (and RBAC); we drop these hook resources from the rendered output to keep Argo sync deterministic.
- Baseline NetworkPolicies are Kyverno-owned and must be treated as immutable; exceptions are expressed as additional NetworkPolicies (never edits to the baseline).

## TLS, Access & Credentials

- No external service endpoints.
- Smoke suite uses in-cluster serviceaccount auth only.

## Dev → Prod

- Same component and policies; only the smoke schedule differs:
  - Dev (`overlays/mac-orbstack*`): hourly
  - Prod (`overlays/proxmox-talos`): every 6 hours

## Smoke Jobs / Test Coverage

- `policy-kyverno-smoke-baseline` (CronJob in `policy-system`) proves A1/A2/B1/B2/B3/C1/C2/D1/D2/E1/E2/E3/E4, webhook scoping invariants, PolicyException expiry discipline, Kyverno metrics reachability, and tenant gateway → tenant backend connectivity (ingress-to-tenant posture).

## Tenant NetworkPolicy guardrails (B3)

Tenant namespaces are default-deny, and any cross-namespace allow rules must stay narrow and reviewable.

Guardrail summary (tenant namespaces only):
- deny `ipBlock` peers
- deny empty/unbounded peers/selectors (`{}`, empty `matchLabels`, no `podSelector.matchLabels`)
- require tenant-scoped `namespaceSelector.matchLabels.darksite.cloud/tenant-id` for tenant-to-tenant cross-namespace peers
- allow platform namespaces only via narrow allowlists:
  - `kube-system`: DNS only (`podSelector.matchLabels={k8s-app: kube-dns}`)
  - `istio-system`: Istio gateway only (`podSelector.matchLabels={istio: ingressgateway}` or `podSelector.matchLabels={gateway.networking.k8s.io/gateway-name: tenant-<tenantId>-gateway}`)
  - `garage`: S3 only (`podSelector.matchLabels={app.kubernetes.io/name: garage, app.kubernetes.io/component: object-storage}`)

## HA Posture

- Kyverno admission controller runs with 2 replicas + PDB + anti-affinity (fail-closed for tenant namespaces).
- Background/cleanup/report controllers are single replica in Phase 0.

## Security

- Baseline constraints are scoped to namespaces labeled `darksite.cloud/rbac-profile=tenant`.
- Admission is fail-closed for tenant namespaces to avoid “policy down ⇒ policy bypass”.
- The restricted-PSS Pod validation has one identity-scoped exception for the platform backup runner (`system:serviceaccount:backup-system:backup-pvc-restic-runner`) so the PVC backup plane can create temporary NFS-backed backup pods and short-lived password Secrets in backup-scoped tenant namespaces.
- Webhook scoping/match conditions are treated as an invariant and continuously asserted by the smoke suite.

## Backup and Restore

- Kyverno install and baseline policies are fully Git-managed and reconstructed by Argo.
- Any PolicyExceptions are Git-managed; the smoke suite flags expired exceptions (process enforcement).
