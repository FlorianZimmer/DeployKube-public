#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYMENT_ID="${DEPLOYMENT_ID:-${DEPLOYKUBE_DEPLOYMENT_ID:-}}"
if [[ -z "${DEPLOYMENT_ID}" ]]; then
  echo "missing deployment id; set DEPLOYMENT_ID or DEPLOYKUBE_DEPLOYMENT_ID" >&2
  exit 1
fi

DEPLOYMENT_DIR="${REPO_ROOT}/platform/gitops/deployments/${DEPLOYMENT_ID}"
SOPS_CONFIG_FILE="${SOPS_CONFIG_FILE:-${DEPLOYMENT_DIR}/.sops.yaml}"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/deploykube/deployments/${DEPLOYMENT_ID}/sops/age.key}"
SOPS_FILE="${SOPS_FILE:-${DEPLOYMENT_DIR}/secrets/step-ca-vault-seed.secret.sops.yaml}"

if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  echo "Age key ${AGE_KEY_FILE} not found; create it via 'age-keygen -o ${AGE_KEY_FILE}'" >&2
  exit 1
fi
if [[ ! -f "${SOPS_CONFIG_FILE}" ]]; then
  echo "SOPS config ${SOPS_CONFIG_FILE} missing" >&2
  exit 1
fi
if [[ ! -f "${SOPS_FILE}" ]]; then
  echo "SOPS file ${SOPS_FILE} missing" >&2
  exit 1
fi

tmp_sops=$(mktemp)
trap 'rm -f "${tmp_sops}"' EXIT

SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" SOPS_CONFIG="${SOPS_CONFIG_FILE}" sops -d "${SOPS_FILE}" >"${tmp_sops}"

# Re-encrypt with the current deployment-scoped SOPS config (ensures encryption rules are applied).
SOPS_CONFIG="${SOPS_CONFIG_FILE}" sops --encrypt --filename-override "secrets/step-ca-vault-seed.secret.sops.yaml" "${tmp_sops}" >"${SOPS_FILE}"

echo "rewrote ${SOPS_FILE} using ${SOPS_CONFIG_FILE}" >&2
