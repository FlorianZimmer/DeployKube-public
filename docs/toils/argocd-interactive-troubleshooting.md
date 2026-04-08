# Toil: Interactive troubleshooting loop (Argo CD + Forgejo mirror)

Goal: troubleshoot against the live cluster without fighting Argo self-heal, but ship the real fix via GitOps.

Related:
- GitOps workflow: `docs/design/gitops-operating-model.md`
- Access-plane guardrails: `docs/design/cluster-access-contract.md`
- Forgejo seeding: `docs/toils/forgejo-seeding.md`

## Loop

1) Pause auto-sync for the affected Argo app (prevents self-heal from reverting experiments):

```bash
# Proxmox/Talos:
export KUBECONFIG=tmp/kubeconfig-prod
# OrbStack dev:
# kubectl config use-context kind-deploykube-dev

APP=<application-name>  # list with: kubectl -n argocd get applications

kubectl -n argocd patch application "${APP}" \
  --type='json' \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

2) Troubleshoot interactively (read-first; apply temporary changes only if needed):

```bash
kubectl -n <ns> get pods -o wide
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> -c <container> --previous --tail=200
```

3) Implement the actual fix in Git (`platform/gitops/**`), update component README + `docs/component-issues/<component>.md`, and commit.

4) Push the GitOps subtree snapshot to Forgejo (Argo reads Forgejo, not GitHub):

```bash
# The seed script snapshots platform/gitops from the root repo HEAD.
# It may skip if tmp/bootstrap/forgejo-repo-seeded* exists unless forced.
FORGEJO_FORCE_SEED=true./shared/scripts/forgejo-seed-repo.sh
```

5) Force Argo to reconcile (kubectl-only fallback when the `argocd` CLI/context is broken):

```bash
kubectl -n argocd annotate application "${APP}" argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application "${APP}" --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

Notes for PostSync smokes/hooks:
- Some apps use `ApplyOutOfSyncOnly=true`, and Argo hook Jobs only re-run when a new sync operation happens.
- For GitOps-driven re-runs, bump the component’s `*-smoke-trigger` ConfigMap `data.runId` (under the component’s `tests/` or `smoke-tests/` bundle), commit, seed Forgejo (prod), then refresh/sync.

If an automated sync gets “stuck” on an old revision:
- Clear the current operation so Argo can start a fresh one against the latest repo state:

```bash
kubectl -n argocd patch application "${APP}" --type=merge -p '{"operation":null}'
```

If prune/deletions get stuck:
- Many apps default to `PrunePropagationPolicy=foreground`, which can leave resources stuck in deletion with `metadata.finalizers: ["foregroundDeletion"]`.
- Treat manual finalizer removal as **breakglass** (ship evidence + the real GitOps fix). Example pattern:

```bash
kubectl -n <ns> patch <kind> <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

If you see `field is immutable` errors for `Job` resources:
- Argo cannot update an existing `Job.spec.template` (immutable). Prefer modeling these as Argo hooks with `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded` so Argo deletes/recreates them cleanly.
- Breakglass unblocker (only if needed): delete the stuck Job so Argo can recreate it on the next sync:

```bash
kubectl -n <ns> delete job <job-name> --ignore-not-found=true
```

6) Re-enable auto-sync (important: pausing was a live patch, not a GitOps change):

```bash
kubectl -n argocd patch application "${APP}" --type merge -p \
  '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

7) Validate GitOps reconciliation and runtime health:

```bash
kubectl -n argocd get application "${APP}" \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}{"\n"}'
kubectl -n <ns> get pods -o wide
```

## Notes

- Prefer GitOps-first debugging (`kubectl kustomize... | kubectl diff/apply`) with auto-sync paused; use live edits only to confirm hypotheses.
- Admission guardrails intentionally deny manual changes to access-critical resource types (RBAC objects, CRDs, admission policies/bindings, webhook configurations). Pausing auto-sync does not bypass this: ship those changes via GitOps, or use breakglass with evidence. See `docs/design/cluster-access-contract.md`.
- If you need to pause the whole platform, pause `platform-apps` (heavy-handed; do this only intentionally).
