# design-docs-missing (design coverage tracker)

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### Medium

#### general
- None currently. (ids: `dk.ca.finding.v1:design-docs-missing:f4347b203b375462de1854adf6e22c0c01642a687cc21cf87f268ee17d00c3a9`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

Tracks **implemented components** (GitOps manifests under `platform/gitops/**`) that currently lack a dedicated design doc link (`docs/design/**`) from their canonical component issue tracker.

This is intentionally a “work through one-by-one” checklist so we can add missing design docs (or explicitly decide “README-only is sufficient”) and then link them from the relevant `docs/component-issues/<component>.md`.

Related:
- Design doc tracking contract: `docs/design/README.md`
- GitOps operating model: `docs/design/gitops-operating-model.md`

---

## Open (missing design coverage)

- None currently.

---

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- None currently.\n\n---", "first_seen_at": "2026-02-25", "id": "dk.ca.finding.v1:design-docs-missing:f4347b203b375462de1854adf6e22c0c01642a687cc21cf87f268ee17d00c3a9", "last_seen_at": "2026-02-25", "recommendation": "None currently.", "severity": "medium", "status": "open", "template_id": "legacy-component-issues.md", "title": "None currently.", "topic": "general"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- [x] **2026-02-18 – Queue #14 strict interpretation closure (dedicated docs where needed, low-overlap decisions):**
  - Added new dedicated design docs for true gaps:
    - Argo CD: `docs/design/argocd-control-plane.md`
    - Forgejo: `docs/design/forgejo-gitops-mirror.md`
    - PKI/certs stack (`cert-manager`, `step-ca`, `certificates-ingress`): `docs/design/certificates-and-pki-stack.md`
    - DNS stack (`coredns`, `powerdns`, `external-sync`): `docs/design/dns-authority-and-sync.md`
    - External Secrets Operator: `docs/design/external-secrets-operator.md`
    - Platform ops automation: `docs/design/platform-ops-automation.md`
  - Kept existing docs (no new dedicated doc needed) to avoid overlap:
    - `cilium`, `metallb`, `gateway-api`, `istio`, `hubble`, `kiali` are covered by `docs/design/multitenancy-networking.md` and related contracts.
    - `factorio` remains README/service-catalog scoped (no standalone design doc required at current complexity).
  -
- [x] **2026-02-18 – Queue #14 design coverage cleanup:** added explicit `docs/design/**` links in all previously listed component trackers:
  - GitOps control plane: `argocd.md`, `forgejo.md`
  - Networking/ingress/mesh: `cilium.md`, `metallb.md`, `gateway-api.md`, `istio.md`, `hubble.md`, `kiali.md`
  - TLS/PKI: `cert-manager.md`, `step-ca.md`, `certificates-ingress.md`
  - DNS: `coredns.md`, `powerdns.md`, `external-sync.md`
  - Secrets/crypto: `external-secrets.md`
  - Ops/workloads: `platform-ops.md`, `factorio.md`
  -
