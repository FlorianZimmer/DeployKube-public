# Target Stack (Dec 2025)

Purpose: concise, repo-truth baseline for Proxmox+Talos (prod) and macOS+OrbStack/kind (dev) with minimal per-env diffs.

Scope/ground truth for this document:
- GitOps manifests in `platform/gitops/` (apps + components)
- Bootstrap scripts + inputs under `shared/scripts/` + `bootstrap/`
- Curated machine-readable proposal catalog in `versions.lock.yaml` for grouped bump reports (incremental coverage; this document remains the human-readable repo-truth summary)
- No live cluster validation (no `kubectl`-derived claims)

## Environments (implemented)
- Dev: macOS + OrbStack + kind, pinned to `kindest/node:v1.34.0` (`bootstrap/mac-orbstack/cluster/kind-config-single-worker.yaml`).
- Prod: Proxmox + Talos, pinned to Talos `v1.10.8` and Kubernetes `1.34.2` (`bootstrap/proxmox-talos/config.yaml`).
- Minimum worker nodes (prod baseline): 3.

## GitOps boundary (implemented)
- Stage 0 (host scripts): provisions the cluster + installs “bring-up” prerequisites (Cilium, MetalLB, NFS provisioner, Gateway API CRDs).
- Stage 1 (host scripts): installs Forgejo + Argo CD, seeds `platform/gitops/` into Forgejo, applies root app `platform-apps`.
- Everything after bootstrap is declared under `platform/gitops/apps/**` and `platform/gitops/components/**` (and reconciled by Argo CD).

## Core platform (implemented)

### Networking / ingress / mesh
- **CNI**: Cilium with kube-proxy replacement and Hubble enabled (installed by Stage 0; proxmox and mac Stage 0 pin chart version `1.18.5`).
- **LoadBalancer**: MetalLB Helm chart `0.15.2` (app `v0.15.2`) via Argo app `networking-metallb`; address pools via `components/networking/metallb`. Stage 0 pre-installs MetalLB and pins chart version `0.15.2`.
- **Gateway API CRDs**: `v1.4.0` via Argo app `networking-gateway-api` (`components/networking/gateway-api/standard-install.yaml`). Stage 0 also applies CRDs (dev defaults to `v1.4.0`; prod Stage 0 currently pre-applies `v1.2.0` but GitOps upgrades it to `v1.4.0`).
- **Ingress**: Gateway API `GatewayClass istio` + `Gateway public-gateway` (`components/networking/istio/gateway`); user-facing apps expose `HTTPRoute`s per component.
- **Tenant egress (Tier S)**: platform-managed HTTP(S) forward proxy per org/project (`components/networking/egress-proxy`), rendered from tenant registry + allowlist intent.
- **Mesh**: Istio installed via operator image `docker.io/istio/operator:1.23.3` (`components/networking/istio/control-plane/operator-rendered.yaml`). The control plane/gateway version follows operator defaults unless overridden by the `IstioOperator` CR.
- **Mesh security**: mesh-wide **STRICT mTLS** enforced via `PeerAuthentication` + `DestinationRule` (`components/networking/istio/mesh-security`). There is no separate “deny-plaintext” `AuthorizationPolicy` in-repo.
- **Kiali**: Helm chart `2.15.0` (app `v2.15.0`) via Argo app `networking-istio-kiali`; disabled by default in the `mac-orbstack-single` playground to save resources.
- **Hubble UI ingress**: HTTPRoute/DestinationRule via `components/networking/hubble`; disabled by default in the `mac-orbstack-single` playground to save resources (Cilium still runs).

### DNS
- **Authoritative DNS**: PowerDNS Auth `powerdns/pdns-auth-46:4.6.4` (`components/dns/powerdns`).
- **ExternalDNS**: `registry.k8s.io/external-dns/external-dns:v0.14.1` (`components/dns/powerdns/externaldns.yaml`).
- **Optional DNS delegation contract**: `DeploymentConfig.spec.dns.delegation` supports `mode=none|manual|auto` with parent-zone writer references; the controller publishes computed delegation state in `DeploymentConfig.status.dns.delegation`, and auto mode reconciles parent-zone records via writer backends (`powerdns`, `dnsendpoint`) in tenant-provisioner.
- **Cloud DNS API/controller (implemented baseline)**: `dns.darksite.cloud/v1alpha1 DNSZone` reconciled by tenant-provisioner supports:
  - platform mode (per-tenant workload zones `<orgId>.workloads.<baseDomain>` + tenant RFC2136 credentials via Vault/ESO), and
  - standalone mode (arbitrary delegated zones via explicit `DNSZone` resources).
