#!/usr/bin/env bash
# validate-deployment-secrets-bundle.sh - Validate Deployment Secrets Bundle (DSB) layout and wiring
# Checks (per deployment under platform/gitops/deployments/<id>/):
#   1) .sops.yaml exists and declares at least one age recipient
#   2) secrets/ exists and contains required bundle files
#   3) only allowed filenames exist under secrets/
#   4) bundle/kustomization.yaml generates argocd/deploykube-deployment-secrets with a stable name
#   5) bundle file list matches secrets/ directory contents
#   6) "wrong key" detection: SOPS recipients in each bundle file are a subset of recipients in .sops.yaml
#   7) no bootstrap bundle SOPS files live under platform/gitops/components/**/secrets/
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

deployments_dir="platform/gitops/deployments"
failures=0

base_required_files=(
  "vault-init.secret.sops.yaml"
  "step-ca-vault-seed.secret.sops.yaml"
)

kms_shim_required_files=(
  "kms-shim-key.secret.sops.yaml"
  "kms-shim-token.vault-seal-system.secret.sops.yaml"
  "kms-shim-token.vault-system.secret.sops.yaml"
)

kms_shim_external_required_files=(
  "kms-shim-token.vault-system.secret.sops.yaml"
)

optional_files=(
  "minecraft-monifactory-seed.secret.sops.yaml"
)

allowed_files=(
  "${base_required_files[@]}"
  "${kms_shim_required_files[@]}"
  "${optional_files[@]}"
)

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require yq
require rg

echo "==> Validating Deployment Secrets Bundles under ${deployments_dir}"

mapfile -t deployment_dirs < <(
  find "${deployments_dir}" -maxdepth 1 -mindepth 1 -type d ! -name examples | sort
)

if [ "${#deployment_dirs[@]}" -eq 0 ]; then
  echo "error: no deployments found under ${deployments_dir}" >&2
  exit 1
fi

array_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

unique_sorted_lines() {
  # Reads lines from stdin, outputs unique sorted lines.
  LC_ALL=C sort -u
}

get_deployment_recipients() {
  local sops_config="$1"
  # Print all configured age recipients (unique, one per line).
  # Shape: creation_rules[].key_groups[].age[] = "<recipient>"
  yq -r '.creation_rules[].key_groups[].age[]' "${sops_config}" 2>/dev/null | rg -v '^null$' | unique_sorted_lines
}

get_file_recipients() {
  local file="$1"
  # Print recipients in file's SOPS metadata (unique, one per line).
  yq -r '.sops.age[].recipient' "${file}" 2>/dev/null | rg -v '^null$' | unique_sorted_lines
}

is_trueish() {
  local v="$1"
  [[ "${v}" == "true" || "${v}" == "\"true\"" ]]
}

fail_placeholder_secret_manifest() {
  local file="$1"
  local v
  v="$(yq -r '.metadata.labels["darksite.cloud/placeholder"] // ""' "${file}" 2>/dev/null || true)"
  if is_trueish "${v}"; then
    echo "  FAIL: required DSB secret is still a placeholder (metadata.labels.darksite.cloud/placeholder=true): ${file}" >&2
    return 1
  fi
  return 0
}

fail_placeholder_step_ca_seed() {
  local file="$1"
  local v
  v="$(yq -r '.["darksite.cloud/placeholder"] // ""' "${file}" 2>/dev/null || true)"
  if [[ -n "${v}" && "${v}" != "null" ]]; then
    echo "  FAIL: required Step CA seed bundle file is still a placeholder (darksite.cloud/placeholder present): ${file}" >&2
    return 1
  fi
  return 0
}

require_secret_field() {
  local file="$1"
  local field="$2"
  local v
  v="$(yq -r "${field} // \"\"" "${file}" 2>/dev/null || true)"
  if [[ -z "${v}" || "${v}" == "null" ]]; then
    echo "  FAIL: ${file} missing required field: ${field}" >&2
    return 1
  fi
  return 0
}

require_secret_key() {
  local file="$1"
  local key="$2"
  local v
  v="$(
    yq -r ".stringData.\"${key}\" // .data.\"${key}\" // \"\"" "${file}" 2>/dev/null || true
  )"
  if [[ -z "${v}" || "${v}" == "null" ]]; then
    echo "  FAIL: ${file} missing required key '${key}' under stringData/data" >&2
    return 1
  fi
  return 0
}

