#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "missing dependency: kubectl" >&2
  exit 1
fi

ts="$(date -u +%Y%m%d%H%M%S)"
tenant_id="smoke-${ts}"
ns="tenant-guardrails-smoke-${ts}"

cleanup() {
  kubectl delete namespace "${ns}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[tenant-guardrails] creating namespace ${ns} (tenant-id=${tenant_id})"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    darksite.cloud/rbac-profile: tenant
    darksite.cloud/tenant-id: ${tenant_id}
    observability.grafana.com/tenant: ${tenant_id}
YAML

fail_expected() {
  local name="$1"
  shift
  echo "[tenant-guardrails] expect DENY: ${name}"
  if "$@" >/tmp/tenant-guardrails-deny.log 2>&1; then
    echo "[tenant-guardrails] ERROR: expected deny but command succeeded: ${name}" >&2
    exit 1
  fi
  tail -n 30 /tmp/tenant-guardrails-deny.log >&2 || true
}

pass_expected() {
  local name="$1"
  shift
  echo "[tenant-guardrails] expect ALLOW: ${name}"
  "$@" >/dev/null
}

if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  fail_expected "ExternalSecret in tenant namespace" \
    kubectl -n "${ns}" apply --dry-run=server -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: deny-me
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-core
  target:
    name: projected-secret
  data:
    - secretKey: value
      remoteRef:
        key: secret/somewhere
        property: value
YAML
else
  echo "[tenant-guardrails] skip ExternalSecret test (CRD externalsecrets.external-secrets.io not present)"
fi

fail_expected "NetworkPolicy with ipBlock" \
  kubectl -n "${ns}" apply --dry-run=server -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-ipblock
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 198.51.100.0/24
YAML

pass_expected "PVC shared-rwo RWO" \
  kubectl -n "${ns}" apply --dry-run=server -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: allow-shared-rwo
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: shared-rwo
YAML

fail_expected "PVC non-allowed StorageClass" \
  kubectl -n "${ns}" apply --dry-run=server -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: deny-storageclass
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
YAML

fail_expected "PVC ReadWriteMany" \
  kubectl -n "${ns}" apply --dry-run=server -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: deny-rwx
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: shared-rwo
YAML

echo "[tenant-guardrails] OK"
