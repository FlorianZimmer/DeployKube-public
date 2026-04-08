#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR:-${REPO_ROOT}/platform/gitops/deployments}"

DEPLOYMENT_ID=""
PHASE=""
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NEW_KEY_FILE=""
FINALIZE_RECIPIENT=""
FINALIZE_KEY_FILE=""

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/deployments/rotate-sops.sh --deployment-id <id> --phase add [--new-key-file <path>] [--kube-context <ctx>]
  ./scripts/deployments/rotate-sops.sh --deployment-id <id> --phase finalize --recipient <age1...> --key-file <path> [--kube-context <ctx>]

Purpose:
  Two-phase SOPS Age key rotation for the Deployment Secrets Bundle (DSB).

Phase: add
  - Generates a new Age key (unless --new-key-file is provided)
  - Adds the new recipient to deployments/<id>/.sops.yaml (keeps existing recipients)
  - Rewrites all deployments/<id>/secrets/*.secret.sops.yaml using `sops updatekeys`
  - Updates in-cluster Secret argocd/argocd-sops-age with an identities file containing BOTH old + new keys

Phase: finalize
  - Sets deployments/<id>/.sops.yaml recipients to ONLY the provided --recipient
  - Rewrites all secrets via `sops updatekeys`
  - Updates argocd/argocd-sops-age to ONLY the provided --key-file identity

Important:
  - This script modifies repo files under platform/gitops/deployments/<id>/ (commit + Forgejo reseed required).
  - The Age private key files live OUTSIDE the repo (under ~/.config/deploykube/... by default).
  - After rotation, record custody acknowledgement (recommended/required for prod Stage 1):
      ./shared/scripts/sops-age-key-custody-ack.sh --deployment-id <id> --age-key-file <age.key> --storage-location '<...>'
USAGE
}

require() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: missing dependency: $cmd" >&2; exit 1; }
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

kubectl_cmd() {
  if [[ -n "${KUBE_CONTEXT}" ]]; then
    kubectl --context "${KUBE_CONTEXT}" "$@"
    return
  fi
  kubectl "$@"
}

extract_secret_key_lines() {
  # Print AGE-SECRET-KEY lines, one per line.
  local key_file="$1"
  grep -Eo '^AGE-SECRET-KEY-[A-Z0-9]+' "${key_file}" 2>/dev/null || true
}

write_unique_lines() {
  # Preserve first-seen order.
  awk '!seen[$0]++'
}

default_deployment_key_path() {
  local dep_id="$1"
  printf '%s' "${HOME}/.config/deploykube/deployments/${dep_id}/sops/age.key"
}

resolve_existing_identity_file() {
  local dep_id="$1"
  if [[ -n "${SOPS_AGE_KEY_FILE:-}" && -f "${SOPS_AGE_KEY_FILE}" ]]; then
    printf '%s' "${SOPS_AGE_KEY_FILE}"
    return
  fi
  local dep_key
  dep_key="$(default_deployment_key_path "${dep_id}")"
  if [[ -f "${dep_key}" ]]; then
    printf '%s' "${dep_key}"
    return
  fi
  local legacy="${HOME}/.config/sops/age/keys.txt"
  if [[ -f "${legacy}" ]]; then
    printf '%s' "${legacy}"
    return
  fi
  printf ''
}

derive_recipient() {
  local key_file="$1"
  age-keygen -y "${key_file}" | tail -n 1 | tr -d '[:space:]'
}

add_recipient_to_sops_config() {
  local sops_config="$1"
  local recipient="$2"
  # Add to every key_groups[].age[] list.
  yq -i "(.creation_rules[].key_groups[].age) |= ((. + [\"${recipient}\"]) | unique)" "${sops_config}"
}

set_only_recipient_in_sops_config() {
  local sops_config="$1"
  local recipient="$2"
  yq -i "(.creation_rules[].key_groups[].age) = [\"${recipient}\"]" "${sops_config}"
}

updatekeys_all() {
  local dep_dir="$1"
  local identities_file="$2"
  (cd "${dep_dir}" && SOPS_CONFIG=.sops.yaml SOPS_AGE_KEY_FILE="${identities_file}" sops updatekeys --yes secrets/*.secret.sops.yaml)
}

update_cluster_age_secret() {
  local identities_file="$1"
  require kubectl
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  kubectl_cmd -n argocd create secret generic argocd-sops-age \
    --from-file=age.key="${identities_file}" \
    --dry-run=client -o yaml >"${tmp}"
  kubectl_cmd apply -f "${tmp}" >/dev/null
  trap - RETURN
  rm -f "${tmp}" || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --kube-context) KUBE_CONTEXT="$2"; shift 2 ;;
    --new-key-file) NEW_KEY_FILE="$2"; shift 2 ;;
    --recipient) FINALIZE_RECIPIENT="$2"; shift 2 ;;
    --key-file) FINALIZE_KEY_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" || -z "${PHASE}" ]]; then
  usage
  exit 1
fi

require sops
require yq
require age-keygen
require awk

dep_dir="${DEPLOYMENTS_DIR}/${DEPLOYMENT_ID}"
secrets_dir="${dep_dir}/secrets"
sops_config="${dep_dir}/.sops.yaml"

if [[ ! -d "${dep_dir}" ]]; then
  echo "error: deployment directory missing: ${dep_dir}" >&2
  exit 1
fi
if [[ ! -d "${secrets_dir}" ]]; then
  echo "error: secrets directory missing: ${secrets_dir}" >&2
  exit 1
fi
if [[ ! -f "${sops_config}" ]]; then
  echo "error: missing deployment sops config: ${sops_config}" >&2
  exit 1
fi

if [[ "${PHASE}" == "add" ]]; then
  existing_id_file="$(resolve_existing_identity_file "${DEPLOYMENT_ID}")"
  if [[ -z "${existing_id_file}" ]]; then
    echo "error: could not find an existing age identities file (set SOPS_AGE_KEY_FILE or create ~/.config/sops/age/keys.txt)" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$(default_deployment_key_path "${DEPLOYMENT_ID}")")"

  if [[ -z "${NEW_KEY_FILE}" ]]; then
    NEW_KEY_FILE="$(default_deployment_key_path "${DEPLOYMENT_ID}").new.$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  if [[ -f "${NEW_KEY_FILE}" ]]; then
    echo "error: new key file already exists: ${NEW_KEY_FILE}" >&2
    exit 1
  fi

  echo "[rotate] generating new age key: ${NEW_KEY_FILE}" >&2
  age-keygen -o "${NEW_KEY_FILE}" >/dev/null
  chmod 600 "${NEW_KEY_FILE}" || true

  new_recipient="$(derive_recipient "${NEW_KEY_FILE}")"
  if [[ -z "${new_recipient}" ]]; then
    echo "error: failed to derive recipient from ${NEW_KEY_FILE}" >&2
    exit 1
  fi

  combined_key_file="$(default_deployment_key_path "${DEPLOYMENT_ID}")"
  tmp_combined="$(mktemp)"
  trap 'rm -f "${tmp_combined}"' RETURN

  {
    extract_secret_key_lines "${existing_id_file}"
    extract_secret_key_lines "${NEW_KEY_FILE}"
  } | write_unique_lines >"${tmp_combined}"

  if [[ ! -s "${tmp_combined}" ]]; then
    echo "error: failed to build combined identities file" >&2
    exit 1
  fi

  mv "${tmp_combined}" "${combined_key_file}"
  chmod 600 "${combined_key_file}" || true
  trap - RETURN

  echo "[rotate] added recipient to ${sops_config}: ${new_recipient}" >&2
  add_recipient_to_sops_config "${sops_config}" "${new_recipient}"

  echo "[rotate] sops updatekeys (re-encrypt metadata) for ${DEPLOYMENT_ID}" >&2
  updatekeys_all "${dep_dir}" "${combined_key_file}"

  echo "[rotate] updating in-cluster argocd/argocd-sops-age (combined identities)" >&2
  update_cluster_age_secret "${combined_key_file}"

  echo "[rotate] done (phase=add)" >&2
  echo "[rotate] new recipient: ${new_recipient}" >&2
  echo "[rotate] combined identities file: ${combined_key_file} (sha256=$(sha256_file "${combined_key_file}"))" >&2
  echo "" >&2
  echo "Next:" >&2
  echo "  1) Run lint: ./tests/scripts/validate-deployment-secrets-bundle.sh" >&2
  echo "  2) Commit repo changes + reseed Forgejo + refresh Argo." >&2
  echo "  3) Verify bootstrap consumers still decrypt successfully." >&2
  echo "  4) When ready, finalize: ./scripts/deployments/rotate-sops.sh --deployment-id ${DEPLOYMENT_ID} --phase finalize --recipient ${new_recipient} --key-file ${NEW_KEY_FILE}" >&2
  echo "  5) Record custody: ./shared/scripts/sops-age-key-custody-ack.sh --deployment-id ${DEPLOYMENT_ID} --age-key-file \"${combined_key_file}\" --storage-location '<...>'" >&2
  exit 0
fi

if [[ "${PHASE}" == "finalize" ]]; then
  if [[ -z "${FINALIZE_RECIPIENT}" || -z "${FINALIZE_KEY_FILE}" ]]; then
    echo "error: phase=finalize requires --recipient and --key-file" >&2
    exit 1
  fi
  if [[ ! -f "${FINALIZE_KEY_FILE}" ]]; then
    echo "error: key file not found: ${FINALIZE_KEY_FILE}" >&2
    exit 1
  fi

  single_key_file="$(default_deployment_key_path "${DEPLOYMENT_ID}")"
  tmp_single="$(mktemp)"
  trap 'rm -f "${tmp_single}"' RETURN

  extract_secret_key_lines "${FINALIZE_KEY_FILE}" | write_unique_lines >"${tmp_single}"
  if [[ ! -s "${tmp_single}" ]]; then
    echo "error: failed to extract secret key line(s) from ${FINALIZE_KEY_FILE}" >&2
    exit 1
  fi
  mv "${tmp_single}" "${single_key_file}"
  chmod 600 "${single_key_file}" || true
  trap - RETURN

  echo "[rotate] setting ${sops_config} to ONLY recipient: ${FINALIZE_RECIPIENT}" >&2
  set_only_recipient_in_sops_config "${sops_config}" "${FINALIZE_RECIPIENT}"

  echo "[rotate] sops updatekeys (finalize) for ${DEPLOYMENT_ID}" >&2
  updatekeys_all "${dep_dir}" "${single_key_file}"

  echo "[rotate] updating in-cluster argocd/argocd-sops-age (single identity)" >&2
  update_cluster_age_secret "${single_key_file}"

  echo "[rotate] done (phase=finalize)" >&2
  echo "[rotate] identities file: ${single_key_file} (sha256=$(sha256_file "${single_key_file}"))" >&2
  echo "" >&2
  echo "Next:" >&2
  echo "  1) Run lint: ./tests/scripts/validate-deployment-secrets-bundle.sh" >&2
  echo "  2) Commit repo changes + reseed Forgejo + refresh Argo." >&2
  echo "  3) Record custody: ./shared/scripts/sops-age-key-custody-ack.sh --deployment-id ${DEPLOYMENT_ID} --age-key-file \"${single_key_file}\" --storage-location '<...>'" >&2
  exit 0
fi

echo "error: unknown --phase: ${PHASE} (expected: add|finalize)" >&2
usage
exit 1
