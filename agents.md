# DeployKube contributor context

DeployKube is a GitOps-first Kubernetes platform workspace.

## Core rules

- Treat repo code, manifests, scripts, and tests as the runtime source of truth.
- Bootstrap is intentionally narrow: Stage 0 and Stage 1 only prepare the cluster and seed the GitOps control plane.
- Steady-state platform changes belong under `platform/gitops/**` and should converge through Argo CD.
- Keep docs aligned with code. If a public-facing doc drifts from implementation, update it with the change.
- Preserve the KRM-native direction: prefer platform APIs and controllers over ad hoc render scripts.

## Start here

- `README.md`
- `docs/design/architecture-overview.md`
- `docs/design/gitops-operating-model.md`
- `scripts/README.md`
- `target-stack.md`

## Useful repo areas

- `bootstrap/` host/bootstrap inputs
- `shared/scripts/` Stage 0 and Stage 1 implementations
- `platform/gitops/apps/` Argo CD applications and environment bundles
- `platform/gitops/components/` platform components and smoke tests
- `platform/gitops/deployments/` deployment config contracts and bootstrap secret bundles
- `tools/tenant-provisioner/` platform API types and controllers
- `docs/design/`, `docs/guides/`, `docs/runbooks/`, `docs/toils/` supporting docs

## Public mirror note

This repository may be published as a sanitized public mirror.

- Keep architecture, contracts, controller code, and representative platform components reviewable.
- Remove or replace internal domains, IPs, credentials, custody details, and sensitive operational evidence.
- Follow `docs/guides/public-mirror-preparation.md` when preparing public copies.
