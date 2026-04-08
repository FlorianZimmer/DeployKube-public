# Runbooks

Runbooks are **incident/alert response** docs: fast triage + remediation steps intended for use under time pressure.

Rules:
- If a Prometheus/Mimir alert sets `runbook_url: docs/runbooks/<...>.md`, that file must exist here.
- Prefer component-local runbooks inside `platform/gitops/components/**/**/README.md` when the runbook is tightly coupled to one component.
- Keep runbooks short: **symptoms → checks → remediation → rollback/evidence**. Link out to deeper guides/toils instead of duplicating them.