validate_required_secret_manifest() {
  local file="$1"
  local expected_name="$2"
  local expected_namespace="$3"
  shift 3
  local required_keys=("$@")

  local errors=0

  fail_placeholder_secret_manifest "${file}" || errors=$((errors + 1))
  require_secret_field "${file}" '.kind' || errors=$((errors + 1))
  local kind
  kind="$(yq -r '.kind // ""' "${file}" 2>/dev/null || true)"
  if [[ "${kind}" != "Secret" ]]; then
    echo "  FAIL: ${file} must be kind=Secret (got '${kind}')" >&2
    errors=$((errors + 1))
  fi

  local name ns
  name="$(yq -r '.metadata.name // ""' "${file}" 2>/dev/null || true)"
  ns="$(yq -r '.metadata.namespace // ""' "${file}" 2>/dev/null || true)"
  if [[ "${name}" != "${expected_name}" ]]; then
    echo "  FAIL: ${file} must set metadata.name='${expected_name}' (got '${name}')" >&2
    errors=$((errors + 1))
  fi
  if [[ "${ns}" != "${expected_namespace}" ]]; then
    echo "  FAIL: ${file} must set metadata.namespace='${expected_namespace}' (got '${ns}')" >&2
    errors=$((errors + 1))
  fi

  local k
  for k in "${required_keys[@]}"; do
    require_secret_key "${file}" "${k}" || errors=$((errors + 1))
  done

  return "${errors}"
}

validate_required_step_ca_seed_manifest() {
  local file="$1"
  local errors=0

  fail_placeholder_step_ca_seed "${file}" || errors=$((errors + 1))

  local required_keys=(
    "ca_json"
    "defaults_json"
    "x509_leaf_tpl"
    "root_ca_crt"
    "intermediate_ca_crt"
    "root_ca_key"
    "intermediate_ca_key"
    "ca_password"
    "provisioner_password"
  )

  local k
  for k in "${required_keys[@]}"; do
    require_secret_field "${file}" ".\"${k}\"" || errors=$((errors + 1))
  done

  return "${errors}"
}