- **Platform Postgres API/controller (implemented baseline)**: `data.darksite.cloud/v1alpha1` now ships `PostgresClass` and `PostgresInstance`, installed via dedicated Argo apps and reconciled by `platform-postgres-controller` (`components/platform/apis/data/data.darksite.cloud/**`). Keycloak, Forgejo, PowerDNS, and Harbor are migrated internal consumers, and platform-only disposable classes now cover PoC/lab cases such as IDLab; tenant exposure remains gated.
- **Apex/wildcard sync**: PostSync Job `dns/external-sync` updates DNS records for:
  - platform ingress hostnames (to the Istio Gateway Service `public-gateway-istio`), and
  - per-tenant workloads wildcard hostnames `*.<orgId>.workloads.<baseDomain>` (to each tenant gateway Service `tenant-<orgId>-gateway-istio`).
- **Cluster resolver**: CoreDNS config component `components/networking/coredns`.

### Time synchronization
- **Cluster node time upstreams (implemented)**: `DeploymentConfig.spec.time.ntp.upstreamServers` is the cloud-wide source of truth for Talos node NTP upstreams (wired by Proxmox Stage 0).
- **Internal workload/LAN NTP endpoint (implemented)**: `components/platform/time-ntp` publishes `Service/time-system/platform-ntp` as `LoadBalancer` on UDP/123 for workload and LAN consumption.

### Certificates / trust
- **cert-manager**: Helm chart `v1.19.4` (app `v1.19.4`) via `components/certificates/cert-manager/helm`.
- **Internal CA (current implementation)**: Smallstep “step-certificates” Helm chart `1.28.4` (app `0.28.4`) via `components/certificates/step-ca/helm`.
- **High-assurance external CA (implemented for platform ingress)**: Vault PKI with cert-manager integration for external client-facing issuance that requires CRL/OCSP publication; authoritative serial inventory and full restore drills remain open follow-up work.
- **Root trust**: DeployKube root CA bundle is committed at `shared/certs/deploykube-root-ca.crt` and reused by bootstrap + internal clients.

### Secrets
- **OpenBao (core secret plane)**: Helm chart `0.31.0` with OpenBao image `2.1.0` in `vault-system`, Raft HA enabled (3 replicas) with configurable auto-unseal via `kms-shim` (in-cluster or external; selected per deployment config) (`components/secrets/vault/helm`).
- **External Secrets Operator**: Helm chart `1.0.0` (app `v1.0.0`) and resources use `external-secrets.io/v1` (`components/secrets/external-secrets`).
- **SOPS (bootstrap-only)**: used via the Deployment Secrets Bundle (DSB) under `platform/gitops/deployments/<deploymentId>/secrets/` (recipients in `platform/gitops/deployments/<deploymentId>/.sops.yaml`); Stage 1 loads the operator Age identities into `argocd/argocd-sops-age` (see `docs/design/deployment-secrets-bundle.md`).

### GitOps / identity / Git service
- **Argo CD**: bootstrap installs Helm chart `9.1.0` (app image tag pinned to `v3.2.0`) (`shared/scripts/bootstrap-*-stage1.sh`).
- **Forgejo**: bootstrap installs Helm chart `15.0.2` (Forgejo `13.0.2-rootless`) and GitOps then migrates it to CNPG + Valkey and configures ingress/OIDC (`components/platform/forgejo`).
- **Keycloak**: Keycloak operator image `quay.io/keycloak/keycloak-operator:26.4.4` and `RELATED_IMAGE_KEYCLOAK=quay.io/keycloak/keycloak:26.4.4` (`components/platform/keycloak/operator`).

### Policy / guardrails
- **Access guardrails**: Kubernetes `ValidatingAdmissionPolicy` enforcement for “access changes via Git only” (`components/shared/access-guardrails`).
- **Policy engine**: Kyverno Helm chart `3.6.1` (app `v1.16.1`) with Phase 0 tenant baseline constraints (`components/shared/policy-kyverno`).

### Storage / data plane
- **NFS provisioner (standard profiles)**: Argo app `storage-nfs-provisioner` installs `nfs-subdir-external-provisioner` chart `4.0.18` (app `4.0.2`). Stage 0 may pre-install the provisioner and pins chart version `4.0.18`.
- **Default StorageClass (RWO)**: `shared-rwo` (stable contract; **exactly one default** StorageClass).
  - Standard profiles: `shared-rwo` via `components/storage/shared-rwo-storageclass` (wave `-1`), backed by the NFS provisioner.
    - Posture: `reclaimPolicy=Retain`, `volumeBindingMode=Immediate`, `allowVolumeExpansion=true`.
  - Single-node profile v1 (`mac-orbstack-single`): `shared-rwo` via `components/storage/local-path-provisioner` (node-local hostPath at `/var/mnt/deploykube/local-path`); `storage-nfs-provisioner` is not installed.
    - Posture: `reclaimPolicy=Retain`, `volumeBindingMode=WaitForFirstConsumer`, `allowVolumeExpansion=false`.
