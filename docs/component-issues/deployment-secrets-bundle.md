# deployment-secrets-bundle design issues

Canonical issue tracker for the Deployment Secrets Bundle (DSB) design.

Design:
- `docs/design/deployment-secrets-bundle.md`

---

## Open

### Component Assessment Findings (Automated)

<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
- (none)
<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->

## Component Assessment Findings (v1)

Canonical, automatable issue list for this component (single tracker file).
Schema: `docs/component-issues/SCHEMA.md`

<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
```jsonl
```
<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

## Resolved

- **DSB app present:** `deployment-secrets-bundle` exists as a GitOps-managed Argo app and is validated via `./tests/scripts/validate-deployment-secrets-bundle.sh`.
- **Per-deployment bundle layout present:** `platform/gitops/deployments/<deploymentId>/.sops.yaml` and `platform/gitops/deployments/<deploymentId>/secrets/*.secret.sops.yaml` exist for the current deployments (dev + prod).
- **DSB restore story documented:** `docs/runbooks/dsb-restore-story.md`.
- **Drift / hygiene checks enforced in CI:** `./tests/scripts/validate-deployment-secrets-bundle.sh` fails on stale/missing required DSB secrets.
