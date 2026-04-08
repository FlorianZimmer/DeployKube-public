# SOPS on macOS: Age key discovery (DSB)

On this repo, SOPS-encrypted files are managed via the **Deployment Secrets Bundle (DSB)** and use an Age recipient configured per deployment:

- `platform/gitops/deployments/<deploymentId>/.sops.yaml`

For the end-to-end bootstrap workflow (Mac + Proxmox), see `docs/guides/bootstrap-new-cluster.md`.

On macOS, `sops` may **not** auto-discover the default Age identity file, so local edits can fail with:
`no identity matched any of the recipients`.

## Fix (recommended)

Export the Age key file path in your shell.

Recommended (deployment-scoped, matches the DSB contract):

```bash
export DEPLOYKUBE_DEPLOYMENT_ID="mac-orbstack-single" # or proxmox-talos
export SOPS_AGE_KEY_FILE="$HOME/.config/deploykube/deployments/$DEPLOYKUBE_DEPLOYMENT_ID/sops/age.key"
```

Legacy fallback (during migration only):

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

Verify decryption works (ciphertext in Git; no secret values printed):

```bash
sops -d platform/gitops/deployments/mac-orbstack-single/secrets/vault-init.secret.sops.yaml >/dev/null
echo "ok"
```

## Persist for zsh (optional)

```bash
rg -n "SOPS_AGE_KEY_FILE" ~/.zshrc || true
echo 'export DEPLOYKUBE_DEPLOYMENT_ID="mac-orbstack-single"' >> ~/.zshrc
echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/deploykube/deployments/$DEPLOYKUBE_DEPLOYMENT_ID/sops/age.key"' >> ~/.zshrc
```

## Recovery (if you lost the local key)

If you have cluster admin access, Stage 1 copies the operator Age key into `argocd/argocd-sops-age`. You can recover it:

```bash
export DEPLOYKUBE_DEPLOYMENT_ID="mac-orbstack-single" # or proxmox-talos
mkdir -p "$HOME/.config/deploykube/deployments/$DEPLOYKUBE_DEPLOYMENT_ID/sops"
kubectl -n argocd get secret argocd-sops-age -o jsonpath='{.data.age\.key}' | base64 -d > "$HOME/.config/deploykube/deployments/$DEPLOYKUBE_DEPLOYMENT_ID/sops/age.key"
chmod 0600 "$HOME/.config/deploykube/deployments/$DEPLOYKUBE_DEPLOYMENT_ID/sops/age.key"
export SOPS_AGE_KEY_FILE="$HOME/.config/deploykube/deployments/$DEPLOYKUBE_DEPLOYMENT_ID/sops/age.key"
```
