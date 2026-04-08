#!/bin/sh
set -euo pipefail

if ! command -v sops >/dev/null 2>&1; then
  echo "sops missing from bootstrap tools image; add it to shared/images/bootstrap-tools/Dockerfile" >&2
  exit 1
fi

if [ -z "${SOPS_AGE_KEY_FILE:-}" ] || [ ! -f "${SOPS_AGE_KEY_FILE}" ]; then
  echo "SOPS_AGE_KEY_FILE must point to a readable Age private key before running secrets-bootstrap" >&2
  exit 1
fi
export SOPS_AGE_KEY_FILE

wait_for_namespace() {
  local namespace="$1"
  local max_attempts="${2:-30}"
  local delay="${3:-5}"
  local attempt=0
  until kubectl get namespace "${namespace}" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      echo "namespace ${namespace} not found after ${max_attempts} checks" >&2
      exit 1
    fi
    echo "waiting for namespace ${namespace} (attempt ${attempt}/${max_attempts})"
    sleep "${delay}"
  done
}

is_placeholder_secret() {
  # Decrypted Kubernetes Secret manifest.
  # Convention: metadata.labels.darksite.cloud/placeholder=true
  local decrypted="$1"
  if command -v yq >/dev/null 2>&1; then
    val="$(yq -r '.metadata.labels["darksite.cloud/placeholder"] // ""' "${decrypted}" 2>/dev/null || true)"
    if [ "${val}" = "true" ] || [ "${val}" = "\"true\"" ]; then
      return 0
    fi
    return 1
  fi
  if grep -Eq 'darksite\.cloud/placeholder:[[:space:]]*(true|"true")([[:space:]]|$)' "${decrypted}"; then
    return 0
  fi
  return 1
}

apply_secret() {
  local namespace="$1"
  local file="$2"
  local required="${3:-false}"
  if [ ! -s "${file}" ]; then
    if [ "${required}" = "true" ]; then
      echo "required secret bundle file missing or empty: ${file}" >&2
      exit 1
    fi
    echo "skipping ${file} (missing or empty)"
    return 0
  fi
  echo "applying secret from ${file} into ${namespace}"
  local tmp_decrypted tmp_err
  tmp_decrypted="$(mktemp)"
  tmp_err="$(mktemp)"
  if sops -d "${file}" >"${tmp_decrypted}" 2>"${tmp_err}"; then
    if is_placeholder_secret "${tmp_decrypted}"; then
      echo "refusing to apply placeholder secret from ${file} (darksite.cloud/placeholder=true)" >&2
      exit 1
    fi
    kubectl apply -n "${namespace}" -f "${tmp_decrypted}"
    rm -f "${tmp_decrypted}" "${tmp_err}"
    return 0
  fi
  if grep -q "metadata not found" "${tmp_err}" 2>/dev/null; then
    echo "sops metadata missing for ${file}; applying plaintext"
    kubectl apply -n "${namespace}" -f "${file}"
    rm -f "${tmp_decrypted}" "${tmp_err}"
    return 0
  fi
  echo "failed to decrypt ${file}:" >&2
  cat "${tmp_err}" >&2 || true
  rm -f "${tmp_decrypted}" "${tmp_err}" || true
  exit 1
}

apply_secret_with_stringdata() {
  local namespace="$1"
  local file="$2"
  local key="$3"
  local value="$4"
  local required="${5:-false}"

  if [ ! -s "${file}" ]; then
    if [ "${required}" = "true" ]; then
      echo "required secret bundle file missing or empty: ${file}" >&2
      exit 1
    fi
    echo "skipping ${file} (missing or empty)"
    return 0
  fi
  if ! command -v yq >/dev/null 2>&1; then
    echo "yq is required to patch ${file} with ${key} for ${namespace}" >&2
    exit 1
  fi

  echo "applying secret from ${file} into ${namespace} (injecting stringData.${key})"
  local tmp_decrypted tmp_err
  tmp_decrypted="$(mktemp)"
  tmp_err="$(mktemp)"
  if sops -d "${file}" >"${tmp_decrypted}" 2>"${tmp_err}"; then
    if is_placeholder_secret "${tmp_decrypted}"; then
      echo "refusing to apply placeholder secret from ${file} (darksite.cloud/placeholder=true)" >&2
      exit 1
    fi
    DK_PATCH_VALUE="${value}" yq -i ".stringData.\"${key}\" = strenv(DK_PATCH_VALUE)" "${tmp_decrypted}"
    kubectl apply -n "${namespace}" -f "${tmp_decrypted}"
    rm -f "${tmp_decrypted}" "${tmp_err}"
    return 0
  fi
  if grep -q "metadata not found" "${tmp_err}" 2>/dev/null; then
    echo "sops metadata missing for ${file}; applying plaintext (patched)"
    cp "${file}" "${tmp_decrypted}"
    if is_placeholder_secret "${tmp_decrypted}"; then
      echo "refusing to apply placeholder secret from ${file} (darksite.cloud/placeholder=true)" >&2
      exit 1
    fi
    DK_PATCH_VALUE="${value}" yq -i ".stringData.\"${key}\" = strenv(DK_PATCH_VALUE)" "${tmp_decrypted}"
    kubectl apply -n "${namespace}" -f "${tmp_decrypted}"
    rm -f "${tmp_decrypted}" "${tmp_err}"
    return 0
  fi
  echo "failed to decrypt ${file}:" >&2
  cat "${tmp_err}" >&2 || true
  rm -f "${tmp_decrypted}" "${tmp_err}" || true
  exit 1
}

