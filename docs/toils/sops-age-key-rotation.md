# Toil: SOPS Age key rotation (DSB)

This repo supports two-phase SOPS Age key rotation for the **Deployment Secrets Bundle (DSB)**.

Bootstrap playbook (end-to-end): `docs/guides/bootstrap-new-cluster.md`.

Goals:
- Add a new Age recipient without downtime (Phase A)
- Validate consumers can decrypt using a combined identities file
- Remove the old recipient (Phase B)

## Phase A: add recipient + dual-key window

```bash
DEPLOYMENT_ID="mac-orbstack-single" # or proxmox-talos
KUBE_CONTEXT="kind-deploykube-dev" # optional (omit if KUBECONFIG already points to the target cluster)./scripts/deployments/rotate-sops.sh \
  --deployment-id "$DEPLOYMENT_ID" \
  --phase add \
  --kube-context "$KUBE_CONTEXT"./tests/scripts/validate-deployment-secrets-bundle.sh
```

Then commit + push the GitOps subtree to Forgejo and force Argo to refresh:

```bash
git add "platform/gitops/deployments/$DEPLOYMENT_ID"
git commit -m "chore(secrets): start sops age rotation ($DEPLOYMENT_ID)"
FORGEJO_FORCE_SEED=true./shared/scripts/forgejo-seed-repo.sh

kubectl -n argocd annotate application platform-apps argocd.argoproj.io/refresh=hard --overwrite
```

Validation signals:
- `deployment-secrets-bundle` app is `Synced/Healthy`
- Consumers that decrypt DSB secrets still succeed (e.g. `secrets-bootstrap`, `certificates-step-ca-seed`)

## Phase B: finalize (drop old recipient)

The Phase A output tells you the new recipient and the new key file that was generated.

```bash
DEPLOYMENT_ID="mac-orbstack-single"
NEW_RECIPIENT="age1..." # from phase A output
NEW_KEY_FILE="$HOME/.config/deploykube/deployments/$DEPLOYMENT_ID/sops/age.key.new.<timestamp>" # from phase A output./scripts/deployments/rotate-sops.sh \
  --deployment-id "$DEPLOYMENT_ID" \
  --phase finalize \
  --recipient "$NEW_RECIPIENT" \
  --key-file "$NEW_KEY_FILE" \
  --kube-context "kind-deploykube-dev"./tests/scripts/validate-deployment-secrets-bundle.sh
```

Commit + reseed Forgejo + refresh Argo again.

## Custody record (prod gate)

After a rotation, record custody acknowledgement for the *current* deployment key file:

```bash./shared/scripts/sops-age-key-custody-ack.sh \
  --deployment-id "$DEPLOYMENT_ID" \
  --age-key-file "$HOME/.config/deploykube/deployments/$DEPLOYMENT_ID/sops/age.key" \
  --storage-location "<...>"
```
