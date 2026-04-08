#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "missing dependency: kubectl" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "missing dependency: openssl" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "missing dependency: python3" >&2; exit 1; }

SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
TOKEN_FILE="${SA_DIR}/token"
CA_FILE="${SA_DIR}/ca.crt"

if [[ ! -r "${TOKEN_FILE}" || ! -r "${CA_FILE}" ]]; then
  echo "missing serviceaccount token/ca at ${SA_DIR}" >&2
  exit 1
fi

KUBE_HOST="${KUBERNETES_SERVICE_HOST:-}"
KUBE_PORT="${KUBERNETES_SERVICE_PORT:-}"
if [[ -z "${KUBE_HOST}" || -z "${KUBE_PORT}" ]]; then
  echo "missing KUBERNETES_SERVICE_HOST/PORT env vars" >&2
  exit 1
fi

KUBECONFIG_PATH="/tmp/kubeconfig"
cat >"${KUBECONFIG_PATH}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: https://${KUBE_HOST}:${KUBE_PORT}
    certificate-authority: ${CA_FILE}
users:
- name: sa
  user:
    tokenFile: ${TOKEN_FILE}
contexts:
- name: in-cluster
  context:
    cluster: in-cluster
    user: sa
current-context: in-cluster
EOF
export KUBECONFIG="${KUBECONFIG_PATH}"

# Wait for API connectivity; with Istio injection the proxy can take a moment to come up.
for _ in $(seq 1 30); do
  if kubectl version --request-timeout=2s >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
kubectl version --request-timeout=5s >/dev/null 2>&1 || { echo "kube API not reachable from this pod" >&2; exit 1; }

exec python3 /scripts/monitor.py
