# Validation Jobs Doctrine (Jobs, CronJobs, Argo Hooks)

This document defines **uniform doctrine + quality gates** for all DeployKube validation jobs (smoke tests, periodic checks, and Argo sync verification).

The goal is to make validation **repeatable**, **actionable**, and **GitOps-native** across all components.

## Tracking

- Canonical tracker: `docs/component-issues/validation-jobs.md`

## Scope / definitions

- **Validation job**: Kubernetes `Job` or `CronJob` that asserts a real platform capability (not just “pod is running”).
- **Smoke test**: a minimal functional validation proving the component/stack works end-to-end.
- **Actionable**: runs regularly (when applicable) and produces an alertable failure signal (CronJob failures + staleness).

## Where validation jobs live (repo layout)

- **Component-local** (preferred): `platform/gitops/components/<area>/<component>/{tests,smoke-tests}/`
  - Use `tests/` for manual/on-demand `Job` bundles.
  - Use `smoke-tests/` for scheduled `CronJob` bundles.
  - `smoke/` is allowed as a legacy alias, but prefer `smoke-tests/` for consistency and CI coverage.
- **Cross-cutting stacks** (allowed): a dedicated component (e.g. `components/certificates/smoke-tests/`) when the test spans multiple components.

Every validation bundle must be Kustomize-managed (`kustomization.yaml`) and owned by an Argo CD `Application`.

## Execution modes (pick the right primitive)

1. **Manual Job bundle (developer loop)**
   - A Kustomize directory with one or more `Job`s.
   - Used for fast iteration and evidence capture.

2. **Argo CD Hook Job (sync-gate)**
   - Used only when the platform must not proceed unless the check passes.
   - Prefer `PostSync` for “verify after reconcile”.
   - Keep hook Jobs short and deterministic (avoid flaky network probes).

3. **Scheduled CronJob (continuous assurance)**
   - Required when a check is intended as ongoing assurance (prod at minimum).
   - Dev overlays may run more frequently for faster feedback.

## CI split vs in-cluster assurance (required)

Use both paths, with clear intent:

1. **In-cluster continuous assurance (CronJobs)**
   - Proves runtime behavior continuously against real dependencies.
   - Feeds alerting/staleness checks.
   - Should remain the canonical long-running health signal.

2. **Pre-merge CI checks (static/structural)**
   - Fast and deterministic checks that do not require mutating a live cluster.
   - Examples: render/lint/syntax/contract validation.
   - Must run on normal PR CI for broad contributor feedback.

3. **Runtime CI orchestrators (targeted E2E)**
   - Use a dedicated workflow when mode/config permutations are too broad for a single in-cluster smoke.
   - Typical split:
     - PR quick profile: minimal high-signal scenario.
     - Nightly/manual full profile: broader matrix coverage.
   - Must run on dedicated self-hosted runners/clusters and be explicitly gated by repo vars/secrets.
   - If a workflow mutates runtime config, require explicit safety acknowledgement and automatic rollback in script logic.

## Quality gates (must-have)

## Validation utility images (required posture)

Validation jobs must use capability-scoped utility images.

Do not default to either extreme:
- one giant shared tools image for every validation job, or
- one bespoke image per smoke job.

Preferred pattern:
- keep a small set of narrow utility images grouped by capability surface,
- migrate low-surface jobs first,
- only use broader images when the job actually needs that broader dependency set.

Current baseline:
- `validation-tools-core` is the narrow image for low-surface validation jobs that only need Kubernetes/TLS/HTTP tooling (`kubectl`, `bash`, `curl`, `jq`, `openssl`).
- Jobs that need database, backup, or IdP tooling should stay on or move to a different capability-scoped image instead of extending `validation-tools-core`.
- If adding a new tool would pull in a large runtime surface (for example Java/Keycloak tooling), prefer a separate image over inflating the core validation image.

### Runtime safety