- **Object storage**: Garage `docker.io/dxflrs/garage:v2.1.0` (`components/storage/garage`).
- **Postgres**: CloudNativePG operator Helm chart `0.26.1` (app `1.27.1`) and base Postgres image `registry.example.internal/cloudnative-pg/postgresql:16.3` (`components/data/postgres`). Internal product-owned Postgres intent now lives under `data.darksite.cloud/v1alpha1`; CNPG remains the current backend implementation.
- **Redis-compatible**: Valkey `valkey/valkey:9.0.0-alpine` (`components/data/valkey`).
- **OCI registry (platform)**: Harbor chart `1.18.2` (app `v2.14.2`) installed in `harbor` namespace (`components/platform/registry/harbor`), backed by an external CNPG Postgres cluster. Exposed via Gateway API hostnames `harbor.<baseDomain>` and `registry.<baseDomain>` (DeploymentConfig-driven).
- **Backups / DR (implemented baseline)**: `backup-system` wires an off-cluster NFS backup target (prod) and runs backup smokes (`storage-smoke-backup-target-write`, `storage-smoke-backups-freshness`) plus an S3 mirror tier (Garage platform buckets → backup target). Tier-0 (OpenBao + Postgres) write artifacts and `LATEST.json` markers into NFS-backed PVCs in prod (`docs/design/disaster-recovery-and-backups.md`).

### Observability (implemented)
The LGTM stack is implemented under `components/platform/observability` and included in `platform/gitops/apps/base/`:
- Grafana chart `10.1.4` (app `12.2.1`)
- Loki chart `6.46.0` (app `3.5.7`)
- Tempo chart `1.24.0` (app `2.9.0`)
- Mimir chart `6.0.5` (app `3.0.1`)
- Alloy chart `1.4.0` (app `v1.11.3`)
- kube-state-metrics chart `7.0.0` (app `2.17.0`)
- node-exporter chart `4.49.2` (app `1.10.2`)
- metrics-server chart `3.12.2` (app `0.7.2`)

### Security scanning / reports (implemented baseline)
- **Centralized repo/CI Trivy plane**: `tests/trivy/central-ci-inventory.yaml` plus `tests/trivy/components/*.yaml` and `tests/scripts/scan-trivy-ci.sh` provide the shared Trivy engine with component-owned target fragments and aggregate profiles. CI now resolves image scope from two curated catalogs:
  - `platform/gitops/artifacts/package-index.yaml` for product-owned artifacts
  - `platform/gitops/artifacts/runtime-artifact-index.yaml` for curated third-party runtime artifacts
- **Curated runtime artifact scan authority**: centralized Trivy CI resolves the runtime-artifact catalog via `distribution_ref`, so CI scans the shipped/mirrored artifact path rather than the upstream source path.
- **Catalog coverage enforcement**: `tests/scripts/validate-security-scanning-contract.sh` now fails when an image from either artifact catalog is missing from the default aggregate set, and still enforces that PR workflow path filters cover all declared Trivy watch paths.
- **Repo-owned image catalog enforcement**: `tests/scripts/validate-trivy-repo-owned-image-coverage.sh` now fails when deployable `platform/gitops/**` manifests introduce a `registry.example.internal/deploykube/*` image ref that is neither curated in `platform/gitops/artifacts/package-index.yaml` nor listed in `tests/fixtures/trivy-repo-owned-image-exemptions.txt`.
- **Expanded aggregate coverage**: the standard aggregate set now includes `platform-core`, `platform-services`, and `platform-foundations`, covering cert-manager, Vault, Kyverno, Harbor, Argo CD, Forgejo, Keycloak, Step CA, External Secrets, DNS, Postgres, Istio, and Observability through one centralized Trivy runner.
- **Full supported baseline coverage in CI**: the centralized Trivy plane now also covers the remaining supported baseline components `Garage`, `MetalLB`, `Valkey`, and the `nfs-subdir-external-provisioner`, so the standard aggregate profile set covers the full intended platform baseline in CI. Tenant workloads, opt-in apps, and PoCs remain out of scope by design.
- **Scoped PR coverage for covered components**: `tests/scripts/resolve-trivy-ci-targets.sh` and `.github/workflows/security-scanning.yml` run changed-component scans on pull requests while keeping push/schedule/manual scans on the standard aggregate profiles.
- **Expanded runtime-artifact catalog coverage**: Argo CD, Forgejo, Keycloak, DNS, Istio/Kiali, Step CA, Kyverno, Harbor, Vault/OpenBao, Observability, MetalLB, Garage, Valkey, NFS provisioner, and CNPG image targets now resolve from `runtime-artifact-index.yaml` instead of fragment-local manifest scraping.
- **Scheduled scan observability**: `.github/workflows/security-scanning.yml` publishes centralized scan freshness/status and latest high/critical totals into Mimir; Grafana dashboard + Mimir alerts live under `components/platform/observability`.

