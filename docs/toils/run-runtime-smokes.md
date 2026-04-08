# Run runtime smoke jobs (cluster-wide or per component)

DeployKube ships many *runtime* validation checks as Kubernetes `CronJob`s ("smoke-tests") and Argo CD hook `Job`s ("sync-gates").

This toil provides a single command to re-trigger them on demand when validating a big platform change.

---

## What this does (and does not do)

- **Does**: creates `Job`s from existing smoke `CronJob`s (so you get an immediate run) and optionally triggers Argo `Application` syncs to rerun hook `Job`s.
- **Does not**: replace repo-local structural linting (`./tests/scripts/ci.sh`); runtime smokes require a live cluster and are intentionally not run in GitHub Actions.

---

## Recommended workflow

### Component change (default expectation)

Rerun only the affected component’s smokes:

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/run-runtime-smokes.sh \
  --app networking-istio-namespaces \
  --hooks --cronjobs --wait
```

This keeps the blast radius small: only hook jobs for that component are re-run (via Argo sync), and only smoke `CronJob`s owned by that component are triggered.

### Big cross-cutting change

Rerun *all* smoke `CronJob`s (and optionally all hook smokes):

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/run-runtime-smokes.sh \
  --all --cronjobs --wait
```

If you also want to re-run hook jobs for all apps:

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/run-runtime-smokes.sh \
  --all --hooks --cronjobs --wait
```

---

## Notes / gotchas

- **Prod bootstrap-tools image overrides**: prod clusters may rewrite `bootstrap-tools` images via Argo Application `spec.source.kustomize.images`. This script avoids “wrong image” pitfalls by:
  - triggering `CronJob` runs from the **cluster CronJob** (jobTemplate already uses the overridden image), and
  - triggering hook jobs via **Argo sync** (so Argo applies its configured image overrides).

- **Hook job cleanup**: many hook jobs use `argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation`. When a hook succeeds, the `Job` object may be deleted automatically; treat Argo `operationState.phase=Succeeded` as the success signal.

