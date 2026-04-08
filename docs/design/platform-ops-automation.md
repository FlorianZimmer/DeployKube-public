# Platform Ops Automation Design

Status: Design + implementation

## Tracking

- Canonical tracker: `docs/component-issues/platform-ops.md`
- Related docs:
  - `docs/design/workload-rightsizing-vpa.md`
  - `docs/design/observability-lgtm-troubleshooting-alerting.md`
  - `docs/design/deployment-config-contract.md`

## Purpose

Define the scope and boundaries for platform-owned operational automation under `platform/gitops/components/platform/ops/`.

## Scope

In scope:
- Cert/runtime safety automations and operational guardrails.
- Cross-namespace automation RBAC posture and blast-radius expectations.
- Alerting and observability requirements for ops automation.

Out of scope:
- Component-specific SLOs owned by individual platform services.
- Tenant-facing day-2 automation productization.

## Automation model

1. Platform-owned jobs:
- Operational jobs run as GitOps-managed CronJobs/Jobs with explicit scope and retry behavior.

2. Declarative target model:
- Automation targets and thresholds are configuration-driven and environment-aware.

3. Safety posture:
- Automations should be idempotent, observable, and bounded in privilege.

## Security boundaries

- Prefer least privilege; avoid cluster-wide mutation grants unless required.
- Cross-namespace actions must be explicit and documented in tracker/evidence.
- Supply-chain hygiene (digest pinning where feasible) applies equally to ops automation images.

## Implementation map (repo)

- platform ops components: `platform/gitops/components/platform/ops/`
- cert monitor assets: `platform/gitops/components/platform/ops/istio-cert-monitor/`
- VPA tooling and recommendations: `platform/gitops/components/platform/ops/vpa-recommendations/`

## Invariants

- Automation actions that restart/patch workloads must be observable.
- Environment-specific targets must be driven by config, not hardcoded one-off values.
- Ops automation changes require evidence with rollback notes when they can affect availability.

## Validation and evidence

Primary signals:
- automation smoke jobs pass for each enabled automation.
- logs/metrics capture successful and failed action attempts.
- evidence notes include operational command traces and outcomes.