validate_deployment() {
  local dep_dir="$1"
  local dep_id
  dep_id="$(basename "${dep_dir}")"

  local errors=0
  echo ""
  echo "==> Deployment: ${dep_id}"

  local config_yaml="${dep_dir}/config.yaml"
  if [[ ! -f "${config_yaml}" ]]; then
    echo "  SKIP: ${config_yaml} missing (not a DeploymentConfig directory)"
    return 0
  fi

  local rot_provider
  rot_provider="$(yq -r '.spec.secrets.rootOfTrust.provider // ""' "${config_yaml}" 2>/dev/null || true)"
  if [[ -z "${rot_provider}" || "${rot_provider}" == "null" ]]; then
    echo "  FAIL: ${config_yaml} missing spec.secrets.rootOfTrust.provider" >&2
    errors=$((errors + 1))
    rot_provider=""
  elif [[ ! "${rot_provider}" =~ ^(kmsShim)$ ]]; then
    echo "  FAIL: ${config_yaml} invalid spec.secrets.rootOfTrust.provider='${rot_provider}' (want kmsShim)" >&2
    errors=$((errors + 1))
    rot_provider=""
  fi

  local rot_mode
  rot_mode="$(yq -r '.spec.secrets.rootOfTrust.mode // ""' "${config_yaml}" 2>/dev/null || true)"
  if [[ -z "${rot_mode}" || "${rot_mode}" == "null" ]]; then
    echo "  FAIL: ${config_yaml} missing spec.secrets.rootOfTrust.mode" >&2
    errors=$((errors + 1))
    rot_mode=""
  elif [[ ! "${rot_mode}" =~ ^(inCluster|external)$ ]]; then
    echo "  FAIL: ${config_yaml} invalid spec.secrets.rootOfTrust.mode='${rot_mode}' (want inCluster|external)" >&2
    errors=$((errors + 1))
    rot_mode=""
  fi

  local sops_yaml="${dep_dir}/.sops.yaml"
  if [[ ! -f "${sops_yaml}" ]]; then
    echo "  FAIL: ${sops_yaml} missing" >&2
    errors=$((errors + 1))
  fi

  local secrets_dir="${dep_dir}/secrets"
  if [[ ! -d "${secrets_dir}" ]]; then
    echo "  FAIL: ${secrets_dir} missing" >&2
    errors=$((errors + 1))
  fi

  if [[ -f "${sops_yaml}" ]]; then
    local recipients
    recipients="$(get_deployment_recipients "${sops_yaml}" || true)"
    if [[ -z "${recipients}" ]]; then
      echo "  FAIL: ${sops_yaml} declares no age recipients" >&2
      errors=$((errors + 1))
    fi
  fi

  if [[ -d "${secrets_dir}" ]]; then
    local required_files=("${base_required_files[@]}")
    if [[ "${rot_mode}" == "external" ]]; then
      required_files+=("${kms_shim_external_required_files[@]}")
    else
      required_files+=("${kms_shim_required_files[@]}")
    fi

    local req
    for req in "${required_files[@]}"; do
      if [[ ! -f "${secrets_dir}/${req}" ]]; then
        echo "  FAIL: missing required bundle file: ${secrets_dir}/${req}" >&2
        errors=$((errors + 1))
      fi
    done

    # Fail fast if required bundle files are still placeholders (repo-only detection; no decryption).
    if [[ -f "${secrets_dir}/vault-init.secret.sops.yaml" ]]; then
      if ! validate_required_secret_manifest "${secrets_dir}/vault-init.secret.sops.yaml" "vault-init" "vault-system" \
        "root-token" "recovery-key" "bootstrap-notes"; then
        errors=$((errors + 1))
      fi
    fi

    if [[ -f "${secrets_dir}/kms-shim-key.secret.sops.yaml" ]]; then
      if ! validate_required_secret_manifest "${secrets_dir}/kms-shim-key.secret.sops.yaml" "kms-shim-key" "vault-seal-system" \
        "age.key"; then
        errors=$((errors + 1))
      fi
    fi
    if [[ -f "${secrets_dir}/kms-shim-token.vault-seal-system.secret.sops.yaml" ]]; then
      if ! validate_required_secret_manifest "${secrets_dir}/kms-shim-token.vault-seal-system.secret.sops.yaml" "kms-shim-token" "vault-seal-system" \
        "token"; then
        errors=$((errors + 1))
      fi
    fi
    if [[ -f "${secrets_dir}/kms-shim-token.vault-system.secret.sops.yaml" ]]; then
      if ! validate_required_secret_manifest "${secrets_dir}/kms-shim-token.vault-system.secret.sops.yaml" "kms-shim-token" "vault-system" \
        "token"; then
        errors=$((errors + 1))
      fi
    fi

    if [[ -f "${secrets_dir}/step-ca-vault-seed.secret.sops.yaml" ]]; then
      if ! validate_required_step_ca_seed_manifest "${secrets_dir}/step-ca-vault-seed.secret.sops.yaml"; then
        errors=$((errors + 1))
      fi
    fi

    # Validate filenames and conventions
    local file
    while IFS= read -r -d '' file; do
      local base
      base="$(basename "${file}")"
      if [[ "${base}" != *.secret.sops.yaml ]]; then
        echo "  FAIL: invalid bundle filename (must end with .secret.sops.yaml): ${file}" >&2
        errors=$((errors + 1))
        continue
      fi
      if ! array_contains "${base}" "${allowed_files[@]}"; then
        echo "  FAIL: unexpected bundle file under secrets/: ${file}" >&2
        errors=$((errors + 1))
      fi
    done < <(find "${secrets_dir}" -maxdepth 1 -type f -print0)
  fi

  local bundle_kustomization="${dep_dir}/kustomization.yaml"
  if [[ ! -f "${bundle_kustomization}" ]]; then
    echo "  FAIL: ${bundle_kustomization} missing" >&2
    errors=$((errors + 1))
  else
    local ns
    ns="$(yq -r '.namespace // ""' "${bundle_kustomization}")"
    if [[ "${ns}" != "argocd" ]]; then
      echo "  FAIL: ${bundle_kustomization} must set namespace: argocd (got '${ns}')" >&2
      errors=$((errors + 1))
    fi

    local stable
    stable="$(yq -r '.generatorOptions.disableNameSuffixHash // false' "${bundle_kustomization}")"
    if [[ "${stable}" != "true" ]]; then
      echo "  FAIL: ${bundle_kustomization} must set generatorOptions.disableNameSuffixHash: true" >&2
      errors=$((errors + 1))
    fi

    local cm_count
    cm_count="$(yq -r '.configMapGenerator[] | select(.name == "deploykube-deployment-secrets") | .name' "${bundle_kustomization}" 2>/dev/null | rg -v '^null$' | wc -l | tr -d ' ')"
    if [[ "${cm_count}" != "1" ]]; then
      echo "  FAIL: ${bundle_kustomization} must define exactly one configMapGenerator named deploykube-deployment-secrets" >&2
      errors=$((errors + 1))
    fi

    local res_cfg
    res_cfg="$(yq -r '.resources[]? | select(. == "config.yaml")' "${bundle_kustomization}" 2>/dev/null | rg -v '^null$' | wc -l | tr -d ' ')"
    if [[ "${res_cfg}" != "1" ]]; then
      echo "  FAIL: ${bundle_kustomization} must include exactly one resource: config.yaml (DeploymentConfig CR)" >&2
      errors=$((errors + 1))
    fi

    if [[ -d "${secrets_dir}" ]]; then
      local expected_files actual_files
      expected_files="$(find "${secrets_dir}" -maxdepth 1 -type f -print | sed 's|.*/||' | unique_sorted_lines)"
      actual_files="$(
        yq -r '.configMapGenerator[] | select(.name == "deploykube-deployment-secrets") | .files[]' "${bundle_kustomization}" 2>/dev/null \
          | sed -E 's/^([^=]+)=.*$/\1/' \
          | unique_sorted_lines
      )"
      if [[ "${expected_files}" != "${actual_files}" ]]; then
        echo "  FAIL: bundle file list mismatch in ${bundle_kustomization}" >&2
        echo "        expected (from secrets/):" >&2
        printf '%s\n' "${expected_files}" | sed 's/^/          - /' >&2
        echo "        actual (from kustomization.yaml):" >&2
        printf '%s\n' "${actual_files}" | sed 's/^/          - /' >&2
        errors=$((errors + 1))
      fi
    fi
  fi

  # Wrong-key detection
  if [[ -f "${sops_yaml}" && -d "${secrets_dir}" ]]; then
    local configured
    configured="$(get_deployment_recipients "${sops_yaml}" || true)"
    local secret
    while IFS= read -r -d '' secret; do
      local base
      base="$(basename "${secret}")"
      local file_recipients
      file_recipients="$(get_file_recipients "${secret}" || true)"
      if [[ -z "${file_recipients}" ]]; then
        echo "  FAIL: ${secret} missing .sops.age[].recipient metadata (not a valid SOPS file?)" >&2
        errors=$((errors + 1))
        continue
      fi
      local r
      while IFS= read -r r; do
        [[ -z "${r}" ]] && continue
        if ! rg -q -x --fixed-strings "${r}" <<<"${configured}"; then
          echo "  FAIL: ${secret} encrypted for recipient ${r}, which is not present in ${sops_yaml}" >&2
          errors=$((errors + 1))
        fi
      done <<<"${file_recipients}"
    done < <(find "${secrets_dir}" -maxdepth 1 -type f -name '*.secret.sops.yaml' -print0)
  fi

  if [[ "${errors}" -eq 0 ]]; then
    echo "  PASS"
  fi

  return "${errors}"
}

for dep_dir in "${deployment_dirs[@]}"; do
  if ! validate_deployment "${dep_dir}"; then
    failures=$((failures + 1))
  fi
done

  echo ""
  echo "==> Lint: no bundle secrets under platform/gitops/components/**/secrets/"
mapfile -t legacy_bundle_files < <(find platform/gitops/components -type f -path '*/secrets/*.secret.sops.yaml' | sort)
if [[ "${#legacy_bundle_files[@]}" -gt 0 ]]; then
  echo "  FAIL: found .secret.sops.yaml files under platform/gitops/components/**/secrets/ (must live under deployments/**/secrets/)" >&2
  printf '%s\n' "${legacy_bundle_files[@]}" | sed 's/^/  - /' >&2
  failures=$((failures + 1))
else
  echo "  PASS"
fi

echo ""
if [ "${failures}" -ne 0 ]; then
  echo "deployment secrets bundle validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "deployment secrets bundle validation PASSED"
