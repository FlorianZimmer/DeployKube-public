# Vault GitOps Repair Plan

> Archived note: this captures a historical failure mode and repair plan. It may not match the current implementation.

This note captures why the Vault stack previously failed under the Stage 0/Stage 1 + Argo GitOps flow and broke the bootstrap, then outlines the steps that were required to make it deterministic again. It complements `docs/design/gitops-operating-model.md` by focusing only on the Vault + (now-retired) transit + External Secrets slice.

## Historical Snapshot

- **Secrets bootstrap job depends on pre-populated SOPS blobs** – `platform/gitops/components/secrets/bootstrap/scripts/bootstrap.sh` decrypts the four SOPS files and applies them into `vault-system` / `vault-transit`. On a brand-new cluster those files still contain placeholders, so the job fails immediately even though we already injected the Age key via `shared/scripts/bootstrap-mac-orbstack-stage1.sh`.
- **Transit bootstrap expects GitOps secrets** (historical; transit is now retired) – the old transit bootstrap script aborted when `vault-transit-init` or either copy of `vault-transit-token` was missing/placeholder, causing Argo’s automated sync loops to wedge early.
- **Core bootstrap never inits Vault** – `platform/gitops/components/secrets/vault/bootstrap/scripts/vault-init.sh` only verifies that the `vault-init` secret already exists; it never calls `vault operator init`. That work currently lives in `shared/scripts/init-vault-secrets.sh`, which runs on the host after Stage 1.
- **Auto-sync conflict** – As soon as Stage 1 applies the root `Application`, Argo starts reconciling `secrets-vault*` apps even though the required secrets are missing. Jobs fail, self-heal requeues them, and the StatefulSets oscillate between `Pending` and `CrashLoopBackOff` when the auto-unseal token is blank.
- **Secrets of record live in three places** – We must keep (a) SOPS-encrypted files in `platform/gitops/components/secrets/bootstrap/secrets/`, (b) Kubernetes Secrets inside the cluster, and (c) the Forgejo repo (so Argo can keep applying updated ConfigMaps). Today `shared/scripts/init-vault-secrets.sh` tries to juggle these but does not clearly gate Argo or document the expected operator steps.
- **Legacy bootstrap (now removed)** – the old all-in-one script used to perform transit + core `vault operator init`, write JSON to a gitignored directory, and apply the resulting Secrets immediately so Vault pods always saw valid credentials. The current flow replaces that with GitOps jobs and SOPS-managed bootstrap secrets; use those instead.

## Accepted Limitations (for now)

- **Manual SOPS publishing** – Until we build an in-cluster controller that can push encrypted blobs back to Forgejo, operators must run `shared/scripts/init-vault-secrets.sh` locally with access to their Age private key. This is acceptable for the reboot milestone, but the limitation is tracked here so we can revisit headless automation once the rest of the platform stabilises.

## Desired Day-0 Flow (Clean Cluster)

1. **Stage 0/1** bring up the cluster, shared storage, Forgejo, and Argo. Stage 1 already copies the operator’s Age key at `$SOPS_AGE_KEY_FILE` into `argocd/argocd-sops-age`.
2. Argo syncs the root Application, installing `secrets-bootstrap` (wave -6) plus the transit/core Applications (waves -5 → 0). They are expected to report `OutOfSync`/`Degraded` until secrets exist.
3. Immediately run `shared/scripts/init-vault-secrets.sh`:
   - Wait for transit pods (`vault-transit` StatefulSet) to exist even if sealed.
   - Call `vault operator init` inside transit, capture `root_token` + `unseal_keys_b64`, generate a deterministic auto-unseal token ID, and write four Kubernetes Secret manifests (transit init + two token copies).
   - Encrypt those manifests into `platform/gitops/components/secrets/bootstrap/secrets/*.sops.yaml` using the operator’s Age key, commit, and push them to Forgejo (`platform/cluster-config`).
   - Apply the plaintext secrets back into the cluster so the transit job can proceed immediately.
