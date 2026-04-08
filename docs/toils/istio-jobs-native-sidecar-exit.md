# Toil: Istio Jobs (native sidecar exit)

When a `Job` runs in an Istio-injected namespace, it may never reach `Complete` because the Istio sidecar container stays alive even after your main container exits.

DeployKube standard:
1) Use Istio **native sidecars** on the Job pod (`sidecar.istio.io/nativeSidecar: "true"`).
2) On exit, explicitly tell Envoy to quit via the shared helper script `istio-native-exit.sh` (calls `http://127.0.0.1:15020/quitquitquit`).

## Kustomize wiring

Add the helper ConfigMap to your component:
- In your component `kustomization.yaml`, add: `../../shared/bootstrap-scripts/istio-native-exit`

## Job pattern

Mount the helper and `trap` it on exit:

```yaml
metadata:
  annotations:
    sidecar.istio.io/nativeSidecar: "true"
spec:
  template:
    metadata:
      annotations:
        sidecar.istio.io/nativeSidecar: "true"
    spec:
      containers:
      - name: your-job
        volumeMounts:
        - name: istio-native-exit
          mountPath: /helpers
          readOnly: true
        command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          ISTIO_HELPER="/helpers/istio-native-exit.sh"
          [ -f "$ISTIO_HELPER" ] || { echo "missing istio-native-exit helper" >&2; exit 1; }. "$ISTIO_HELPER"
          trap deploykube_istio_quit_sidecar EXIT INT TERM
          #... your job logic...
      volumes:
      - name: istio-native-exit
        configMap:
          name: istio-native-exit-script
          defaultMode: 0444
```

## Notes

- If your image lacks `curl`, either install it (see `platform/gitops/components/secrets/vault/config/backup.yaml`) or use `deploykube/bootstrap-tools:*` which already has it.
- Prefer this pattern over disabling injection; we usually want mesh policy to apply consistently even for Jobs.

