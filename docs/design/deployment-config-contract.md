# Design: Central Deployment Config Contract

Last updated: 2026-01-20  
Status: Phase 1–3 implemented (repo-only); Phase 4 planned

## Tracking

- Canonical tracker: `docs/component-issues/deployment-config-contract.md`

## Purpose

Stop “deployment identity” from being hard-coded and scattered across manifests and scripts, and reduce the current environment-to-environment toil (dev vs prod path patches) by introducing a single, versioned **deployment config contract** that both:

- **Bootstrap tooling** (Stage 0/Stage 1 and operator helpers) can read for defaults, and
- **GitOps** can consume to render/parameterize environment-specific resources.

This is an essential prerequisite for the longer-term “single YAML provisioner” direction, without committing to CRDs/controllers yet.

## Scope / ground truth

This design is grounded in **repo reality** only:

- GitOps: `platform/gitops/**`
- Bootstrap/scripts: `shared/scripts/**`, `scripts/**`, `bootstrap/**`
- Docs: `docs/**`, `target-stack.md`

No live cluster assumptions.

## Problem Statement (repo-grounded)

### 1) Hard-coded deployment identity

The repository currently bakes in concrete identity values:

- GitOps manifests hard-code public hostnames like `*.dev.internal.example.com` and `*.prod.internal.example.com` across many components (e.g. `platform/gitops/components/networking/istio/gateway/overlays/{dev,prod}/gateway.yaml`).
- Some helper scripts previously defaulted to a different convention (`*.dev.internal.example.com`) — **now fixed** to use `.internal`.
- Proxmox bootstrap config previously used `prod.internal.example.com` — **now fixed** to use `prod.internal.example.com`.

Risk: scaling to “many deployments” or “multi-customer hosted” becomes brittle and high-toil unless identity/config is centralized and validated.

### 2) Environment bundles patch dozens of Argo apps individually

The legacy GitOps environment selection model changed `spec.source.path` per Argo `Application` via long patch lists:

- Dev: `platform/gitops/apps/environments/mac-orbstack/patches/patch-app-dev-domain-overlays.yaml` (legacy)
- Dev (single-node): `platform/gitops/apps/environments/mac-orbstack-single/` (current; optimized for low memory)
- Prod: `platform/gitops/apps/environments/proxmox-talos/patches/patch-app-proxmox-domain-overlays.yaml` (legacy)

Risk: adding/removing apps or changing overlay strategy requires editing multiple patch lists and keeping them in sync.

## Goals

- **Single source of truth** for deployment identity:
  - base domain + per-service hostnames (explicit)
  - trust roots (e.g., Step CA root bundle path)
  - environment/deployment identifiers
  - network handoff mode (L2 today; eBGP later) + IP pools/VIPs that are identity-relevant
- **Single source of truth** for deployment-scoped ops configuration that should not be hard-coded across components/scripts:
  - backup/DR target endpoint + schedules (RPO defaults)
- **Reduce toil** by removing per-application “dev vs prod overlay path” patch lists.
- **Keep GitOps boundaries** intact (Stage 0/1 only prep + seed; steady-state via Argo CD).
- **Prevent regression**: add repo checks so new hard-coded domain strings don’t spread.
- **Keep `.internal` naming for now**. Treat `.int` usage as legacy/drift to eliminate once the contract is in place.

## Non-goals (for this design)

- Implement the “single YAML provisioner” (CRDs/controllers) described in `docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`.
- Implement BGP/VRF/anycast networking (this design only carries the config knobs; the implementation is future work).
- Re-architect the repo split (Forgejo mirror remains a snapshot of `platform/gitops` at monorepo `HEAD`).
- Full component refactors in one shot (migration is incremental).

## Proposed Contract

### Contract shape

Add one file per deployment under the GitOps subtree (so it mirrors into Forgejo):

- `platform/gitops/deployments/<deploymentId>/config.yaml`

This file is the **only** place where deployment-specific identity values should live (outside documentation/examples).

The file is a *configuration contract* (data), not executable logic.

### Versioning

Use a small versioned schema to allow evolution:

