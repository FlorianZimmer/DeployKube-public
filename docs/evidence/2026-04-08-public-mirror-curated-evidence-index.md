# 2026-04-08 public mirror evidence index

Environment: `repo-only`

Purpose: point to the sanitized subset of real evidence notes kept in the public mirror after removing the private operational archive.

Included notes:

- `docs/evidence/2026-01-29-tenant-provisioner-renderer-retirement-scaffold.md`
- `docs/evidence/2026-01-29-dns-wiring-controller-cutover.md`
- `docs/evidence/2026-01-29-platform-ingress-certificates-controller-cutover.md`
- `docs/evidence/2026-02-21-component-assessment-execution-framework.md`
- `docs/evidence/2026-03-08-component-assessment-validation-jobs-prompt.md`
- `docs/evidence/2026-03-11-trivy-ci-artifact-coverage-enforcement.md`
- `docs/evidence/2026-03-11-trivy-ci-repo-owned-image-catalog-enforcement.md`

Selection rules:

- keep genuine evidence notes from the private repo rather than mirror-only summaries
- prefer repo-only notes or notes that stay accurate after limited redaction
- preserve original filenames, dates, and evidence structure
- limit public edits to removing workstation paths, internal mirror addresses, custody records, recovery paths, and omitted mirror-only references

Omitted on purpose:

- deployment secret bundles
- custody acknowledgements
- breakglass runbooks and drills
- incident notes with raw runtime output
- local filesystem paths and workstation-specific context
