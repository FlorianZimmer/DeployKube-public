# Toil: Forgejo GitOps seeding / force-push

DeployKube runs a “GitHub monorepo → Forgejo mirror” workflow: the cluster reads desired state from the Forgejo repo, seeded from this repo’s `platform/gitops/` tree.

Related:
- GitOps operating model: `docs/design/gitops-operating-model.md`
- Seed helper: `shared/scripts/forgejo-seed-repo.sh`

## Key properties (don’t skip)

- The seed snapshots **root git `HEAD`** (uncommitted working tree changes are ignored). Commit before seeding.
- Stage 1 bootstraps run a GitOps seed preflight guardrail (`shared/scripts/preflight-gitops-seed-guardrail.sh`) before seeding:
  - refuses to seed from a dirty git working tree, and
  - fails fast if DeploymentConfig-driven rendered outputs drift from committed files.
- `platform/gitops/` is **not** a standalone git repo. Do not create `platform/gitops/.git`.
- Stage 1 may skip reseeding if a sentinel exists:
  - dev: `tmp/bootstrap/forgejo-repo-seeded`
  - prod: `tmp/bootstrap/forgejo-repo-seeded-proxmox`
  - override: `FORGEJO_SEED_SENTINEL=...`
- Security: seeding can bypass PR approval controls in a “GitHub → Forgejo mirror” setup; treat it as a privileged deployment action (prefer CI-only execution after merge, with evidence/audit).

## Normal reseed (recommended)

```sh
FORGEJO_FORCE_SEED=true./shared/scripts/forgejo-seed-repo.sh
```

For Proxmox/prod-like reseeds, set the kubeconfig explicitly instead of relying on the current kubectl context:

```sh
KUBECONFIG=tmp/kubeconfig-prod \
FORGEJO_FORCE_SEED=true \./shared/scripts/forgejo-seed-repo.sh
```

If the script cannot read `Secret/forgejo-admin`, check the active context first; the helper reads bootstrap credentials from the target cluster before it can push the mirror.

## Argo CD AppProject migration gotcha (existing clusters)

`AppProject/default` is deny-by-default. If your cluster was bootstrapped before the `platform` project migration and the root app is still in `spec.project: default`, Argo will reject it once `default` is locked down.

Fix (kubectl-only; before/after seeding):

```sh
kubectl -n argocd apply -f platform/gitops/apps/base/appproject-platform.yaml
kubectl -n argocd patch application platform-apps --type merge -p '{"spec":{"project":"platform"}}'
kubectl -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite
```

Evidence (prod rollout):.

## Force-push via port-forward (when remote URL points to in-cluster Forgejo)

```sh./shared/scripts/forgejo-seed-repo.sh --force
```

## Remote check/repair

```sh./shared/scripts/forgejo-switch-gitops-remote.sh \
  --gitops-path platform/gitops \
  --host forgejo.<env>.internal.example.com
```

Notes:
- In monorepo mode the remote helper only verifies the HTTPS endpoint; it does not rewrite remotes.