- `apiVersion: platform.darksite.cloud/v1alpha1`
- `kind: DeploymentConfig`

The contract should be treated like an API: changes must be reviewed as carefully as code changes.

### Minimal required fields (v1alpha1)

- Identity:
  - `spec.deploymentId` (string, stable identifier; must match folder name; enforced by validation)
  - `spec.environmentId` (enum: `dev|prod|staging`, semantic intent)
  - `spec.dns.baseDomain` (string; **`.internal` convention**, e.g. `prod.internal.example.com`; must be unique per deployment; enforced by validation)
  - `spec.dns.hostnames` (map; explicit hostnames for externally-reachable platform endpoints)
- Trust:
  - `spec.trustRoots.stepCaRootCertPath` (path in repo, default `shared/certs/deploykube-root-ca.crt`)
- Certificates mode contract:
  - `spec.certificates.platformIngress.mode` (`subCa|acme|wildcard`)
  - `spec.certificates.tenants.mode` (`subCa|acme`)
  - `spec.certificates.acme.*` (ACME directory + solver wiring when any surface uses `acme`)
  - `spec.certificates.platformIngress.wildcard.*` (BYO wildcard projection wiring when `platformIngress.mode=wildcard`)
- Network identity knobs:
  - `spec.network.handoffMode` (enum: `l2|ebgp`)
  - `spec.network.metallb.pools` (named pools; CIDR/range lists)
  - Optional pinned VIPs (when required by a deployment): `spec.network.vip.publicGatewayIP`, `spec.network.vip.powerdnsIP`, etc.

### Recommended additional fields (v1alpha1)

These fields are optional in the schema for backwards compatibility, but should be treated as “required for prod-class deployments” as part of the Phase 0 ops readiness baseline.

- Operator/LAN DNS resolvers (optional but strongly recommended when operators access the platform via a LAN DNS forwarder like Pi-hole):
  - `spec.dns.operatorDnsServers` (list of IPv4 addresses)
- Optional DNS authority + delegation contract:
  - `spec.dns.authority.nameServers` (nameserver FQDNs for zone `SOA/NS`; defaults to `ns1.<baseDomain>` when unset)
  - `spec.dns.delegation.mode` (`none|manual|auto`)
  - `spec.dns.delegation.parentZone` (parent zone where delegation records for `baseDomain` are created)
  - `spec.dns.delegation.writerRef.{name,namespace}` (required when `mode=auto`; references a Secret with writer settings)
    - current backend: `provider=powerdns` (default if omitted), plus `apiUrl`, `apiKey`, optional `serverId`, optional `nsTTL`, optional `glueTTL`
  - `spec.dns.cloudDNS.tenantWorkloadZones.enabled` (bool; enables tenant zone lifecycle controller)
  - `spec.dns.cloudDNS.tenantWorkloadZones.zoneSuffix` (DNS label segment; defaults to `workloads`, producing `<orgId>.<zoneSuffix>.<baseDomain>`)

- Secrets plane root-of-trust (v1; non-secret selector):
  - `spec.secrets.rootOfTrust.provider` (`kmsShim`)
  - `spec.secrets.rootOfTrust.mode` (`inCluster|external`)
  - `spec.secrets.rootOfTrust.assurance` (`low|external-soft`)
  - `spec.secrets.rootOfTrust.acknowledgeLowAssurance` (bool; **required** when `environmentId=prod` and `assurance=low`)
  - `spec.secrets.rootOfTrust.external.address` (string; **required** when `mode=external`)

- Certificates mode details (Option A):
  - `platformIngress.mode=wildcard` is for one platform wildcard cert (`*.${baseDomain}`) and does **not** apply to tenant workload hostnames.
  - Tenant workload wildcard certs remain per-tenant (`*.${orgId}.workloads.${baseDomain}`) and are controlled by `spec.certificates.tenants.mode` (`subCa|acme`).
  - ACME supports self-hosted and external directory URLs via `spec.certificates.acme.server`; success with external CAs depends on publicly-resolvable challenge DNS.
  - ACME DNS01 providers are `rfc2136|cloudflare|route53`, with provider-specific solver fields under `spec.certificates.acme.solver.*`.
  - Route53 supports ambient IAM credentials (no `credentials.vaultPath`) or Vault-projected static credentials.

