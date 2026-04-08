# Proof Of Concepts Guide

This guide defines how DeployKube packages, documents, and operates proof-of-concept work without accidentally promoting it into the default product surface.

## When to use a PoC

Use a PoC when the goal is to validate:
- an architecture or protocol shape,
- an operational workflow,
- an upstream dependency or product fit question,
- or a migration idea that is not yet ready to become a supported platform contract.

Do not use a PoC as a shortcut around normal platform design. If the workload is intended to become a durable shared service, model it as a product surface early.

## Packaging rules

- Keep PoCs opt-in by default. Prefer a dedicated Argo app under `platform/gitops/apps/opt-in/`.
- Keep PoCs out of the default platform bundle unless there is an explicit promotion decision.
- Use a dedicated namespace and do not apply tenant labels unless the PoC truly satisfies the tenant baseline.
- Treat PoC state as disposable unless there is a written reason not to.

## Data-service rule

PoCs should still use platform-owned APIs where they exist.

For Postgres:
- use `data.darksite.cloud/v1alpha1 PostgresInstance`
- prefer a disposable class such as `PostgresClass/platform-poc-disposable` for lab-only state
- do not introduce new raw `postgresql.cnpg.io` manifests in PoC components

The disposable Postgres class is the standard way to express:
- no backup helpers
- `darksite.cloud/backup=skip`
- an explicit backup skip reason
- optional monitoring suppression
- reduced single-instance sizing for labs

## Docs and evidence

Every PoC should ship:
- a component README under `platform/gitops/components/proof-of-concepts/<name>/README.md`
- a PoC narrative doc under `docs/proof-of-concepts/`
- a tracker under `docs/component-issues/`
- evidence notes under `docs/evidence/`

Document explicitly:
- why the PoC exists
- what is intentionally out of scope
- what makes it disposable
- what would have to change before promotion

## Validation

PoCs still need validation, but the signal can be narrower than for product surfaces.

Recommended pattern:
- one opt-in Argo entrypoint
- one repeatable validation path
- clear teardown instructions
- evidence-backed live runs for meaningful claims

If a PoC affects a real shared control plane, validate it on the target cluster before considering the change complete.

## Promotion path

Promotion out of PoC status should be explicit.

Before promotion:
- remove plaintext/lab-only credentials
- replace disposable storage posture with a durable backup model
- align HA, observability, and security hardening with the target service tier
- move the surface into product-owned API and component docs
- update `target-stack.md` and the relevant design docs