4. Rerun the `secrets-bootstrap` job (either by deleting the Job or letting the script drive `kubectl apply`) so Argo now sees real SOPS contents and the job re-applies the decrypted secrets.
5. Once transit reports `Sealed=false`, repeat the process for the core Vault StatefulSet: wait for pods, `vault operator init`, capture `root_token` + `recovery_keys_b64`, update/commit/push the SOPS file, and re-run `secrets-bootstrap`.
6. Trigger Argo syncs for `secrets-vault-*` Applications (bootstrap → config → helm) so the jobs finish and the StatefulSet converges. Re-enable `selfHeal` once Vault is `Ready`.

## Repair Tasks

| Task | Owner | Details |
| --- | --- | --- |
| **Document & enforce the bootstrap handshake** | Platform | Update `shared/scripts/bootstrap-mac-orbstack-clean.sh` docs + `platform/gitops/components/secrets/vault*/README.md` to say that Stage 1 is incomplete until `init-vault-secrets.sh` runs with a valid Age key. Highlight that Argo errors are expected before that step. |
| **Age key pre-flight helper** | Platform | Add an explicit Stage 1 prerequisite: if `SOPS_AGE_KEY_FILE` is unset or the file is missing, instruct operators to run `age-keygen -o ~/.config/sops/age/keys.txt` before continuing. Surface the same remediation text in the bootstrap/orchestrator scripts so newcomers never reach Argo without a key. |
| **Harden `init-vault-secrets.sh`** | Platform | Ensure the script pauses Argo self-heal on the transit/core Applications while it wipes PVCs or updates Secrets, then resumes once secrets are in place. Add explicit waits for `secrets-bootstrap` completion and surface actionable errors if the Forgejo admin password (`tmp/forgejo-bootstrap-admin.txt`) is missing. |
| **Guarantee ConfigMap refresh** | Platform | After writing new SOPS blobs, the script already patches the `secrets-bootstrap-sops` ConfigMap. We need to verify this is sufficient for Argo (SSA) and document that behaviour. Optionally add a hash annotation on the Job pod template so Argo re-runs it when the ConfigMap data changes. |
| **Improve vault-init job messaging** | Platform | Update `platform/gitops/components/secrets/vault/bootstrap/scripts/vault-init.sh` to emit a clearer error: “Run `shared/scripts/init-vault-secrets.sh` to capture fresh credentials” when the secret is missing. Do the same for transit bootstrap so debugging points to the correct remediation. |
| **Add validation hooks** | Platform | Extend the safeguard job to check that `vault-init` in-cluster values match the SOPS contents (hash comparison) so we can detect drift between repo and cluster after manual edits. |
| **Evidence loop** | Platform | After implementing the above, capture a full teardown + Stage 0 + Stage 1 + `init-vault-secrets.sh` run, recording Argo syncs, `kubectl wait` outputs, and the Git commit that introduced the refreshed SOPS secrets. Store links in `docs/design/gitops-operating-model.md` or `docs/evidence/`. |
| **Preserve-mode safety in `init-vault-secrets.sh`** | Platform | Refactor the script so `--skip-*` or `BOOTSTRAP_SKIP_VAULT_INIT=true` short-circuits before any StatefulSet/PVC deletion. Wipe actions must verify the OrbStack NFS host is running, confirm the target directories exist, and prompt/log before destructive steps. |

## Open Questions / Risks

- **Automating SOPS updates entirely in-cluster (deferred):** manual pushes are acceptable for now, but we still need a design for CI/headless flows once the reboot stabilises.
- **Age key distribution:** Stage 1 assumes the operator already has `~/.config/sops/age/keys.txt`. We should add a pre-flight check or helper (`age-keygen -o...`) in Stage 0/Stage 1 instructions so new contributors do not hit the missing-key failure.
- **Vault wipe semantics:** `init-vault-secrets.sh --wipe-*` deletes StatefulSets/PVCs and scrubs `deploykube-nfs-data`. We must ensure OrbStack’s NFS container is running and that the script exits early (without touching PVCs) when `BOOTSTRAP_SKIP_VAULT_INIT=true` so preserve-mode bootstraps remain safe.

## Next Steps

1. Socialise this plan with stakeholders and get sign-off that `init-vault-secrets.sh` is the canonical way to seed credentials.
2. Implement the hardening items above, then run `shared/scripts/bootstrap-mac-orbstack-clean.sh` end-to-end to capture evidence.
3. Update the Vault component README and `docs/component-issues/vault.md` once the repair is validated so future operators don’t rediscover the same failure mode.
