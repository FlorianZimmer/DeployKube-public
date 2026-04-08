# Keycloak Upstream Simulator

## Purpose

This component deploys a minimal in-cluster Keycloak instance that acts as a simulated external OIDC upstream for validating DeployKube Keycloak IAM downstream/hybrid behavior.

It is intended for validation and canary workflows, not production identity.

## What it deploys

- Namespace: `keycloak-upstream-sim`
- `Deployment/keycloak-upstream-sim` (`start-dev`, internal TLS certificate)
  - Uses in-cluster HTTP (`:8080`) for admin automation calls and HTTPS (`:8443`) for issuer/discovery checks
  - **Idle by default** (`replicas: 0`) to avoid steady-state resource usage
- `CronJob/keycloak-upstream-sim-smoke`
  - **Suspended by default**
  - On run: scales simulator up, reconciles upstream bootstrap state, executes smoke checks, and scales simulator back down
  - Verifies upstream discovery and token grant for the simulation user
  - Optionally enforces that DeploymentConfig is actively pointing to this simulator (`REQUIRE_DEPLOYMENTCONFIG_MATCH=true`)

## Resource profile (low-footprint)

- Upstream sim Keycloak pod (during smoke runs):
  - requests: `50m` CPU, `384Mi` memory
  - limits: `1` CPU, `1Gi` memory
- Smoke job:
  - requests: `10m` CPU, `32Mi` memory
  - limits: `100m` CPU, `128Mi` memory

## Secrets

Values come from Vault via ESO path `keycloak/upstream-sim`:

- `adminUsername`
- `adminPassword`
- `simUserUsername`
- `simUserPassword`

## Enablement

This app is disabled by default in the `platform-apps` chart and enabled per environment via `enabledApps`.

## Security and operational guidance

Running this smoke continuously at high frequency is not recommended.

Risks of continuous smoke:

1. Repeated credential use increases authentication noise and incident triage load.
2. Frequent token grants produce more sensitive auth event volume and larger audit surface.
3. A continuously active validation control loop can become an unintended dependency and attack target.

Recommended posture:

1. Keep `CronJob/keycloak-upstream-sim-smoke` suspended by default.
2. Run one-shot smoke on-demand (post-change, post-upgrade, or scheduled low-frequency windows).
3. If periodic automation is required, use a low cadence (for example every 6-24h), dedicated least-privileged simulation credentials, and keep alerting tuned for failed smoke only.
4. Smoke pods run with non-root runtime constraints and reduced capabilities, and egress is restricted to DNS and simulator service ports.
5. Kubernetes API access for smoke pods is explicitly granted through `CiliumNetworkPolicy` `toEntities: kube-apiserver` (ports `443`/`6443`) instead of broad internet egress.

## Suggested validation runbook

1. Ensure this app is healthy (`Deployment` should remain scaled to `0` while idle).
2. Run one-shot smoke job from CronJob template and verify success.
3. Confirm simulator scales back to `0` replicas after smoke completion.
4. For full downstream canary validation, temporarily point `DeploymentConfig.spec.iam.upstream.oidc.issuerUrl` to this simulator issuer and confirm hybrid/downstream behavior, then revert.