For every `Job`:
- `spec.backoffLimit` set (prefer `0` or `1`).
- `spec.activeDeadlineSeconds` set (hard stop; default target: `300–900` seconds).
- `spec.ttlSecondsAfterFinished` set (cleanup).
- Pod `restartPolicy: Never`.

For every `CronJob`:
- `spec.concurrencyPolicy: Forbid`.
- `spec.startingDeadlineSeconds` set.
- `spec.successfulJobsHistoryLimit` and `spec.failedJobsHistoryLimit` set.
- `spec.jobTemplate.spec.backoffLimit`, `activeDeadlineSeconds`, and `ttlSecondsAfterFinished` set.
- `spec.jobTemplate.spec.template.spec.restartPolicy: Never`.

### Determinism and repeatability

- The job must be **idempotent**:
  - either creates uniquely named resources per run (timestamp/run id), or
  - cleans up any previous artifacts before creating new ones.
- If the test writes data (e.g., pushes a log/metric), it must use a unique run identifier and clean up where possible.

### Functional assertions

- Assert real functionality (e.g., “issued cert chains to root and matches hostname”), not only readiness.
- Validate the important boundary:
  - controller reconciles resources,
  - data plane consumes them (if applicable),
  - the intended client path works (DNS/TLS/HTTP semantics, etc.).

### Diagnostics on failure

On failure, print **enough context to debug** without re-running interactively:
- `kubectl describe` for the primary resource(s) under test,
- recent events in the relevant namespace,
- any key dependent resources (e.g., CertificateRequests, Pods, Gateways).

Avoid brittle shell patterns:
- Use `set -euo pipefail`.
- Avoid `echo "$list" | while read...` when you need variables to persist; prefer heredocs (`while read... <<EOF`) or arrays.

### Mesh / sidecar behavior

- Default: disable injection for validation pods (`sidecar.istio.io/inject: "false"`) unless the test explicitly validates mesh behavior.
- If a Job must run in an Istio-injected namespace and should be injected:
  - use native sidecars (`sidecar.istio.io/nativeSidecar: "true"`) and
  - mount and trap `istio-native-exit.sh` from `platform/gitops/components/shared/bootstrap-scripts/istio-native-exit`.
  - ensure the helper `ConfigMap` (`istio-native-exit-script`) is owned by exactly one Argo CD `Application` per namespace to avoid SharedResourceWarnings and OutOfSync flapping.

### Security and RBAC

- Use a dedicated `ServiceAccount` per validation bundle.
- Grant least privilege:
  - namespaced `Role` for namespaced operations,
  - `ClusterRole` only when truly needed (e.g., read `ClusterIssuer`, read cross-namespace `Secret`).
- Never log secrets:
  - avoid `set -x`,
  - don’t print full cert/key material,
  - redact tokens/passwords.

## “Actionable” enforcement (required behavior)

If a smoke check is intended as ongoing assurance:
- Implement it as a `CronJob` in prod.
- Ensure failure is observable via Kubernetes Job status:
  - failed runs increment `.status.failed`,
  - last schedule time is visible (`kubectl get cronjob`).

### Alerting / staleness standard (standard mechanisms)

DeployKube uses the platform observability stack for alerting: **Mimir Ruler → Alertmanager** with Prometheus-style rule files.

Baseline expectation for ongoing assurance CronJobs:
- **Staleness alert**: alert when a CronJob has not produced a successful run within the expected freshness window.
  - Use kube-state-metrics `kube_cronjob_status_last_successful_time` (seconds since epoch).
  - Example pattern:
    - `(time - kube_cronjob_status_last_successful_time{namespace="<ns>", cronjob="<name>"}) > <max_age_seconds>`
- **Failure alert**: alert when the underlying Jobs are failing.
  - A generic `kube_job_status_failed > 0` style rule is acceptable initially, but prefer scoping to the specific smoke CronJob/Jobs to avoid noise.

Dev vs prod guidance:
- **Dev**: warn-only (or suppress) staleness/failure alerts unless you are explicitly validating alert routing.
- **Prod**: treat staleness/failure as actionable (severity should be at least `warning`, often `critical` depending on the capability).

