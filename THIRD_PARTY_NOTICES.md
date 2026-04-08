# Third-Party Notices (and commercialization notes)

This document is **not legal advice**. It is an engineering-oriented inventory + workflow intended to reduce the chance of accidental license non-compliance when shipping DeployKube as a product.

## 1) Repository license

The DeployKube repository (unless noted otherwise in-file) is licensed under **Apache-2.0** (see `LICENSE`).

Important: some files in this repo are copied/generated from upstream projects and remain under their original licenses; see “In-repo third-party artefacts” below.

## 2) In-repo third-party artefacts (committed files)

The following third-party artefacts are committed into this repository and retain their upstream licenses:

- **Gateway API “Standard install” CRDs bundle** (Apache-2.0)
  - Path: `platform/gitops/components/networking/gateway-api/standard-install.yaml`
  - Upstream: https://github.com/kubernetes-sigs/gateway-api
- **CloudNativePG operator manifest (vendored output)** (Apache-2.0)
  - Path: `platform/gitops/components/data/postgres/cnpg-operator/manifest.yaml`
  - Upstream: https://github.com/cloudnative-pg/cloudnative-pg
- **Grafana Tempo Helm chart** (Apache-2.0)
  - Path: `platform/gitops/components/platform/observability/tempo/charts/tempo/`
  - Upstream: https://github.com/grafana/helm-charts

## 3) Runtime stack: license risk inventory (current target stack)

The current platform stack is defined in `target-stack.md`. Licenses below are a pragmatic “risk map” for commercialization discussions (not an exhaustive legal review).

### Component → license map (as of `target-stack.md` Dec 2025)

This is the “what is in the stack right now” map. If you change the stack (new component, major bump, or vendor switch), update this table.

| Component | Scope | License | Notes / link |
|---|---|---|---|
| Kubernetes (incl. Gateway API) | Cluster runtime | Apache-2.0 | https://github.com/kubernetes/kubernetes |
| kind / kindest/node | Dev cluster runtime | Apache-2.0 | https://github.com/kubernetes-sigs/kind |
| Talos Linux | Prod nodes | MPL-2.0 | https://github.com/siderolabs/talos |
| Proxmox VE | Prod virtualization host | AGPL-3.0 | https://pve.proxmox.com/wiki/Developers_Documentation#Software_License |
| OrbStack | Dev virtualization host | Proprietary | vendor EULA |
| Cilium (+ Hubble) | CNI | Apache-2.0 | https://github.com/cilium/cilium |
| MetalLB | LoadBalancer | Apache-2.0 | https://github.com/metallb/metallb |
| Istio | Service mesh | Apache-2.0 | https://github.com/istio/istio |
| Kiali | Mesh UI (optional in dev) | Apache-2.0 | https://github.com/kiali/kiali |
| PowerDNS Authoritative Server | DNS | GPL-2.0 | https://github.com/PowerDNS/pdns |
| ExternalDNS | DNS automation | Apache-2.0 | https://github.com/kubernetes-sigs/external-dns |
| CoreDNS | Cluster resolver | Apache-2.0 | https://github.com/coredns/coredns |
| cert-manager | Certificates | Apache-2.0 | https://github.com/cert-manager/cert-manager |
| step-certificates (step-ca) | Internal CA | Apache-2.0 | https://github.com/smallstep/certificates |
| OpenBao | Secrets store | MPL-2.0 | https://github.com/openbao/openbao |
| SOPS | Bootstrap secret encryption | MPL-2.0 | https://github.com/getsops/sops |
| External Secrets Operator | Secret sync | Apache-2.0 | https://github.com/external-secrets/external-secrets |
| Argo CD | GitOps engine | Apache-2.0 | https://github.com/argoproj/argo-cd |
| Forgejo | Git service | GPL-3.0-or-later | https://forgejo.org/compare/ |
| Keycloak | Identity/OIDC | Apache-2.0 | https://github.com/keycloak/keycloak |
| Kyverno | Policy engine | Apache-2.0 | https://github.com/kyverno/kyverno |
| nfs-subdir-external-provisioner | Storage provisioner | Apache-2.0 | https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner |
| local-path-provisioner (dev single-node profile) | Storage provisioner | Apache-2.0 | https://github.com/rancher/local-path-provisioner |
| Garage | S3-compatible object storage | AGPL-3.0 | https://github.com/deuxfleurs-org/garage |
| CloudNativePG | Postgres operator | Apache-2.0 | https://github.com/cloudnative-pg/cloudnative-pg |
| PostgreSQL (base image) | Database | PostgreSQL License | https://www.postgresql.org/about/licence/ |
| Valkey | Redis-compatible store | BSD-3-Clause | https://github.com/valkey-io/valkey |
| Grafana | Observability UI | AGPL-3.0 | https://github.com/grafana/grafana |
| Loki | Logs backend | AGPL-3.0 | https://github.com/grafana/loki |
| Tempo | Tracing backend | AGPL-3.0 | https://github.com/grafana/tempo |
| Mimir | Metrics backend | AGPL-3.0 | https://github.com/grafana/mimir |
| Alloy | Observability agent | Apache-2.0 | https://github.com/grafana/alloy |
| kube-state-metrics | Metrics exporter | Apache-2.0 | https://github.com/kubernetes/kube-state-metrics |
| node-exporter | Metrics exporter | Apache-2.0 | https://github.com/prometheus/node_exporter |
| metrics-server | Metrics pipeline | Apache-2.0 | https://github.com/kubernetes-sigs/metrics-server |
| Factorio (optional examples app) | Workload | Proprietary / EULA | vendor terms |
| Minecraft / Modpacks (optional examples app) | Workload | Proprietary / EULA | vendor terms |

