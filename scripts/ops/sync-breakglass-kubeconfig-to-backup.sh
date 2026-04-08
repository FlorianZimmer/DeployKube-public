#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/ops/sync-breakglass-kubeconfig-to-backup.sh \
    --deployment-id <id> \
    --source-kubeconfig <path> \
    --confirm-in-cluster-copy yes \
    [--namespace <ns>] \
    [--secret-name <name>] \
    [--operator "<name>"] \
    [--ticket "<id>"] \
    [--evidence <path>]

Purpose:
  Copy the offline breakglass kubeconfig into an operator-managed Kubernetes Secret
  so `backup-system` can include it in encrypted recovery bundles.

Notes:
  - This is an explicit in-cluster copy of a breakglass credential.
  - The out-of-band stored kubeconfig remains the source of truth.
  - Cluster access for this script comes from the active `kubectl` context / `KUBECONFIG`.
EOF
}

require() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "error: missing dependency: ${cmd}" >&2
    exit 1
  }
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
    return 0
  fi
  echo "error: need shasum or sha256sum to compute SHA256" >&2
  exit 1
}

DEPLOYMENT_ID=""
SOURCE_KUBECONFIG=""
BACKUP_NAMESPACE="backup-system"
SECRET_NAME="backup-breakglass-kubeconfig"
OPERATOR_NAME="${USER:-}"
TICKET_ID=""
EVIDENCE_PATH=""
CONFIRM_IN_CLUSTER_COPY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id)
      DEPLOYMENT_ID="${2:-}"; shift 2 ;;
    --source-kubeconfig)
      SOURCE_KUBECONFIG="${2:-}"; shift 2 ;;
    --namespace)
      BACKUP_NAMESPACE="${2:-}"; shift 2 ;;
    --secret-name)
      SECRET_NAME="${2:-}"; shift 2 ;;
    --operator)
      OPERATOR_NAME="${2:-}"; shift 2 ;;
    --ticket)
      TICKET_ID="${2:-}"; shift 2 ;;
    --evidence)
      EVIDENCE_PATH="${2:-}"; shift 2 ;;
    --confirm-in-cluster-copy)
      CONFIRM_IN_CLUSTER_COPY="${2:-}"; shift 2 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" || -z "${SOURCE_KUBECONFIG}" ]]; then
  usage
  exit 1
fi

if [[ "${CONFIRM_IN_CLUSTER_COPY}" != "yes" ]]; then
  echo "error: refusing to copy breakglass kubeconfig into the cluster without --confirm-in-cluster-copy yes" >&2
  exit 1
fi

require awk
require date
require kubectl

if [[ "${SOURCE_KUBECONFIG}" != /* ]]; then
  SOURCE_KUBECONFIG="${REPO_ROOT}/${SOURCE_KUBECONFIG}"
fi

if [[ ! -s "${SOURCE_KUBECONFIG}" ]]; then
  echo "error: source kubeconfig not found (or empty): ${SOURCE_KUBECONFIG}" >&2
  exit 1
fi

context="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "${context}" ]]; then
  echo "error: kubectl current-context is empty; set KUBECONFIG or select a context first" >&2
  exit 1
fi

kubectl get namespace "${BACKUP_NAMESPACE}" >/dev/null

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
day_utc="$(date -u +%Y-%m-%d)"
sha256="$(sha256_file "${SOURCE_KUBECONFIG}")"
bytes="$(wc -c <"${SOURCE_KUBECONFIG}" | tr -d ' ')"

if [[ -z "${EVIDENCE_PATH}" ]]; then
  EVIDENCE_PATH="${REPO_ROOT}/docs/evidence/${day_utc}-backup-breakglass-kubeconfig-sync-${DEPLOYMENT_ID}.md"
fi
if [[ "${EVIDENCE_PATH}" != /* ]]; then
  EVIDENCE_PATH="${REPO_ROOT}/${EVIDENCE_PATH}"
fi

mkdir -p "$(dirname "${EVIDENCE_PATH}")"

kubectl -n "${BACKUP_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-file=BREAKGLASS_KUBECONFIG="${SOURCE_KUBECONFIG}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${BACKUP_NAMESPACE}" label --overwrite secret/"${SECRET_NAME}" app.kubernetes.io/name=backup-system >/dev/null
kubectl -n "${BACKUP_NAMESPACE}" annotate --overwrite secret/"${SECRET_NAME}" \
  darksite.cloud/breakglass-material=true \
  darksite.cloud/breakglass-source-sha256="${sha256}" \
  >/dev/null

stored_key="$(kubectl -n "${BACKUP_NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.BREAKGLASS_KUBECONFIG}' 2>/dev/null || true)"
if [[ -z "${stored_key}" ]]; then
  echo "error: secret ${BACKUP_NAMESPACE}/${SECRET_NAME} does not contain BREAKGLASS_KUBECONFIG after apply" >&2
  exit 1
fi

cat >"${EVIDENCE_PATH}" <<EOF
# Evidence: backup-system breakglass kubeconfig sync (${DEPLOYMENT_ID})

Date (UTC): \`${now_utc}\`

Purpose: record the operator action that copied the offline breakglass kubeconfig into the cluster so \`backup-system\` can include it in encrypted recovery bundles.

## Source credential (identified, not stored here)

- Deployment: \`${DEPLOYMENT_ID}\`
- Source kubeconfig path: \`${SOURCE_KUBECONFIG#${REPO_ROOT}/}\`
- SHA256: \`${sha256}\`
- Size: \`${bytes}\` bytes

## Target cluster copy

- Target context: \`${context}\`
- Namespace: \`${BACKUP_NAMESPACE}\`
- Secret: \`${SECRET_NAME}\`
- Secret key: \`BREAKGLASS_KUBECONFIG\`

## Operator record

- Operator: \`${OPERATOR_NAME}\`
- Ticket/incident (optional): \`${TICKET_ID}\`

## Attestation

I intentionally created or updated the in-cluster breakglass copy above so proxmox backup-set assembly can require and capture it in the encrypted recovery bundle. The out-of-band stored kubeconfig remains the primary custody copy.
EOF

echo "synced ${BACKUP_NAMESPACE}/${SECRET_NAME} from ${SOURCE_KUBECONFIG}"
echo "wrote evidence: ${EVIDENCE_PATH#${REPO_ROOT}/}"