### Workload sizing (implemented)
- **Vertical Pod Autoscaler (VPA)**: `v1.5.1` (`registry.k8s.io/autoscaling/vpa-{recommender,updater,admission-controller}:1.5.1`) via `components/platform/ops/vertical-pod-autoscaler` to produce CPU/memory **request** recommendations (baseline is recommendations-only; cluster-wide for long-lived controllers via `components/platform/ops/vpa-recommendations`).

### HA tiering contract (implemented)
- Deployments/StatefulSets in the proxmox-talos platform render carry `darksite.cloud/ha-tier` labels (on workload metadata and pod template labels).
- Tier floors enforced by CI:
  - `tier-0`: odd quorum replicas, minimum 3
  - `tier-1`: minimum 2 replicas
  - `tier-2`: singleton/non-critical allowed
- This is intentionally not a global `replicas: 3` requirement for every workload.
- CI enforcement source: `tests/scripts/validate-ha-three-node-deadlock-contract.sh`.

## Not implemented yet / planned
- PTP support (contract + runtime wiring) for higher-precision sync use-cases; NTP baseline is implemented first.
- Security scanning/reporting platform:
  - Trivy Operator for cluster-native runtime/config/compliance reports,
  - Harbor built-in Trivy for registry-ingress and tenant-facing image scan UX.
- Cloud productization roadmap (ideas): multi-customer private cloud-in-a-box, three-zone anycast/BGP, single-YAML provisioning, four-eyes access/breakglass, marketplace, and a KRM-first UI (`docs/ideas/`).
- Cluster-wide backups: Velero + restore runbooks (beyond the current per-app jobs).
- CI: GitHub Actions (or similar) running bootstrap + smoke harness before merge.

## Bootstrap expectations
- Stage 0:
  - Dev: creates a kind cluster, brings up local registry caches, configures OrbStack-hosted NFS (unless using the single-node local-path profile), installs Cilium/MetalLB/NFS provisioner (standard profile), applies Gateway API CRDs.
  - Prod: provisions VMs, boots Talos, installs Cilium/MetalLB/NFS provisioner, applies Gateway API CRDs, writes kubeconfig `tmp/kubeconfig-prod`, and runs a preflight that verifies discovered `registry.example.internal/*` runtime image refs are present in the configured local mirror for `linux/amd64` (plus Talos pull-path smoke).
- Stage 1 (both): installs Forgejo + Argo CD, seeds `platform/gitops/` into Forgejo, applies root app, loads SOPS age key into Argo CD.
- Bootstrap tools image (used by bootstrap + many Jobs): `registry.example.internal/deploykube/bootstrap-tools:1.4` (Stage 0/1 defaults).
- Validation tools core image (used by low-surface smoke jobs): `registry.example.internal/deploykube/validation-tools-core:0.1.0`.
- SCIM bridge image (packaged platform service image for Keycloak upstream provisioning): `registry.example.internal/deploykube/scim-bridge:0.1.0`.

## Services catalogue (to include/maintain)
- Core: Step CA (current internal/private issuer path), Vault/OpenBao + ESO (secret plane plus implemented high-assurance external PKI host), Keycloak, Forgejo, Argo CD, PowerDNS/ExternalDNS, Harbor.
- Networking/mesh: Gateway API, Istio, MetalLB, Cilium, mesh-security verifier, (optional) Kiali/Hubble UI.
- Storage/data: `shared-rwo` (NFS-backed in standard profiles; node-local in single-node profile v1), Garage S3, CloudNativePG Postgres, Valkey.
- Observability: LGTM stack (Grafana, Loki, Tempo, Mimir) + Alloy + exporters.
- Apps currently shipped as GitOps components: Factorio, Minecraft (Monifactory).

## Acceptance criteria (per component)
- GitOps manifests/Helm values committed under `platform/gitops/components/...`.
- README covering purpose, HA/TLS, secrets, sync order, runbooks, and smoke tests.
- Argo apps `Synced/Healthy`; smoke test commands + sample output captured.
- Access instructions (URL, port, OIDC login, example curl/CLI).
