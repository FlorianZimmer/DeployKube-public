# Introduction

This component implements the **cluster access contract** enforcement layer:

- Humans authenticate to Kubernetes via **Keycloak OIDC**
- Kubernetes RBAC is managed via GitOps
- The API server enforces **“access changes via Git only”** using **built-in** `ValidatingAdmissionPolicy` guardrails
- Breakglass remains the only exception

Design doc: `docs/design/cluster-access-contract.md`.

Open items (if any) live in: `docs/component-issues/access-guardrails.md`.

## Architecture

- Guardrails are enforced by Kubernetes admission (`ValidatingAdmissionPolicy` + bindings).
- The guardrails are cluster-scoped resources applied by Argo CD.
- The allow-list is intentionally minimal:
  - Argo CD application controller ServiceAccount (GitOps apply identity)
  - `rbac-system/rbac-namespace-sync` (namespace RoleBinding automation)
  - `system:kube-controller-manager` for Kubernetes-native reconciliation that would otherwise deadlock under RBAC immutability (ClusterRole aggregation updates; and namespace teardown deleting `Role`/`RoleBinding`).
  - Breakglass (`system:masters`, and on kubeadm-style clusters `kubeadm:cluster-admins`)
  - `policy-system` Kyverno service accounts for **narrow, self-managed** webhook lifecycle operations on Kyverno-owned webhook configurations (`kyverno-*`) so Kyverno can bootstrap and rotate/inject `caBundle` without requiring a breakglass/manual intervention (see `base/vap-guardrails-self-protection.yaml`).

## Subfolders

- `base/`: admission policies + bindings (cluster-scoped)
- `overlays/{mac-orbstack,mac-orbstack-single,proxmox-talos}/`: deployment-specific overlays; includes `smoke-tests/` and deployment-specific patches
- `smoke-tests/`: CronJobs that continuously prove enforcement works

## Container Images / Artefacts

- Uses Kubernetes built-in admission (`admissionregistration.k8s.io/v1` `ValidatingAdmissionPolicy`).
- Smoke jobs run with `registry.example.internal/deploykube/bootstrap-tools:1.4`.
- Verification control: `./tests/scripts/validate-access-guardrails-supply-chain-contract.sh` enforces canonical smoke image reference usage and docs alignment.

## Dependencies

- Kubernetes API server must have the `ValidatingAdmissionPolicy` admission plugin enabled (Stage 0 input).
- Kubernetes API server must have OIDC enabled (Stage 0 input; issuer + groups claim) for the OIDC runtime smoke.
- `shared-rbac` app must exist (for the `rbac-namespace-sync` ServiceAccount).
- Argo CD must be operational to apply/maintain guardrails.

## Communications With Other Services

### Kubernetes Service → Service calls

- None (cluster-scoped admission policies).

### External dependencies (Vault, Keycloak, PowerDNS)

- None directly. (OIDC client configuration lives under the Keycloak component.)

### Mesh-level concerns (DestinationRules, mTLS exceptions)

- Not applicable (no in-mesh workloads).

## Initialization / Hydration

- Applied by Argo CD as cluster-scoped resources.
- First application should happen before relying on “Git-only RBAC” governance.

## Argo CD / Sync Order

- Sync wave annotation: `-10` for policies and `-9` for bindings (so policies exist before bindings).
- Pre/PostSync hooks: none.
- Sync dependencies:
  - `platform-argocd` healthy
  - `shared-rbac` healthy (for allow-path smoke job)

## Operations (Toils, Runbooks)

- Offline breakglass procedure exists in the private working repo and is intentionally omitted from the public mirror.
- Smoke alert triage: `docs/runbooks/access-guardrails-smoke-alerts.md`
- OIDC runtime validation (repeatable): `docs/toils/kubernetes-oidc-runtime-validation.md`
- Validate smoke status:
  - `kubectl -n rbac-system get cronjob access-guardrails-smoke-allow-rbac-mutations`
  - `kubectl -n access-guardrails-system get cronjob access-guardrails-smoke-deny-rbac-mutations`
  - `kubectl -n access-guardrails-system get cronjob access-guardrails-smoke-oidc-runtime`
- Run manually (create Job from CronJob):
  - `kubectl -n rbac-system create job --from=cronjob/access-guardrails-smoke-allow-rbac-mutations access-guardrails-smoke-allow-manual`
  - `kubectl -n access-guardrails-system create job --from=cronjob/access-guardrails-smoke-deny-rbac-mutations access-guardrails-smoke-deny-manual`
  - `kubectl -n access-guardrails-system create job --from=cronjob/access-guardrails-smoke-oidc-runtime access-guardrails-smoke-oidc-runtime-manual`

## Customisation Knobs

- Allow-list identities are hard-coded in the policies (keep minimal; expand only intentionally).
- Smoke schedules differ by deployment overlay:
  - `mac-orbstack` and `mac-orbstack-single`: every 15 minutes
  - `proxmox-talos`: every 6 hours

## Oddities / Quirks

- The “deny” smoke job intentionally uses an identity that *is authorized by RBAC* to create RoleBindings, so it proves admission is actually enforcing the contract.

## TLS, Access & Credentials

- No service endpoints; only API-server admission config.
- Breakglass handling is described at the contract level in `docs/design/cluster-access-contract.md`; the exact operational procedure is intentionally omitted from the public mirror.

## Dev → Prod

- No promotion differences besides smoke schedule in current deployment overlays:
  - `mac-orbstack` and `mac-orbstack-single` (dev-like): every 15 minutes
  - `proxmox-talos` (prod-like): every 6 hours

## Smoke Jobs / Test Coverage

Smoke CronJobs prove three things continuously:

1) **Deny path**: a non-allowlisted identity cannot mutate RBAC (even if RBAC permissions exist).
2) **Allow path**: the RBAC automation identity (`rbac-namespace-sync`) can still create and clean up RoleBindings.
3) **OIDC runtime path**: Keycloak issues tokens containing the expected `groups` claim, and Kubernetes validates those claims end-to-end via `kubectl auth whoami` + `kubectl auth can-i`.

## HA Posture

Not assessed in Phase 0 (admission policy availability is a control-plane concern).

## Security

- The guardrails are cluster-scoped and deny access-critical mutations unless the request is from GitOps or breakglass.
- This is defense-in-depth; control-plane/root access can still disable the enforcement by changing API server flags.

## Backup and Restore

- Guardrails are fully reconstructible from Git; restore requires Stage 0 to enable `ValidatingAdmissionPolicy` on the API server.