### Permissive (commercial-friendly)

Typically Apache-2.0/BSD/MIT-style licenses. You can sell your product and redistribute these components, but must comply with notice + license-text requirements when you distribute copies (e.g. when you ship container images or air-gapped bundles).

Examples in the current stack include (non-exhaustive):
- Kubernetes / Gateway API / kind
- Argo CD
- Cilium / MetalLB / Istio / Kiali
- cert-manager
- External Secrets Operator
- Keycloak
- Kyverno
- CloudNativePG
- Valkey (BSD-3-Clause)

### Weak copyleft (MPL-2.0)

File-level copyleft (generally manageable, but track modifications if you vendor/patch upstream source files).

Examples (non-exhaustive):
- Talos Linux (MPL-2.0)
- OpenBao (MPL-2.0)
- SOPS (MPL-2.0)

### Strong copyleft (GPL/AGPL)

If you **distribute** these components (for example, by shipping pre-pulled container images, an offline registry, or an appliance), you generally must provide corresponding source code and preserve license notices. If you **modify** and offer them as a network service (AGPL), you must make modifications available to network users.

Examples in the current stack include (non-exhaustive):
- Proxmox VE (AGPLv3)
- Grafana (AGPLv3)
- Loki / Tempo / Mimir (AGPLv3)
- Garage (AGPLv3)
- PowerDNS Authoritative Server (GPL-2.0)
- Forgejo (GPLv3+ as of Forgejo v9.0+)

### Source-available / restricted-use (commercial risk)

These licenses can be incompatible with some business models (notably “offer as a hosted service competitive with the upstream vendor”).

Current default stack:
- None

Possible optional/customer-supplied variant:
- HashiCorp Vault (BSL-1.1; verify exact terms for the shipped version and hosting model)

### Proprietary / EULA-bound (do not bundle without legal review)

Examples in this repo’s ecosystem:
- OrbStack (dev environment dependency)
- Optional “example apps” (e.g. Minecraft/Modpacks, Factorio) often have licenses/EULAs that make redistribution as part of a commercial product non-trivial.

## 4) Commercialization guidance (engineering)

Before “selling DeployKube”, decide which of these you are shipping:

1) **GitOps-only (source manifests + scripts)**: customer pulls upstream charts/images themselves.
   - Lowest redistribution obligations (you’re mostly shipping your own Apache-2.0 repo).
2) **Air-gapped / appliance / offline bundle**: you ship container images + chart sources.
   - You become a redistributor: you must ship license texts/notices and (for GPL/AGPL) corresponding source (or a compliant written offer), and track any modifications you make.
3) **Hosted service** (you run it for customers):
   - Re-check BSL and similar “competitive offering” clauses for any source-available software included in that offering.
   - For AGPL components: if you patch/modify them, you must provide those modifications to network users.

## 5) Process: keeping us out of trouble

When adding a new component (or bumping major versions):

1) Record the component’s license category in `target-stack.md` (short note) **and** update this file if it changes the risk profile.
2) If the component is GPL/AGPL/BSL/proprietary: add a note to the component README (`platform/gitops/components/.../README.md`) under “Security” or “Oddities / Quirks” and track any mitigation in `docs/component-issues/<component>.md`.
3) If we vendor/copy upstream sources into this repo: preserve upstream `LICENSE`/`NOTICE` and keep provenance (upstream repo + version) next to the vendored artefact.
