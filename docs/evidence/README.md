# Evidence notes (DeployKube)

This folder holds dated evidence logs for changes and troubleshooting.

## Format (v1)

New evidence notes should use **EvidenceFormat: v1** and include:

- `Date` (YYYY-MM-DD)
- `Environment` (`mac-orbstack`, `mac-orbstack-single`, `proxmox-talos`, `staging`, or `repo-only`)
- `Scope / ground truth` (what the note is validated against)
- `Git` (commit SHA; optionally repo/branch if relevant)
- `Argo` (root app status + revision), or explicitly `N/A` when scope is repo-only
- `What changed`
- `Commands / outputs` (copy/pasteable commands and short output excerpts)

Use the template:

- `docs/templates/evidence-note-template.md`
