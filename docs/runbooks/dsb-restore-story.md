# Runbook: DSB restore story (lost SOPS Age key) + “safe rebootstrap” definition

The Deployment Secrets Bundle (DSB) stores **bootstrap-only** secrets as SOPS-encrypted manifests under:
- `platform/gitops/deployments/<deploymentId>/secrets/*.secret.sops.yaml`

Those files are decrypted by bootstrap consumers using the deployment’s **SOPS Age private key** loaded into the cluster as:
- `Secret/argocd/argocd-sops-age` (created by Stage 1 from `SOPS_AGE_KEY_FILE`)

Bootstrap playbook (end-to-end): `docs/guides/bootstrap-new-cluster.md`.

Related toils:
- Custody acknowledgement (prod gate): `docs/toils/sops-age-key-custody.md`
- Two-phase rotation: `docs/toils/sops-age-key-rotation.md`

## What “safe rebootstrap” means (DSB scope)

In this repo, **safe rebootstrap** (w.r.t. DSB) means:

1) The deployment’s DSB ciphertext files remain present in Git (`platform/gitops/deployments/<deploymentId>/secrets/**`), and
2) Operators can obtain the correct Age private key **out-of-band** (custody), so Stage 1 can recreate `argocd/argocd-sops-age`, and
3) All DSB consumers can decrypt their inputs and converge without human “hand edits” inside the cluster.

If the Age private key is lost and cannot be recovered, you are no longer able to decrypt the bootstrap material stored in Git. At that point, you must treat this as a **tier-0 credential loss** and perform rotations/re-initializations for the affected secret values (Vault init/transit material, Step CA seed material, and any other DSB consumers).

## Recovery scenarios

### Scenario A — Local Age key lost, cluster still reachable

Goal: recover the Age identities file from the cluster, then re-establish custody evidence.

1) Treat this as breakglass-class access:
   - Use a trusted kubeconfig for the target cluster.
2) Retrieve the in-cluster Age identities file:
   - `argocd/argocd-sops-age` contains the Age identities content that Stage 1 loaded.
3) Restore it to the deployment-scoped key path (recommended default):
   - `~/.config/deploykube/deployments/<deploymentId>/sops/age.key`
4) Re-run custody acknowledgement (required for prod deployments):
   ```bash./shared/scripts/sops-age-key-custody-ack.sh \
     --deployment-id "<deploymentId>" \
     --age-key-file "$HOME/.config/deploykube/deployments/<deploymentId>/sops/age.key" \
     --storage-location "<password manager / vault path / envelope ID>"
   ```
5) Validate repo hygiene:
   ```bash./tests/scripts/validate-deployment-secrets-bundle.sh
   ```

Notes:
- Do **not** generate a new Age key “just to get unstuck” for prod deployments. That makes existing DSB ciphertext undecryptable until you rotate keys and re-encrypt (§Rotation).

### Scenario B — Cluster wiped, Age key available out-of-band

Goal: rebootstrap normally using the existing Age key.

1) Restore the Age identities file to:
   - `~/.config/deploykube/deployments/<deploymentId>/sops/age.key`
2) Ensure Stage 1 uses it:
   ```bash
   export DEPLOYKUBE_DEPLOYMENT_ID="<deploymentId>"
   export SOPS_AGE_KEY_FILE="$HOME/.config/deploykube/deployments/<deploymentId>/sops/age.key"
   ```
3) For prod deployments, ensure custody ack sentinel matches the key file SHA:
   - Toil: `docs/toils/sops-age-key-custody.md`
4) Run bootstrap (Stage 0/1) as usual:
   - Guide: `docs/guides/bootstrap-new-cluster.md`
5) Confirm the DSB validator passes:
   ```bash./tests/scripts/validate-deployment-secrets-bundle.sh
   ```

### Scenario C — Cluster wiped and Age key lost (cannot be recovered)

Outcome: you cannot decrypt the DSB bootstrap material stored in Git. Recovery requires **reset/rotation** of the affected tier-0 secret values.

Required actions (high level):
- Generate a new Age key for the deployment.
- Update `platform/gitops/deployments/<deploymentId>/.sops.yaml` to the new recipient(s).
- Replace affected DSB secret values with new material and re-encrypt to the new key.
- Rebootstrap and re-establish trust for dependents:
  - Vault init/transit material changes imply Vault access-plane changes.
  - Step CA seed changes may imply PKI trust anchor changes (high blast radius).

Operator workflow:
- Use the rotation helper where possible: `docs/toils/sops-age-key-rotation.md`
- Record a new custody acknowledgement: `docs/toils/sops-age-key-custody.md`

This scenario is a sev-1 platform risk. Capture evidence and track follow-ups as needed.
