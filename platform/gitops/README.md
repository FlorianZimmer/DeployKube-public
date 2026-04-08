# DeployKube GitOps Workspace

This directory holds the Argo CD app-of-apps definition and component overlays. It is committed alongside the rest of the DeployKube workspace and mirrored into Forgejo during the Stage 1 bootstrap.
It is intentionally **not** a separate git repository; the canonical remote is the top-level DeployKube GitHub repo. Forgejo is seeded from a snapshot of this directory via `shared/scripts/forgejo-seed-repo.sh`.

## Important: Git structure (no nested repo)

- `platform/gitops` is part of the top-level DeployKube git repository.
- Do **not** run `git init` inside `platform/gitops`.
- `platform/gitops/.git` must **not** exist. A nested repo causes confusing “committed but not pushed” states and can result in GitHub pushes that do not include the GitOps content.

If you suspect a nested repo exists:

```bash
test -d platform/gitops/.git && echo "nested repo detected"
```

Fix (safe):

```bash
tar -czf tmp/platform-gitops-dotgit-backup.tgz platform/gitops/.git
rm -rf platform/gitops/.git
```

## Structure

```
apps/
  base/                 # shared Argo Application definitions (app-of-apps)
  environments/
    mac-orbstack-single/ # environment-specific Application bundle (dev)
    proxmox-talos/       # environment-specific Application bundle (prod)
tenants/                # platform-owned tenant intent (folders + metadata.yaml)
components/
  networking/           # Kustomize bundles rendered by the Applications
  secrets/              # Vault, transit, ESO, bootstrap jobs
  certificates/         # Step CA, cert-manager, issuers, bootstrap jobs
  storage/              # "
clusters/
  management/           # Argo Projects / ApplicationSets for the mgmt cluster
```

Additional environments (proxmox, baremetal) will gain their own folders as we port the pattern.

## Current status
- Stage 1 bootstrap snapshots this content into the Forgejo repo and applies the root Application.
- The snapshot is taken from the **DeployKube git `HEAD`** (not your working tree). Commit before seeding.
- This subtree is the desired-state source of truth for Argo CD once Stage 1 hands off. See `docs/design/gitops-operating-model.md` in the parent repo for the end-to-end workflow.