remove_secret_data_key_if_present() {
  local namespace="$1"
  local name="$2"
  local key="$3"
  kubectl -n "${namespace}" patch secret "${name}" --type json -p "[{\"op\":\"remove\",\"path\":\"/data/${key}\"}]" >/dev/null 2>&1 || true
}

DEPLOYMENT_CONFIG="/deployment-config/deployment-config.yaml"
ROOT_OF_TRUST_PROVIDER="kmsShim"
ROOT_OF_TRUST_MODE="inCluster"
ROOT_OF_TRUST_EXTERNAL_ADDR=""
if [ -f "${DEPLOYMENT_CONFIG}" ] && command -v yq >/dev/null 2>&1; then
  ROOT_OF_TRUST_PROVIDER="$(yq -r '.spec.secrets.rootOfTrust.provider // "kmsShim"' "${DEPLOYMENT_CONFIG}" 2>/dev/null || echo "kmsShim")"
  ROOT_OF_TRUST_MODE="$(yq -r '.spec.secrets.rootOfTrust.mode // "inCluster"' "${DEPLOYMENT_CONFIG}" 2>/dev/null || echo "inCluster")"
  ROOT_OF_TRUST_EXTERNAL_ADDR="$(yq -r '.spec.secrets.rootOfTrust.external.address // ""' "${DEPLOYMENT_CONFIG}" 2>/dev/null || echo "")"
fi
case "${ROOT_OF_TRUST_PROVIDER}" in
  kmsShim) ;;
  *)
    echo "invalid spec.secrets.rootOfTrust.provider (want kmsShim): ${ROOT_OF_TRUST_PROVIDER}" >&2
    exit 1
    ;;
esac
case "${ROOT_OF_TRUST_MODE}" in
  inCluster|external) ;;
  *)
    echo "invalid spec.secrets.rootOfTrust.mode (want inCluster|external): ${ROOT_OF_TRUST_MODE}" >&2
    exit 1
    ;;
esac
echo "root-of-trust: provider=${ROOT_OF_TRUST_PROVIDER} mode=${ROOT_OF_TRUST_MODE}"

wait_for_namespace vault-system
apply_secret vault-system /config/vault-init.secret.sops.yaml true

if [ "${ROOT_OF_TRUST_MODE}" = "inCluster" ]; then
  wait_for_namespace vault-seal-system
  apply_secret vault-seal-system /config/kms-shim-key.secret.sops.yaml true
  apply_secret vault-seal-system /config/kms-shim-token.vault-seal-system.secret.sops.yaml true
  apply_secret vault-system /config/kms-shim-token.vault-system.secret.sops.yaml true
  # If the cluster previously ran external root-of-trust mode, remove stale
  # Secret.data.address so Vault does not keep using the old external endpoint.
  remove_secret_data_key_if_present vault-system kms-shim-token address
else
  if [ -z "${ROOT_OF_TRUST_EXTERNAL_ADDR}" ]; then
    echo "spec.secrets.rootOfTrust.external.address is required for provider=kmsShim mode=external" >&2
    exit 1
  fi
  apply_secret_with_stringdata vault-system /config/kms-shim-token.vault-system.secret.sops.yaml "address" "${ROOT_OF_TRUST_EXTERNAL_ADDR}" true
fi

apply_secret vault-system /config/minecraft-monifactory-seed.secret.sops.yaml false
