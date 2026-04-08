# Toil: Keycloak IAM mode matrix E2E

Run end-to-end IAM mode validation against a live cluster by mutating the singleton `DeploymentConfig.spec.iam`, triggering existing IAM CronJobs, asserting status outputs, and restoring the original IAM config.

Script:
- `tests/scripts/e2e-iam-modes-matrix.sh`

## Safety contract

- This workflow mutates live runtime config.
- Explicit acknowledgement is mandatory:
  - `--ack-config-mutation yes`, or
  - `DK_IAM_E2E_ACK_CONFIG_MUTATION=yes`.
- The script always restores original `spec.iam` on exit.
- By default it keeps `argocd/deployment-config-controller` running (`freeze=no`) so deployment-config snapshots continue propagating to IAM jobs.
- Optional advanced mode can still freeze that controller, but only use it when IAM jobs are configured to read DeploymentConfig directly.
- By default it also temporarily disables Argo auto-sync on both `argocd/platform-apps` and `argocd/deployment-secrets-bundle` so GitOps does not revert temporary mode patches mid-run.

## Profiles

- `quick`:
  - Hybrid-mode happy-path sanity for fast PR signal.
  - Asserts `keycloak-iam-sync` reaches `state=applied`.
- `full`:
  - Validates standalone/downstream/hybrid behavior.
  - Validates hybrid fail-open + failback transition.
  - Validates LDAP `operationMode=sync` path.
  - Optionally runs `keycloak-upstream-sim-smoke`.

## Prerequisites

- Cluster has exactly one `DeploymentConfig` (`deploymentconfigs.platform.darksite.cloud`).
- IAM CronJobs exist in `keycloak` namespace:
  - `keycloak-iam-sync`
  - `keycloak-ldap-sync`
- Optional: upstream simulator CronJob exists in `keycloak-upstream-sim`:
  - `keycloak-upstream-sim-smoke`

## Local examples

Quick profile:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_IAM_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-iam-modes-matrix.sh \
  --profile quick \
  --ack-config-mutation yes
```

Full profile:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
DK_IAM_E2E_ACK_CONFIG_MUTATION=yes \./tests/scripts/e2e-iam-modes-matrix.sh \
  --profile full \
  --run-upstream-sim auto \
  --ack-config-mutation yes
```

## Environment knobs

Optional environment variables:

- `DK_IAM_E2E_OIDC_ISSUER_URL`
- `DK_IAM_E2E_HEALTHCHECK_URL`
- `DK_IAM_E2E_FAILOPEN_TEST_URL`
- `DK_IAM_E2E_LDAP_URL`
- `DK_IAM_E2E_RUN_UPSTREAM_SIM` (`auto|yes|no`)
- `DK_IAM_E2E_FREEZE_DEPLOYMENT_CONFIG_CONTROLLER` (`yes|no`)
- `DK_IAM_E2E_FREEZE_GITOPS_SYNC` (`yes|no`)

Defaults are intentionally chosen so tests can run without additional secrets in most clusters.

## CI split

- PR (`quick`) and nightly/manual (`full`) are wired in:
  - `.github/workflows/keycloak-iam-mode-e2e.yml`
- Runtime continuous assurance remains in-cluster via existing CronJobs and alerting.
