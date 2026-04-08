# Toil: SOPS Age key custody acknowledgement (DSB)

The Deployment Secrets Bundle (DSB) uses SOPS Age identities to decrypt bootstrap-only secrets at runtime.

Bootstrap playbook (end-to-end): `docs/guides/bootstrap-new-cluster.md`.

For **prod-class deployments**, Stage 1 enforces a custody acknowledgement gate: it refuses to proceed unless you recorded where the Age key is stored out-of-band.

## Acknowledge custody (writes local sentinel + evidence)

```bash
DEPLOYMENT_ID="proxmox-talos" # or mac-orbstack-single
AGE_KEY_FILE="$HOME/.config/deploykube/deployments/$DEPLOYMENT_ID/sops/age.key"./shared/scripts/sops-age-key-custody-ack.sh \
  --deployment-id "$DEPLOYMENT_ID" \
  --age-key-file "$AGE_KEY_FILE" \
  --storage-location "<password manager / vault path / envelope ID>"
```

Outputs:
- Local sentinel (not a secret, but machine-local): `tmp/bootstrap/sops-age-key-acked-<deploymentId>`
- Evidence (commit this): `docs/evidence/YYYY-MM-DD-sops-age-key-custody-ack-<deploymentId>.md`

## When to re-run

- After generating a new key for a deployment
- After SOPS key rotation (the key file SHA changes)
- After restoring a deployment key from out-of-band storage

## Troubleshooting

- If Stage 1 fails with “missing SOPS Age custody acknowledgement sentinel”, run the command above.
- If it fails with “SHA mismatch”, re-run the acknowledgement against the key file that Stage 1 uses.
