# Platform Upgrade & Version Management Strategy

Keeping DeployKube reproducible and secure means treating every component upgrade like a production change. This note captures the process and tooling we rely on to stay current across Cilium, cert-manager, Vault, Forgejo, and any add-on that ships as a Kubernetes workload.

## Inventory: Know What’s Running
- Version all images, charts, and manifests in Git—no `:latest` tags.
- Generate periodic inventories (`kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}'`) and commit snapshots when they change so Renovate/CI has a baseline.
- Record component versions in their README files (e.g., component README under `platform/gitops/components/<category>/<component>/`) to make drift obvious during reviews.

## Detection: Automate Update Signals
- Enable Renovate (preferred) or Dependabot against this repo with rules for Helm charts, container images, and Go modules. Renovate should raise merge requests for new tags in `values*.yaml` and raw manifests.
- For components Flux/Argo manage, consider their native image-update controllers (`flux get image update` / Argo Image Updater) when we move to GitOps automation.
- Subscribe to upstream RSS/security feeds for critical dependencies (Kubernetes, Cilium, Vault, cert-manager) so we hear about CVEs or breaking changes early.

## Validation: Bootstrap Every Change
- Each Renovate MR must run `shared/scripts/bootstrap-mac-orbstack.sh` (or the relevant environment bootstrap) in CI.
- Smoke tests are mandatory: RWX storage probe, PowerDNS/ExternalDNS zone checks, Forgejo + Keycloak HTTPRoute acceptance, and any service-specific health checks.
- Only merge upgrades that finish bootstrap cleanly; never “document” an upgrade without success evidence (terminal output, logs, or CI artefacts) attached to the PR.

## Promotion: Roll Out in Layers
- Keep the OrbStack/kind environment as the proving ground. Move to Proxmox/bare-metal only after the Mac stack passes.
- For multi-step upgrades (e.g., CloudNativePG major versions), stage them with feature flags/parallel deployments so we can roll back via Git.
- Document plan/risk in component READMEs and cross-link to this strategy so operators know how to react when Renovate opens a PR.

## Security & Policy Guardrails
- Use admission policies (Kyverno/Gatekeeper) to block unpinned images and enforce acceptable registries.
- Run Trivy/Grype (or another scanner) in CI against both base images and rendered manifests; fail the pipeline on critical CVEs.
- Track Kubernetes API deprecations (plenty of tooling exists: `pluto`, `kubent`) whenever the control plane revs.

## Operational Tips
- Tag releases of this repo (Git tag) after a successful upgrade bundle so we can bisect regressions.
- Maintain a “component compatibility” matrix (Kubernetes ↔ Cilium ↔ cert-manager ↔ Forgejo) in `target-stack.md`. Update it when Renovate raises bumps with major/minor implications.
- Schedule monthly “dependency weeks” where we merge Renovate backlog and refresh the inventory; don’t let upgrades pile up.

## Suggested Tooling Stack Summary
- Renovate bot for version detection and PR generation.
- GitHub/GitLab CI job that spins up OrbStack/kind and runs `bootstrap-<env>.sh` + smoke tests.
- FluxCD Image Automation (future GitOps) for keeping environments in sync once CI approves a version bump.
- Security scanners (Trivy/Grype) + admission policies enforcing immutable/pinned tags.

A disciplined loop—detect, validate, promote—keeps DeployKube close to upstream without sacrificing reliability. Update this design doc as we add automation (e.g., Flux image policies) or standardise CI pipelines.
