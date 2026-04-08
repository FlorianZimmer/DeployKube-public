#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./shared/scripts/sops-age-key-custody-ack.sh \
    --deployment-id <id> \
    --age-key-file <path> \
    --storage-location "<where you stored it out-of-band>" \
    [--operator "<name>"] \
    [--ticket "<id>"] \
    [--evidence <path>]

Purpose:
  Records an operator attestation that the Deployment Secrets Bundle (DSB)
  SOPS Age private key was saved out-of-band.

Outputs:
  - Evidence markdown under docs/evidence/ (no secrets; includes SHA256 + recipients + storage location ID)
  - Local sentinel under tmp/bootstrap/ to unblock prod Stage 1 custody gate

Notes:
  - This script does NOT copy the key anywhere (by design).
  - It will ask you to re-type the key file SHA256 to avoid “click through” mistakes.
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

list_recipients_from_identities_file() {
  local key_file="$1"
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN

  # An "age identities" file may contain multiple private keys.
  # Extract each secret key line and run age-keygen -y per key.
  grep -Eo '^AGE-SECRET-KEY-[A-Z0-9]+' "${key_file}" \
    | while IFS= read -r sk; do
        printf '%s\n' "${sk}" >"${tmp}"
        age-keygen -y "${tmp}" | tail -n 1
      done \
    | LC_ALL=C sort -u

  trap - RETURN
  rm -f "${tmp}" || true
}

DEPLOYMENT_ID=""
AGE_KEY_PATH=""
STORAGE_LOCATION=""
OPERATOR_NAME="${USER:-}"
TICKET_ID=""
EVIDENCE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id)
      DEPLOYMENT_ID="${2:-}"; shift 2;;
    --age-key-file)
      AGE_KEY_PATH="${2:-}"; shift 2;;
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

if [[ -z "${DEPLOYMENT_ID}" || -z "${AGE_KEY_PATH}" || -z "${STORAGE_LOCATION}" ]]; then
  usage
  exit 1
fi

require awk
require date
require age-keygen

if [[ "${AGE_KEY_PATH}" != /* ]]; then
  AGE_KEY_PATH="${REPO_ROOT}/${AGE_KEY_PATH}"
fi

if [[ ! -s "${AGE_KEY_PATH}" ]]; then
  echo "error: age key file not found (or empty): ${AGE_KEY_PATH}" >&2
  exit 1
fi

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
day_utc="$(date -u +%Y-%m-%d)"
sha256="$(sha256_file "${AGE_KEY_PATH}")"
bytes="$(wc -c <"${AGE_KEY_PATH}" | tr -d ' ')"
recipients="$(list_recipients_from_identities_file "${AGE_KEY_PATH}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

if [[ -z "${recipients}" ]]; then
  echo "error: failed to derive any age recipient(s) from ${AGE_KEY_PATH}" >&2
  exit 1
fi

if [[ -z "${EVIDENCE_PATH}" ]]; then
  EVIDENCE_PATH="${REPO_ROOT}/docs/evidence/${day_utc}-sops-age-key-custody-ack-${DEPLOYMENT_ID}.md"
fi
if [[ "${EVIDENCE_PATH}" != /* ]]; then
  EVIDENCE_PATH="${REPO_ROOT}/${EVIDENCE_PATH}"
fi

SENTINEL_DIR="${REPO_ROOT}/tmp/bootstrap"
SENTINEL_PATH="${SENTINEL_DIR}/sops-age-key-acked-${DEPLOYMENT_ID}"

echo ""
echo "SOPS Age key custody acknowledgement (DSB)"
echo "  deployment:   ${DEPLOYMENT_ID}"
echo "  key file:     ${AGE_KEY_PATH}"
echo "  size:         ${bytes} bytes"
echo "  sha256:       ${sha256}"
echo "  recipients:   ${recipients}"
echo "  storage:      ${STORAGE_LOCATION}"
if [[ -n "${TICKET_ID}" ]]; then
  echo "  ticket:       ${TICKET_ID}"
fi
echo ""
echo "You must now confirm:"
echo "  (1) you copied this Age key file to the out-of-band storage location above"
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
age_key_file=${AGE_KEY_PATH}
age_key_sha256=${sha256}
age_recipients=${recipients}
storage_location=${STORAGE_LOCATION}
operator=${OPERATOR_NAME}
ticket=${TICKET_ID}
EOF

cat >"${EVIDENCE_PATH}" <<EOF
# Evidence: SOPS Age key custody acknowledgement (${DEPLOYMENT_ID})

Date (UTC): \`${now_utc}\`

Purpose: operator attestation that the **deployment-scoped SOPS Age private key** used for the Deployment Secrets Bundle (DSB) was saved out-of-band.

## Credential (identified, not stored)

- Deployment: \`${DEPLOYMENT_ID}\`
- Local path (working copy): \`${AGE_KEY_PATH#${REPO_ROOT}/}\`
- SHA256: \`${sha256}\`
- Size: \`${bytes}\` bytes
- Recipient(s): \`${recipients}\`

## Custody record (out-of-band)

- Storage location: \`${STORAGE_LOCATION}\`
- Operator: \`${OPERATOR_NAME}\`
- Ticket/incident (optional): \`${TICKET_ID}\`

## Attestation

I confirm that I copied the Age key file identified above into the out-of-band storage location and verified retrieval.
EOF

chmod 600 "${SENTINEL_PATH}" || true

echo ""
echo "OK: recorded local sentinel: ${SENTINEL_PATH#${REPO_ROOT}/}"
echo "OK: wrote evidence file:      ${EVIDENCE_PATH#${REPO_ROOT}/}"
echo ""
echo "Next:"
echo "  - Commit the evidence file (recommended): git add '${EVIDENCE_PATH#${REPO_ROOT}/}' && git commit -m 'evidence: sops age key custody ack (${DEPLOYMENT_ID})'"
echo ""