- Backup / DR:
  - `spec.backup.enabled` (bool)
  - `spec.backup.target` (type + endpoint)
    - v1: `type: nfs` (`server`, `exportPath`, optional `mountOptions`)
    - future: `type: s3` (S3-compatible endpoint + bucket)
  - `spec.backup.rpo` (recommended defaults for tier schedules)
    - `tier0`, `s3Mirror`, `pvc` (durations like `1h`, `6h`)
  - `spec.backup.schedules` (optional Cron schedule overrides for backup-plane jobs)
    - `s3Mirror`, `smokeBackupTargetWrite`, `smokeBackupsFreshness`, `backupSetAssemble`, `pvcResticBackup`, `smokePvcResticCredentials`, `pruneTier0`, `smokeFullRestoreStaleness`
  - `spec.backup.retention` (recommended defaults)
    - `restic` retention flags (e.g. `--keep-daily 7 --keep-weekly 8`)

- Observability (deployment-scoped tuning knobs; non-secret):
  - Loki per-tenant limits:
    - `spec.observability.loki.limits.retentionPeriod` (duration like `24h`, `168h`)
    - optional: ingestion rate/burst and stream limits (future consumers)

### Hostname derivation rules (v1alpha1)

To avoid inconsistency, v1alpha1 intentionally **does not** allow consumers to invent hostnames from `baseDomain`.

- `spec.dns.hostnames` is **authoritative** for all user-facing/external platform endpoints (Argo CD, Forgejo, Vault, Keycloak, Grafana, etc.).
- `spec.dns.baseDomain` exists to:
  - define the DNS zone identity (PowerDNS zone name, CoreDNS stub domain),
  - enable validation (“all hostnames must be within baseDomain”), and
  - serve as future-proofing for a later “derived hostnames” feature (if we decide it is valuable).

If/when we add hostname derivation, it must be implemented in exactly one place (a shared renderer), not ad-hoc per script/component.

Example (illustrative only):

```yaml
apiVersion: platform.darksite.cloud/v1alpha1
kind: DeploymentConfig
metadata:
  name: proxmox-talos
spec:
  deploymentId: proxmox-talos
  environmentId: prod

  dns:
    baseDomain: prod.internal.example.com
    operatorDnsServers:
      - 198.51.100.3
    hostnames:
      argocd: argocd.prod.internal.example.com
      forgejo: forgejo.prod.internal.example.com
      keycloak: keycloak.prod.internal.example.com
      vault: vault.prod.internal.example.com
      grafana: grafana.prod.internal.example.com

  trustRoots:
    stepCaRootCertPath: shared/certs/deploykube-root-ca.crt

  secrets:
    rootOfTrust:
      provider: kmsShim
      mode: inCluster
      assurance: low
      acknowledgeLowAssurance: true

  network:
    handoffMode: l2
    metallb:
      pools:
        public:
          - 198.51.100.61-198.51.100.100
    vip:
      publicGatewayIP: 198.51.100.62
      powerdnsIP: 198.51.100.65

  backup:
    enabled: false
    # Configure before relying on DR.
    # target:
    #   type: nfs
    #   nfs:
    #     server: 198.51.100.20
    #     exportPath: /volume1/deploykube/backups
    # rpo:
    #   tier0: 1h
    #   s3Mirror: 1h
    #   pvc: 6h
    # schedules:
    #   s3Mirror: "7 * * * *"
    #   smokeBackupTargetWrite: "11 * * * *"
    #   pvcResticBackup: "17 */6 * * *"
    #   smokeBackupsFreshness: "29,59 * * * *"
    #   smokePvcResticCredentials: "41 */6 * * *"
    #   smokeFullRestoreStaleness: "43 4 * * *"
    #   backupSetAssemble: "47 * * * *"
    #   pruneTier0: "15 3 * * *"
    # retention:
    #   restic: --keep-within 2h --keep-hourly 24 --keep-daily 7 --keep-weekly 52

  observability:
    loki:
      limits:
        retentionPeriod: 168h
```

Dev example (illustrative only):

