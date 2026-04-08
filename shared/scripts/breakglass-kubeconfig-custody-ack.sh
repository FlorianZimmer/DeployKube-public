#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./shared/scripts/breakglass-kubeconfig-custody-ack.sh \
    --deployment-id <id> \
    --kubeconfig <path> \
    --storage-location "<where you stored it out-of-band>" \
    [--operator "<name>"] \
    [--ticket "<id>"] \
    [--evidence <path>]

Purpose:
  Records an operator attestation that the offline Kubernetes breakglass kubeconfig
  was saved out-of-band (password manager / vault / envelope) after deployment.

Outputs:
  - Evidence markdown under docs/evidence/ (no secrets; includes SHA256 + storage location ID)
  - Local sentinel under tmp/bootstrap/ to unblock bootstrap continuation

Notes:
  - This script does NOT copy the kubeconfig anywhere (by design).
  - It will ask you to re-type the kubeconfig SHA256 to avoid “click through” mistakes.
EOF
}

require() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${cmd}" >&2
    exit 1
  fi
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  echo "error: need shasum or sha256sum to compute SHA256" >&2
  exit 1
}

DEPLOYMENT_ID=""
KUBECONFIG_PATH=""
STORAGE_LOCATION=""
OPERATOR_NAME="${USER:-}"
TICKET_ID=""
EVIDENCE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id)
      DEPLOYMENT_ID="${2:-}"; shift 2;;
    --kubeconfig)
      KUBECONFIG_PATH="${2:-}"; shift 2;;
    --storage-location)
      STORAGE_LOCATION="${2:-}"; shift 2;;
    --operator)
      OPERATOR_NAME="${2:-}"; shift 2;;
    --ticket)
      TICKET_ID="${2:-}"; shift 2;;
    --evidence)
      EVIDENCE_PATH="${2:-}"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "error: unknown arg: $1" >&2
      usage
      exit 1;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" || -z "${KUBECONFIG_PATH}" || -z "${STORAGE_LOCATION}" ]]; then
  usage
  exit 1
fi

require awk
require date

if [[ "${KUBECONFIG_PATH}" != /* ]]; then
  KUBECONFIG_PATH="${REPO_ROOT}/${KUBECONFIG_PATH}"
fi

if [[ ! -s "${KUBECONFIG_PATH}" ]]; then
  echo "error: kubeconfig not found (or empty): ${KUBECONFIG_PATH}" >&2
  exit 1
fi

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
day_utc="$(date -u +%Y-%m-%d)"
sha256="$(sha256_file "${KUBECONFIG_PATH}")"
bytes="$(wc -c <"${KUBECONFIG_PATH}" | tr -d ' ')"

if [[ -z "${EVIDENCE_PATH}" ]]; then
  EVIDENCE_PATH="${REPO_ROOT}/docs/evidence/${day_utc}-breakglass-kubeconfig-custody-ack-${DEPLOYMENT_ID}.md"
fi
if [[ "${EVIDENCE_PATH}" != /* ]]; then
  EVIDENCE_PATH="${REPO_ROOT}/${EVIDENCE_PATH}"
fi

SENTINEL_DIR="${REPO_ROOT}/tmp/bootstrap"
SENTINEL_PATH="${SENTINEL_DIR}/breakglass-kubeconfig-acked-${DEPLOYMENT_ID}"

echo ""
echo "Breakglass kubeconfig custody acknowledgement"
echo "  deployment:  ${DEPLOYMENT_ID}"
echo "  kubeconfig:   ${KUBECONFIG_PATH}"
echo "  size:         ${bytes} bytes"
echo "  sha256:       ${sha256}"
echo "  storage:      ${STORAGE_LOCATION}"
if [[ -n "${TICKET_ID}" ]]; then
  echo "  ticket:       ${TICKET_ID}"
fi
echo ""
echo "You must now confirm:"
echo "  (1) you copied this kubeconfig to the out-of-band storage location above"
echo "  (2) you verified you can retrieve it"
echo ""

read -r -p "Type the SHA256 again to confirm: " sha_confirm
if [[ "${sha_confirm}" != "${sha256}" ]]; then
  echo "error: SHA256 did not match; refusing to record ack" >&2
  exit 1
fi

read -r -p "Type 'SAVED-OUT-OF-BAND' to confirm: " confirm
if [[ "${confirm}" != "SAVED-OUT-OF-BAND" ]]; then
  echo "error: confirmation phrase did not match; refusing to record ack" >&2
  exit 1
fi

mkdir -p "${SENTINEL_DIR}"
mkdir -p "$(dirname "${EVIDENCE_PATH}")"

cat >"${SENTINEL_PATH}" <<EOF
timestamp_utc=${now_utc}
deployment_id=${DEPLOYMENT_ID}
kubeconfig_path=${KUBECONFIG_PATH}
kubeconfig_sha256=${sha256}
storage_location=${STORAGE_LOCATION}
operator=${OPERATOR_NAME}
ticket=${TICKET_ID}
EOF

cat >"${EVIDENCE_PATH}" <<EOF
# Evidence: Breakglass kubeconfig custody acknowledgement (${DEPLOYMENT_ID})

Date (UTC): \`${now_utc}\`

Purpose: operator attestation that the **offline Kubernetes breakglass kubeconfig** was saved out-of-band after deployment.

## Credential (identified, not stored)

- Deployment: \`${DEPLOYMENT_ID}\`
- Local path (working copy): \`${KUBECONFIG_PATH#${REPO_ROOT}/}\`
- SHA256: \`${sha256}\`
- Size: \`${bytes}\` bytes

## Custody record (out-of-band)

- Storage location: \`${STORAGE_LOCATION}\`
- Operator: \`${OPERATOR_NAME}\`
- Ticket/incident (optional): \`${TICKET_ID}\`

## Attestation

I confirm that I copied the kubeconfig identified above into the out-of-band storage location and verified retrieval.
EOF

chmod 600 "${SENTINEL_PATH}" || true

echo ""
echo "OK: recorded local sentinel: ${SENTINEL_PATH#${REPO_ROOT}/}"
echo "OK: wrote evidence file:      ${EVIDENCE_PATH#${REPO_ROOT}/}"
echo ""
echo "Next:"
echo "  - Commit the evidence file (recommended): git add '${EVIDENCE_PATH#${REPO_ROOT}/}' && git commit -m 'evidence: breakglass custody ack (${DEPLOYMENT_ID})'"
echo ""