Receiver endpoints are not required to exist to ship the rules:
- If Alertmanager has no active notification endpoints yet, rules still provide in-cluster visibility and can be routed to a null receiver until endpoints are configured.

Manual-only validation is acceptable only when explicitly documented as manual (and tracked as a follow-up if ongoing assurance is required).

## Review checklist (PR gate)

Every PR that adds/changes validation jobs must include:
- Updated component README “Smoke Jobs / Test Coverage” section documenting:
  - what is proven,
  - how to run manually (create Job from CronJob if applicable),
  - where it runs (namespace) and key dependencies.
- Updated `docs/component-issues/<component>.md` (open/resolved items).
- Evidence file under `docs/evidence/YYYY-MM-DD-*.md` showing:
  - Argo app `Synced/Healthy`,
  - the smoke execution command(s),
  - a short success/failure output excerpt.

## Local enforcement (lint)

Run the repo lint helper before merging:

```bash./tests/scripts/validate-validation-jobs.sh
```

This performs repo-local structural checks (kustomize render + required fields) for directories named `tests/` or `smoke-tests/` under `platform/gitops/components/`.

## CI enforcement (pre-merge)

This repo runs the same lint in GitHub Actions on every PR:

- Workflow: `.github/workflows/validation-jobs.yml`
- Check: `./tests/scripts/validate-validation-jobs.sh`

CI enforces **structural** quality gates (renderability + required safety fields). It does not prove runtime correctness.

## Local testing (without applying to a live cluster)

For a validation bundle directory:

- Render manifests: `kubectl kustomize <dir>`
- Run lint (recommended): `./tests/scripts/validate-validation-jobs.sh`

If you want additional (optional) client-side validation without a cluster:

- `kubectl kustomize <dir> | kubectl apply --dry-run=client -f - --validate=false`

Note: `--validate=false` is required for CRDs that aren’t in the local OpenAPI schema (common for cert-manager, Gateway API, etc.).

## Integration testing (dev cluster, GitOps-first)

Runtime validation happens in dev first (not in CI), then gets promoted to prod:

1. Implement the validation job(s) under `platform/gitops/components/**`.
2. Commit (Forgejo seeding snapshots `HEAD` only).
3. Seed dev Forgejo + sync Argo.
4. Run the job(s) and capture evidence under `docs/evidence/YYYY-MM-DD-*.md`.
5. Promote by seeding/syncing the same commit to prod and validating the prod schedule/behavior.

This keeps “pre-merge correctness” (static) separate from “post-sync correctness” (runtime).

Convenience helper:
- To re-trigger smoke runs on demand (cluster-wide or per Argo Application), use:
  - `./tests/scripts/run-runtime-smokes.sh` (toil doc: `docs/toils/run-runtime-smokes.md`).

## Implementation prompt (copy/paste)

Use this prompt when adding/changing validation jobs:

```text
Please implement validation jobs for component path: <COMPONENT_PATH>.

Goals:
- Add Kustomize-managed Job/CronJob smoke checks that prove real functionality (not just readiness).
- If a smoke check is intended as ongoing assurance, implement it as a CronJob in prod (and document schedule differences via overlays).
- Follow the repo doctrine in docs/design/validation-jobs-doctrine.md (safety fields, determinism, diagnostics, RBAC least privilege, Istio job behavior).

Repo requirements:
- The validation bundle must have a kustomization.yaml and be owned by an Argo CD Application.
- Update the component README Smoke Jobs / Test Coverage section with: what it proves, dependencies, how to run manually (create Job from CronJob if applicable).
- Add/update docs/component-issues/<component>.md for any missing capabilities.
- Add an evidence file under docs/evidence/YYYY-MM-DD-*.md with Argo status + smoke output.
- Update `agents.md` if the validation-job workflow changes agent-facing repo rules.

Validation:
- Run./tests/scripts/validate-validation-jobs.sh and fix any failures.
```
