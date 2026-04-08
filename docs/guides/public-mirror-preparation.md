# Public Mirror Preparation

This guide defines how to turn the private DeployKube working repo into a sanitized public mirror that stays technically useful without exposing internal operational detail.

The goal is not to publish every private operator detail. The goal is to keep the architecture, GitOps model, platform APIs, and representative implementation work visible.

## Publishing goals

The public mirror should make these things obvious within a few minutes:

- what DeployKube is
- why the architecture is interesting
- which technologies are actually used
- where the platform-specific engineering lives
- what was intentionally removed from the public copy

## Keep vs remove

Keep:

- root `README.md`
- design docs that explain the operating model and architecture
- representative component READMEs
- platform API docs and controller code
- bootstrap structure and scripts where they are not sensitive
- validation scripts, CI contracts, and artifact governance logic

Remove or sanitize:

- internal base domains
- internal IP addresses and hostnames
- breakglass credentials, custody acknowledgements, and recovery details that reveal environment specifics
- SOPS ciphertext bundles if they still reveal deployment identities or sensitive metadata
- evidence logs that contain live URLs, account names, network details, or operational timestamps that should stay private
- screenshots containing internal domains, dashboards, usernames, or alerts

## Sanitization checklist

### 1. Secrets and credentials

- Verify no plaintext secrets are tracked.
- Re-check encrypted files for revealing metadata or comments.
- Remove private seed material, local kubeconfigs, and custody artifacts from the public branch.

### 2. Identity and network details

- Replace real domains with reserved examples such as `example.internal`.
- Replace private IPs with documentation-safe examples where possible.
- Remove personal or organization-specific usernames that are not needed for understanding the design.

### 3. Evidence and runbooks

- Keep evidence only when it demonstrates engineering quality and is safe to share.
- Prefer sanitized excerpts over raw operational output dumps.
- Remove breakglass and incident-response details that would materially improve an attacker's understanding more than the public artifact needs.

### 4. Public repo entry path

- Ensure the root `README.md` points to the architecture overview, GitOps model, target stack, and representative components.
- Keep at least one architecture diagram in Markdown so GitHub renders it directly.
- Include a short "start here" path for someone who has never seen the repo before.

### 5. Scope statement

- State clearly that the public repo is a sanitized mirror.
- Explain that some deployment-specific material was intentionally removed.
- Name the areas that remain accurate and representative: GitOps structure, controller code, platform APIs, component layout, and validation discipline.

## Recommended public mirror extras

These are optional but high value:

- a small set of sanitized screenshots
- one short demo GIF of bootstrap or Argo reconciliation
- a concise architecture diagram
- a short "highlights" section in the root README
- a small list of representative files

## Minimal publication workflow

1. Create a dedicated public-mirror branch or separate mirror repo.
2. Apply sanitization commits there rather than weakening the private working repo.
3. Review the diff specifically for domains, IPs, identities, and evidence logs.
4. Re-read the root `README.md` as if you had never seen the repo before.
5. Publish only when the repo is understandable without private context.

## What the public repo should still show

After sanitization, the public repo should still make these things obvious:

- the bootstrap boundary
- the GitOps layout
- the platform stack
- the controller-driven parts of the design
- the quality bar around docs, validation, and operations