```yaml
apiVersion: platform.darksite.cloud/v1alpha1
kind: DeploymentConfig
metadata:
  name: mac-orbstack
spec:
  deploymentId: mac-orbstack
  environmentId: dev

  dns:
    baseDomain: dev.internal.example.com
    hostnames:
      argocd: argocd.dev.internal.example.com
      forgejo: forgejo.dev.internal.example.com
      keycloak: keycloak.dev.internal.example.com
      vault: vault.dev.internal.example.com
      grafana: grafana.dev.internal.example.com

  trustRoots:
    stepCaRootCertPath: shared/certs/deploykube-root-ca.crt

  secrets:
    rootOfTrust:
      provider: kmsShim
      mode: inCluster
      assurance: low

  network:
    handoffMode: l2
    metallb:
      pools:
        public:
          - 203.0.113.240-203.0.113.250

  observability:
    loki:
      limits:
        retentionPeriod: 24h
```

### Validation

Add a schema + validator to fail fast in CI/local checks:

- `platform/gitops/deployments/schema.json`
- `tests/scripts/validate-deployment-config.sh`

Validation should include:

- Required fields present.
- `.internal` domain convention enforced for now.
- `spec.deploymentId` must match:
  - `metadata.name`, and
  - the `<deploymentId>` folder name.
- Hostnames must be within `baseDomain`.
- `baseDomain` must be unique across all `platform/gitops/deployments/*/config.yaml` files (v1alpha1 assumes 1:1 zone → deployment).
- IP range formatting sanity checks (best-effort, not a full IPAM system).
- Cross-deployment IP pool overlap detection is **out of scope** for v1alpha1 (future enhancement; see “Future Evolution”).

Validator implementation (initial target):

- `tests/scripts/validate-deployment-config.sh` performs explicit checks (required keys + conventions + cross-file uniqueness) using `yq` (mikefarah) + bash.
- `platform/gitops/deployments/schema.json` is the contract’s canonical JSON Schema for documentation and future automated schema validation (AJV/CI enforcement can be added later if desired).

### Staging status

`environmentId: staging` exists to reserve the semantic shape of “staging” early, but staging is **not implemented yet** in this pass.

Initial deployment configs are expected only for:

- `mac-orbstack` (dev)
- `proxmox-talos` (prod)

`apps/environments/staging` remains a placeholder until we add a real staging deployment.

### Sensitivity / secrets

The deployment config is expected to remain **plaintext**:

- It must be readable as a values/input file by build/render tooling (Kustomize/Helm within Argo CD).
- It must not contain secrets (credentials, tokens, private keys).
- Hostnames, IP pools, and VIPs are treated as configuration, not secrets, in this repo model.
- Backup target endpoints (server hostnames, export paths) are also treated as configuration; any **backup target authentication material** must be stored outside this file (Vault and/or an encrypted recovery bundle per `docs/design/disaster-recovery-and-backups.md`).
- `spec.secrets.rootOfTrust` is **not** a secret: it is only a posture selector and wiring (keys/tokens live in Vault/DSB as applicable).

If a future threat model considers “IPs/hostnames are sensitive”, treat the entire GitOps repo as sensitive rather than SOPS-encrypting this contract (SOPS also complicates build-time consumption).

Bootstrap secrets (SOPS) are intentionally **out of scope** for this contract. The contract defines identity and non-secret inputs; bootstrap-only secret material is handled by the **Deployment Secrets Bundle (DSB)** design:

- `docs/design/deployment-secrets-bundle.md`

## Consumption Plan

### A) Bootstrap scripts (Stage 1 + helper scripts)

Bootstrap scripts should read the deployment config for defaults (but still allow overrides via env vars, for emergency/debugging).

In-cluster GitOps Jobs that need to branch on deployment posture should mount a GitOps-visible copy of this contract:
- ConfigMap: `argocd/deploykube-deployment-config` (published by the deployment-config-controller from the singleton `DeploymentConfig` CR).

Targeted consumers:

