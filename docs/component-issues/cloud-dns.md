# Cloud DNS – Known Issues & Follow-ups

Status: **implemented baseline** (optional delegation + tenant/standalone Cloud DNS + runtime smoke implemented; delegation output promoted to `DeploymentConfig.status`, tenant RFC2136 Vault scoping implemented; tenant-dedicated authoritative instances are explicitly deferred to the future dedicated-cluster/dedicated-hardware product tier)

Design:
- `docs/design/dns-delegation-and-cloud-dns.md`

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### High

#### general
- Per-tenant dedicated Cloud DNS instances are deferred to the future dedicated-cluster/dedicated-hardware product tier: the current shared-cluster Cloud DNS baseline is intentionally one shared authoritative service with per-tenant zones and credentials, and should not grow an intermediate per-tenant dedicated-instance mode inside the shared cluster. (ids: `dk.ca.finding.v1:cloud-dns:78a3941a48452ab95912c14165549cd1a47348f524d4e69415c9d2ee4664708b`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

- Related: `docs/design/dns-authority-and-sync.md`
- Related: `docs/design/multitenancy-networking.md`

## Open Items (Non-Blocking Hardening)

- **Per-tenant dedicated Cloud DNS instances are deferred to the dedicated-cluster tier:** the current shared-cluster product intentionally stops at shared authoritative service + per-tenant zones/credentials. If a high-paranoia isolation tier is needed, it should arrive with dedicated clusters on dedicated hardware rather than an intermediate per-tenant PowerDNS mode inside the shared cluster.

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- **Per-tenant dedicated Cloud DNS instances are intentionally deferred:** the shared-cluster Cloud DNS product stops at one shared authoritative service with per-tenant zones and credentials. High-paranoia isolation should be delivered by the future dedicated-cluster/dedicated-hardware product tier, not by adding an intermediate dedicated-instance mode inside the shared cluster.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-dns:78a3941a48452ab95912c14165549cd1a47348f524d4e69415c9d2ee4664708b", "last_seen_at": "2026-03-14", "links": ["docs/design/dns-delegation-and-cloud-dns.md"], "recommendation": "Keep the shared-cluster Cloud DNS scope at shared authoritative service + per-tenant zones/credentials, and defer tenant-dedicated authoritative instances until the dedicated-cluster/dedicated-hardware offering exists.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "Per-tenant dedicated Cloud DNS instances are intentionally deferred to the future dedicated-cluster product tier.", "topic": "general"}
{"class": "actionable", "details": "- **Manual output surface hardening:** manual delegation output now uses `DeploymentConfig.status.dns.delegation` as the canonical API surface, and the legacy `ConfigMap/argocd/deploykube-dns-delegation` has been retired.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-dns:8670b5455365e1480302f51f0e8352bd903b5de7aea2f4a9c0fbb5c6360eac16", "last_seen_at": "2026-03-14", "links": ["docs/design/dns-delegation-and-cloud-dns.md"], "recommendation": "Use DeploymentConfig.status.dns.delegation as the canonical manual delegation output surface.", "severity": "high", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Manual delegation output is promoted to DeploymentConfig.status.", "topic": "general"}
{"class": "actionable", "details": "- **Auto delegation backend expansion:** `powerdns` and `dnsendpoint` are implemented; keep the supported set intentionally frozen until a concrete deployment requires another provider.", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-dns:8cbc23ef18524b57f551baea404e81e92cbd8d92b58efda6eab8e56e207b3802", "last_seen_at": "2026-03-12", "links": ["docs/design/dns-delegation-and-cloud-dns.md"], "recommendation": "Keep the supported auto-delegation writer set at powerdns|dnsendpoint until a concrete deployment requires another provider.", "severity": "medium", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Auto delegation backend expansion is intentionally deferred until concrete provider demand exists.", "topic": "general"}
{"class": "actionable", "details": "- **Security posture:** Cloud DNS tenant RFC2136 credentials now use a tenant-scoped Vault policy/store path.\n  - `tenant-dns-rfc2136.sh` reconciles `k8s-tenant-<orgId>-cloud-dns-eso` roles with access limited to `secret/data/tenants/<orgId>/sys/dns/rfc2136`.\n  - `tenant_cloud_dns_controller.go` projects credentials via `ClusterSecretStore/vault-tenant-<orgId>-cloud-dns` instead of `vault-core`.", "evidence": [{"key": "ClusterSecretStore name vault-tenant-<orgId>-cloud-dns", "path": "tools/tenant-provisioner/internal/controllers/tenant_cloud_dns_controller.go", "resource": "controller:tenant-cloud-dns"}, {"key": "tenant-${org_id}-cloud-dns-rfc2136-ro + k8s-tenant-${org_id}-cloud-dns-eso", "path": "platform/gitops/components/secrets/vault/config/scripts/tenant-dns-rfc2136.sh", "resource": "vault tenant dns reconciler"}], "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:cloud-dns:7877b2814ec6f787c9ba0ddcbf5ebf46f88f9a02504a43e8fe24b45f8839df82", "last_seen_at": "2026-03-14", "links": [], "recommendation": "Keep Cloud DNS tenant RFC2136 reads on the tenant-scoped Vault policy/store path, not the broad vault-core store.", "severity": "high", "status": "resolved", "template_id": "legacy-component-issues.md", "title": "Security posture: tenant RFC2136 credential projection is scoped to a tenant-specific Vault store.", "topic": "general"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved Items

- **2026-03-14 – Dedicated-instance Cloud DNS scope narrowed:** recorded that per-tenant dedicated authoritative DNS instances are not a missing shared-cluster hardening item and are intentionally deferred until the future dedicated-cluster/dedicated-hardware product tier exists.
- **2026-03-14 – Manual delegation output promoted to DeploymentConfig status:** manual delegation output now uses `DeploymentConfig.status.dns.delegation` as the canonical API surface, and the legacy `argocd/ConfigMap/deploykube-dns-delegation` is removed.
- **2026-03-14 – Tenant RFC2136 Vault scoping implemented:** tenant Cloud DNS credential projection now uses tenant-scoped Vault policies/roles and controller-managed `ClusterSecretStore/vault-tenant-<orgId>-cloud-dns` instead of the broad `vault-core` store.
- **2026-03-12 – Delegated-authority exposure baseline documented:** documented that delegation is disabled unless explicitly configured, current deployment profiles pin manual mode, and proxmox authoritative DNS/API exposure is intentionally narrowed by `NetworkPolicy`.
- **2026-03-12 – Auto delegation provider scope documented:** recorded the intentional v1 boundary that auto delegation supports `powerdns` and `dnsendpoint` only until a concrete provider demand exists.

- **2026-02-22 – Manual delegation baseline implemented:** `DeploymentConfig` now supports `spec.dns.authority` + `spec.dns.delegation`, DNS wiring publishes authority/delegation inputs, and manual instructions are reconciled to `ConfigMap/argocd/deploykube-dns-delegation`.
- **2026-02-22 – external-sync authority fix:** zone `SOA/NS` + nameserver `A` records are now driven by explicit authority settings and authoritative DNS endpoint IP, no longer implicitly tied to ingress VIP.
- **2026-02-22 – Auto delegation writer implemented:** `spec.dns.delegation.mode=auto` now reconciles parent-zone `NS` + glue `A` records via a PowerDNS writer Secret referenced by `spec.dns.delegation.writerRef`.
- **2026-02-22 – Auto delegation portability implemented:** added `provider=dnsendpoint` writer backend that reconciles `externaldns.k8s.io/v1alpha1 DNSEndpoint` resources for external-dns publication.
- **2026-02-22 – Tenant workload-zone lifecycle implemented:** per-tenant `DNSZone` resources (`<orgId>.workloads.<baseDomain>`) are derived from `Tenant` + `DeploymentConfig`, delegated from base zone, and integrated with external-sync wildcard exclusion.
- **2026-02-22 – Tenant RFC2136 credential lifecycle implemented:** Vault CronJob issues/rotates per-tenant TSIG credentials at `secret/tenants/<orgId>/sys/dns/rfc2136`; platform-managed `ClusterExternalSecret` projects credentials into tenant namespaces.
- **2026-02-22 – Standalone Cloud DNS API baseline implemented:** introduced `dns.darksite.cloud/v1alpha1 DNSZone` CRD/controller for arbitrary zone hosting + optional parent delegation.
- **2026-02-22 – Runtime smoke coverage added:** added `CronJob/cloud-dns-tenant-zone-smoke` in proxmox overlay validating tenant zone presence, delegation, and credential projection.
- **2026-02-22 – Feature request acceptance criteria closed:** completed Phase A-E traceability pass with fresh proxmox/runtime validation and linked evidence.
