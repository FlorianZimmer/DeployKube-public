# Testing Harness Implementation Plan

## Objectives
- Provide a repeatable test entry point for humans, agents, and CI that validates each environment, platform component, and user journey.
- Co-locate component smoke tests beside their overlays while exposing a single orchestration surface (e.g., `just test --env mac-orbstack`).
- Integrate harness execution into bootstrap scripts so every run enforces the same checks.
- Assert Kubernetes readiness for every managed workload (Pods, Deployments, StatefulSets, Jobs, PVCs/PVs, CRDs) before passing.

## Tooling Decisions (locked for MVP)
- **Harness language**: Go (`testing` + `client-go`) for fast execution and direct Kubernetes API access.
- **CLI orchestrator**: `just` (Justfile) for repo-level commands (`bootstrap`, `test`, `test component=storage`).
- **Shared helpers**: new package under `tests/lib/` housing kube clients, polling utilities, log capture.
- **Containerised runner**: build and publish a test-runner image so CI and local developers execute the suite identically.
- **CI target**: GitHub Actions (later) running the same commands the team uses locally.

## Incremental Steps
1. **Scaffold repo-level orchestration**
   - Add `Justfile` stubs (`just bootstrap-mac-orbstack`, `just test env=mac-orbstack`).
   - Document usage in `README.md` and `agents.md`.

2. **Set up Go test workspace**
   - Introduce `tests/go.mod` with dependencies (`k8s.io/client-go`, `github.com/stretchr/testify`).
   - Create `tests/lib/kubeclient` helper for context discovery and retry helpers.

3. **Port existing storage smoke test**
   - Wrap current RWX PVC/Job manifests in Go: apply manifests, wait for completion, capture logs.
   - Expose entry point `go test./tests/storage -run TestRWX`.
   - Update `shared/scripts/bootstrap-mac-orbstack.sh` to call the Go test instead of raw `kubectl`.

4. **Bootstrap plumbing**
   - Modify bootstrap script to invoke `just test component=storage` (or direct `go test`) with `ENABLE_SHARED_STORAGE_VERIFY`.
   - Ensure failures bubble out with clear logs and exit codes.

5. **Core platform coverage**
   - Add suites per component (Cilium, MetalLB, cert-manager, step-ca, Vault transit).
   - Each suite should live beside its GitOps component under `platform/gitops/components/<category>/<component>/tests/go/` and reuse shared helpers.
   - Provide `component_test.go` skeletons with placeholders for API checks.

6. **Environment smoke suite**
   - Implement `tests/mac_orbstack/suite_test.go` aggregating component tests plus cluster health (node taints, storage classes, ingress routes).
   - Wire `just test env=mac-orbstack` to run this package.

7. **User journey scenarios**
   - Model full workflows (e.g., `TestGitOpsPipeline`, `TestKeycloakLogin`) with feature flags so they can be opt-in (`JUST_PROFILE=user`).
   - Capture logs/URLs on failure. Postpone browser-driven UX automation (Selenium, etc.) until after the MVP harness lands.

8. **CI integration**
   - Add pipeline job executing `just bootstrap-mac-orbstack` + `just test env=mac-orbstack`.
   - Publish junit XML from Go tests for visibility.

9. **Cross-environment expansion**
   - Duplicate harness patterns for Proxmox and Baremetal once parity exists.
   - Share common helpers via `tests/lib`.

10. **Documentation & maintenance**
    - Update component READMEs with test invocation instructions.
    - Refresh `agents.md` testing doctrine with concrete commands.
    - Track follow-up work (e.g., load testing, chaos experiments) in this plan.

## Follow-ups
- Add browser/Selenium-style UX automation when we extend test coverage beyond the MVP.
- Design the containerised test-runner build and publishing workflow (base image, caching strategy).
- Re-evaluate artifact retention once the harness produces output; default to CI job logs and skip cross-environment artifact stores unless a concrete need emerges.