- `shared/scripts/bootstrap-mac-orbstack-stage1.sh` (root app path selection + trust root path)
- `shared/scripts/bootstrap-proxmox-talos-stage1.sh` (root app path selection + trust root path)
- Helper scripts defaults:
  - `shared/scripts/argocd-token.sh` (default `KEYCLOAK_HOST`, `ARGOCD_SERVER`, CA cert path)
  - `shared/scripts/vault-token.sh` (default `VAULT_ADDR`, `KEYCLOAK_HOST`, CA cert path)
  - `shared/scripts/forgejo-switch-gitops-remote.sh` (default `FORGEJO_CA_CERT`, and if applicable, host naming)

Design intent: stop “guessing” deployment hostnames in scripts; derive them from the contract.

### B) GitOps: controller-owned app catalog (no render artifacts)

The highest-leverage GitOps change is to remove long per-app patch lists and retire committed render artifacts for app-of-apps generation.

#### Implemented approach: `PlatformApps` CR + controller

DeployKube now treats app-of-apps generation as a controller-owned KRM API surface:

- CRD/Kind: `platform.darksite.cloud/v1alpha1`, `PlatformApps`
- Base spec (catalog): `platform/gitops/components/platform/platform-apps-controller/base/platformapps.platform.darksite.cloud.yaml`
- Reconciler: `platform-apps-controller` deployment
- Environment selection: each environment patches `Application/platform-platform-apps-controller` to pick a deployment overlay under `components/platform/platform-apps-controller/overlays/<deploymentId>`.

Why this approach:

- Keeps Argo CD ApplicationSet controller **disabled**.
- Removes renderer drift classes (`overlay-apps.yaml`, values files, render scripts).
- Keeps the source of truth in a single KRM object with GitOps-managed overlays.

Retired posture:

- The previous pre-rendered chart flow (`apps/charts/platform-apps` + committed `apps/environments/*/overlay-apps.yaml`) is retired.
- Validation now focuses on controller contract correctness (`tests/scripts/validate-platform-apps-controller.sh`) and env-bundle buildability.

#### Alternatives (not recommended for first iteration)

- **Enable ApplicationSet** and generate apps from the contract:
  - Adds a controller and operational surface area; repo currently documents ApplicationSet as disabled.
- **Kustomize replacements/vars** driven by a ConfigMap:
  - Possible, but requires introducing/standardizing a replacement pattern repo-wide (not used today) and does not solve “overlay selection” cleanly without additional structure.

### C) Gradual refactor: move identity-sensitive manifests behind the contract

After Applications are generated from a single config, start migrating the most identity-sensitive resources to consume the same deployment config:

High-impact first targets:

- `components/networking/istio/gateway` (listener hostnames + optional pinned LB IP)
- `components/certificates/ingress` (Certificate SANs)
- `components/dns/powerdns` + `components/networking/coredns` (zone + forwarding)
- `components/dns/external-sync` (target zone + host lists)

Migration principle:

- Keep component bases environment-neutral where possible.
- When env-specific data is unavoidable, source it from the deployment config rather than duplicating it in multiple overlays.

#### Target injection mechanism (for step 4)

For GitOps components (Istio gateway listeners, certificate SANs, DNS zone/bootstrap, etc.), the target pattern is:

- Use **Helm rendering** (either:
  - Argo `Application` sources that are Helm charts, or
  - Kustomize `helmCharts:` within the component) to template identity-bearing resources from the deployment config.

Rationale:

- Kustomize does not have a good built-in way to “read a YAML contract and pluck fields” without either:
  - rewriting the contract into a flat ConfigMap and using `replacements`, or
  - duplicating the same values across multiple overlays.
- Helm templates can consume the contract as a values document (even if the YAML is nested under `.spec`), making a single-file contract feasible.

This is intentionally deferred to migration step 4 to keep the initial change small; but it is the planned direction for eliminating hard-coded hostnames/IPs inside component overlays.

## Migration Plan (incremental)

1) **Introduce the contract + validation (no behavior change)**
   - Add `platform/gitops/deployments/<id>/config.yaml` for existing deployments (`mac-orbstack`, `proxmox-talos`).
   - Add schema + validator script.
   - Add a “no new hard-coded domains” repo check (initially warn-only if needed, then enforce).

