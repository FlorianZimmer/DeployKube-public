# validation-jobs doctrine issues

Canonical issue tracker for the validation jobs doctrine.

Design:
- `docs/design/validation-jobs-doctrine.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
### Medium

#### vulnerabilities
- Validation jobs still over-share the broad `bootstrap-tools` image. `validation-tools-core` now covers the low-surface certificate validation path, but other smoke/hook jobs still need migration to capability-scoped images so unrelated dependency CVEs do not keep leaking across components. (ids: `dk.ca.finding.v1:validation-jobs:f42be8426958b7104fbcd5dce99054a7da895a58ca8f683ddce3ae6331f30a4f`)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
{"class": "actionable", "details": "- The broad `bootstrap-tools` image bundles unrelated Java/Keycloak, backup, and database tooling, so low-surface validation jobs inherit avoidable vulnerability churn.\n- The doctrine now requires capability-scoped validation utility images instead of either one giant shared image or one image per job.\n- `validation-tools-core` is the first narrow image and now covers the certificate smoke path, but other jobs still need migration.", "evidence": [{"key": "Doctrine now defines capability-scoped validation utility images", "path": "docs/design/validation-jobs-doctrine.md", "resource": "Design doc"}, {"key": "Broad bootstrap-tools image carries unrelated toolchains", "path": "shared/images/bootstrap-tools/Dockerfile", "resource": "Dockerfile"}, {"key": "First narrow validation image exists", "path": "shared/images/validation-tools-core/Dockerfile", "resource": "Dockerfile"}, {"key": "Certificate smoke jobs now consume validation-tools-core", "path": "platform/gitops/components/certificates/smoke-tests/README.md", "resource": "README"}], "first_seen_at": "2026-03-09", "id": "dk.ca.finding.v1:validation-jobs:f42be8426958b7104fbcd5dce99054a7da895a58ca8f683ddce3ae6331f30a4f", "last_seen_at": "2026-03-09", "recommendation": "Keep `validation-tools-core` narrow, migrate other low-surface validation jobs to capability-scoped images, and reserve broader images for jobs that actually require their larger tool surface.", "risk": "Unrelated CVEs in a broad shared tools image will continue to block or distract component-level validation reviews until the remaining validation jobs stop inheriting that surface area.", "severity": "medium", "status": "open", "template_id": "security-03-vulnerabilities.md", "title": "Validation jobs still over-share a broad utility image and need capability-scoped image migration", "topic": "vulnerabilities", "track_in": "docs/component-issues/validation-jobs.md"}
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **Capability-scoped validation image baseline established (2026-03-09):** the doctrine now requires narrow utility images by capability class, `shared/images/validation-tools-core/` was added for low-surface Kubernetes/TLS/HTTP validation jobs, and the certificate smoke path now consumes it instead of the broader `bootstrap-tools` image.
- **DNS delegation mode matrix hang fixed (2026-03-08):** `tests/scripts/e2e-dns-delegation-modes-matrix.sh` now captures controller logs before matching the expected marker. The previous `kubectl logs... | grep -q` form ran under `set -o pipefail`, so `grep` exiting after the first match could surface a SIGPIPE from `kubectl logs` and make the poller loop until timeout even though the controller already emitted the line.
- **Release runtime smoke suite + mode-matrix expansion (2026-02-24):** added curated release runtime smoke runner (`tests/scripts/e2e-release-runtime-smokes.sh`) and wired it into release gate/tag flow. Added dedicated runtime mode-matrix runners/workflows for DNS delegation and root-of-trust (`tests/scripts/e2e-dns-delegation-modes-matrix.sh`, `tests/scripts/e2e-root-of-trust-modes-matrix.sh`, plus corresponding workflows). Full release profile keeps backup checks non-destructive by default and treats restore canary as explicit opt-in. DNS auto mode now supports ephemeral in-cluster writer simulation with rrset-level assertions; root-of-trust external mode now supports ephemeral in-cluster KMS endpoint simulation plus Vault restart/unseal verification.
- **CI vs continuous assurance split clarified (2026-02-23):** doctrine now explicitly requires intentional split between in-cluster CronJob assurance, fast pre-merge structural CI checks, and optional gated runtime CI orchestrators (`quick` PR profile + `full` nightly/manual profile) when matrix coverage is needed.
- **CI doctrine check exists:** `./tests/scripts/validate-validation-jobs.sh` enforces baseline doctrine requirements for Jobs/CronJobs in-repo.
- **Doctrines-to-CI coverage:** `./tests/scripts/validate-validation-jobs.sh` scans all Kustomize validation bundles under `platform/gitops/components/**/{tests,smoke-tests,smoke}/` and fails when required safety fields are missing. (Resolved: 2026-01-05)
- **Staleness/alerting standard:** baseline staleness/failure alerting expectations are defined in `docs/design/validation-jobs-doctrine.md` (Mimir Ruler → Alertmanager). Receiver endpoints may be null/unconfigured until operational endpoints exist. (Resolved: 2026-01-05)
