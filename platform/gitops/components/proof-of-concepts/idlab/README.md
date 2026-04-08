# Identity Lab Proof Of Concept

This component deploys a disposable identity lab in namespace `idlab` for the proxmox cluster.
The runtime+tests stack is intentionally packaged as an opt-in Argo app so it can be enabled,
validated, and torn down cleanly without joining the default platform bundle.

What it ships:
- `ukc-keycloak`, `mkc-keycloak`, `btp-keycloak`
- `PostgresInstance/idlab-postgres`
- `upstream-scim-facade`, `source-scim-ingest`, `mkc-scim-facade`, `sync-controller`, `btp-scim-facade`
- `proofs-pvc`
- a separate tests bundle with seed/config/auth/convergence Jobs

This is intentionally a proof of concept, not a long-term platform surface.
It runs in a dedicated non-tenant namespace because the current proxmox tenant baseline rejects the raw Keycloak dev-mode pods and kube-apiserver egress pattern that the proof jobs require.
Its stateful surfaces (`idlab-postgres` and `proofs-pvc`) are explicitly labeled `darksite.cloud/backup=skip` because this opt-in lab is disposable and is not part of the durable platform backup plane. The database now requests that disposable posture through `data.darksite.cloud/v1alpha1 PostgresInstance` and `PostgresClass/platform-poc-disposable` instead of shipping a raw CNPG `Cluster`.

Implementation fixes discovered during live rollout:
- The source provisioning contract is now strict SCIM push-to-push. `upstream-scim-facade` no longer exposes the source SCIM server; it acts as a UKC-side push adapter and publishes full-state SCIM users/groups/memberships into middle-side `source-scim-ingest`.
- `sync-controller` no longer polls upstream SCIM directly. It consumes the pushed source snapshot from the middle-layer state store, which keeps the middle boundary stateful while preserving a standard SCIM ingest contract on the upstream edge.
- The MKC provisioning contract is now SCIM as well. `sync-controller` provisions MKC users, groups, and memberships through `mkc-scim-facade` instead of a custom `/v1/*` shim, so the UKC -> MKC provisioning leg is protocol-standard at the service boundary.
- UKC seed users must include `email`, `firstName`, and `lastName`; otherwise the UKC broker flow can stop on the `VERIFY_PROFILE` required action before returning to MKC.
- MKC and BTP broker instances must be created as generic `oidc` IdPs with explicit endpoint URLs instead of relying on implicit provider defaults.
- MKC and BTP IdP instances must not be created with `linkOnly=true`; that blocks broker login entirely. The PoC keeps login enabled and proves the intended link-only behavior through pre-provisioned identities plus negative login tests.
- MKC and BTP first-broker-login flows must be existing-account-only: disable `Create User If Unique` and require `Handle Existing Account`, otherwise the negative link-only proofs can still create side-effect users even when the browser flow never reaches the callback.
- BTP runtime login for SCIM-provisioned users depends on a pre-created BTP federated identity link that points to the MKC user ID. Provisioning now owns that link instead of leaving BTP to interactive first-broker-login handling.
- MKC still needs a Keycloak-specific internal broker-link step for `users/{id}/federated-identity`. That is now isolated behind `mkc-scim-facade:/internal/federated-links` instead of being mixed into the MKC provisioning contract.
- The Playwright auth jobs use a synthetic `http://127.0.0.1/callback` redirect and must intercept that callback inside the browser job rather than expecting a listener on pod loopback.
- MKC broker logins were not reliably exposed through the expected `events?type=LOGIN` query on proxmox. The offline-enrollment proof now keys off the successful online auth artifacts already written to `proofs-pvc` and then verifies the MKC password credential through Admin REST after reset.
- The convergence proof must wait for the UKC realm endpoint after the Deployment rollout completes. Pod readiness alone was not sufficient before the post-outage admin calls.
- The suspended Argo test-hook model can leave the tests Application waiting on stale hook Jobs. For live reruns, use fresh concrete `*-runN` Jobs after the GitOps templates are updated.
- The steady-state tests Application uses suspended Job templates. Those Jobs are annotated with `argocd.argoproj.io/ignore-healthcheck: "true"` so Argo health reflects GitOps convergence rather than the intentionally paused execution state.
- Existing `Job` runs must be recreated when the template changes because Kubernetes keeps `Job.spec.template` immutable.

GitOps entrypoints:
- Opt-in Argo app: `platform/gitops/apps/opt-in/idlab-poc/applications/idlab-poc-prod.yaml`
- Combined stack path: `platform/gitops/components/proof-of-concepts/idlab/stack`

Manual entrypoints:
- Deploy runtime only: `kubectl apply -k platform/gitops/components/proof-of-concepts/idlab`
- Install proof job templates only: `kubectl apply -k platform/gitops/components/proof-of-concepts/idlab/tests`
- Deploy runtime + tests together: `kubectl apply -k platform/gitops/components/proof-of-concepts/idlab/stack`
- Run proof jobs sequentially by unsuspending them in order:
  - `idlab-seed-ukc`
  - `idlab-config-mkc`
  - `idlab-config-btp`
  - `idlab-smoke-provisioning`
  - `idlab-smoke-provisioning-guardrail`
  - `idlab-smoke-auth-online`
  - `idlab-offline-enroll`
  - `idlab-smoke-failover-manual`
  - `idlab-smoke-auth-manual-offline`
  - `idlab-smoke-auth-offline`
  - `idlab-smoke-offline-write`
  - `idlab-smoke-auth-offline-write`
  - `idlab-smoke-failover-auto`
  - `idlab-smoke-failover-auto-manual-return`
  - `idlab-smoke-convergence`
  - `idlab-smoke-negative-mkc-link-only`
  - `idlab-smoke-negative-btp-link-only`

Standard CI entrypoint:
- `./tests/scripts/e2e-idlab-poc.sh`
  - auto-detects already-present `proof-of-concepts-idlab` and `proof-of-concepts-idlab-tests` Applications and uses them directly, so live reruns do not create a conflicting opt-in wrapper app on top of the same resources
- `.github/workflows/idlab-idp-poc-e2e.yml`

Proof artifacts:
- Shared PVC: `PersistentVolumeClaim/idlab/proofs-pvc`
- Runtime files: `/proofs/*.json`
- Negative link-only proofs:
  - `/proofs/negative_mkc_link_only.json`
  - `/proofs/negative_btp_link_only.json`

Latest fully validated proof run:
- Date: `2026-03-11`
- Environment: proxmox existing-app mode
- Command: `KUBECONFIG=tmp/kubeconfig-prod bash./tests/scripts/e2e-idlab-poc.sh --mode existing --cleanup no --timeout 1800`
- Result: full proof sequence completed with `PASS: idlab IdP PoC E2E completed` on the strict push-to-push topology
-

Tracker: `docs/component-issues/idlab-proof-of-concepts.md`
Proof-of-concept docs: `docs/proof-of-concepts/idlab-offline-identity-lab.md`
PoC operating guide: `docs/guides/proof-of-concepts.md`