2) **Normalize naming and defaults to `.internal`**
   - Update scripts currently defaulting to `.int` to derive from deployment config.
   - Update bootstrap docs/config examples that currently use `.int` to `.internal`.
   - Keep the actual deployed domains unchanged (we are standardizing repo truth, not forcing a live migration).

3) **Replace per-app patch lists with controller-owned `PlatformApps`**
   - Maintain app catalog in `PlatformApps` CR (`platform-apps-controller` base + per-deployment overlays).
   - Keep env bundles focused on selecting the right controller overlay.
   - Delete/retire legacy renderer artifacts and per-app overlay patch lists once no longer referenced.

4) **Move identity-heavy manifests behind the contract**
   - Convert hostnames and domain-specific resources to read from the deployment config (via Helm values or a standardized Kustomize pattern).
   - Track missing/uncertain pieces in `docs/component-issues/<component>.md` (not in READMEs).

## Testing / Safety Nets

Add/extend repo-only checks:

- `tests/scripts/validate-deployment-config.sh`:
  - Validate contract schema for all `platform/gitops/deployments/*/config.yaml`.
  - Enforce `.internal` convention for now.
- “No hard-coded identity” guardrail:
  - Fail if `*.internal.example.com` literals appear outside:
    - `platform/gitops/deployments/**` (the contract)
    - `docs/**` (docs/examples may mention it)
    - `tests/**` (fixtures)
    - `bootstrap/**` (bootstrap input examples; these will be migrated later)
  - Start by scoping to the current domain strings; later generalize to “any baseDomain literal not from the contract”.

When implementing changes:

- Capture evidence per the operating model (`docs/design/gitops-operating-model.md`): Argo `Synced/Healthy` + smoke output in `docs/evidence/**`.

## Risks and Mitigations

- **Risk: “contract becomes a dumping ground”**
  - Mitigation: strict schema + versioning; keep v1alpha1 small and scoped to identity.
- **Risk: templating increases complexity**
  - Mitigation: keep the initial Helm chart tiny and limited to generating Argo `Application` objects; do not template all components at once.
- **Risk: migration churn**
  - Mitigation: incremental steps with repo-only validation; keep old overlays until each component is migrated.

## Future Evolution (explicitly out of scope now)

Once this contract exists and is stable, it becomes the natural seed for:

- A “single YAML provisioner” (CRDs/controllers) that can reconcile deployments/tenants (`docs/ideas/2025-12-25-declarative-provisioning-single-yaml.md`).
- L3 network handoff (`handoffMode: ebgp`) and multi-zone scaling; the contract already has a place for these knobs.
- Renaming conventions (including potentially moving away from `.internal`) with controlled blast radius:
  - once consumers read from the contract, renaming is a contract update + validation, not a repo-wide search/replace.

### Tenant vs deployment config (separate contracts)

This contract is intentionally **deployment-scoped** (cluster/platform identity + network + trust), not tenant-scoped.

- Tenant onboarding and the tenant-facing contract surface are defined in the multitenancy design-doc set:
  - Tenancy model + label invariants: `docs/design/multitenancy.md`
  - GitOps/Argo boundaries: `docs/design/multitenancy-gitops-and-argo.md`
  - Secrets/Vault model: `docs/design/multitenancy-secrets-and-vault.md`
  - Storage + backups posture: `docs/design/multitenancy-storage.md`
  - Lifecycle/offboarding/support sessions: `docs/design/multitenancy-lifecycle-and-data-deletion.md`
- Implementation is tracked separately from this deployment contract:
  - `docs/component-issues/multitenancy-implementation.md`

Keeping deployment identity separate from tenant intent prevents the deployment config from becoming a “god object” and keeps future productization clean.

### Cross-deployment validation (future)

As soon as multiple deployments are actively maintained, consider extending repo checks to enforce:

- `baseDomain` uniqueness across deployments (v1alpha1 assumes this; the validator should enforce it).
- IP pool overlap constraints across deployments (if the deployments are meant to be routable within the same L2/L3 domain).

For now, only `baseDomain` uniqueness is treated as a hard constraint for v1alpha1; cross-deployment IPAM is deferred.
