#!/usr/bin/env bash
# validate-security-scanning-contract.sh
# Fast contract checks for the centralized Trivy CI plane.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

require_cmd jq
require_cmd rg
require_cmd yq

inventory_file="tests/trivy/central-ci-inventory.yaml"
workflow_file=".github/workflows/security-scanning.yml"
wrapper_file="tests/scripts/scan-cert-manager-images.sh"
resolver_file="tests/scripts/resolve-trivy-ci-targets.sh"
package_index_file="platform/gitops/artifacts/package-index.yaml"
runtime_artifact_index_file="platform/gitops/artifacts/runtime-artifact-index.yaml"

if [[ ! -f "${inventory_file}" ]]; then
  echo "error: missing ${inventory_file}" >&2
  exit 1
fi
if [[ ! -f "${workflow_file}" ]]; then
  echo "error: missing ${workflow_file}" >&2
  exit 1
fi
if [[ ! -f "${package_index_file}" ]]; then
  echo "error: missing ${package_index_file}" >&2
  exit 1
fi
if [[ ! -f "${runtime_artifact_index_file}" ]]; then
  echo "error: missing ${runtime_artifact_index_file}" >&2
  exit 1
fi

workflow_covers_path() {
  local watch_path="$1"
  local workflow_path

  for workflow_path in "${workflow_paths[@]}"; do
    if [[ "${workflow_path}" == "${watch_path}" ]]; then
      return 0
    fi
    if [[ "${workflow_path}" == */** ]]; then
      local base="${workflow_path%/**}"
      if [[ "${watch_path}" == "${base}" || "${watch_path}" == "${base}/"* ]]; then
        return 0
      fi
    fi
  done

  return 1
}

tmpdir="$(mktemp -d "${root_dir}/tmp/validate-security-scanning.XXXXXX")"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT INT TERM

echo "==> Resolving centralized CI components and aggregate profile"
./tests/scripts/scan-trivy-ci.sh --component argocd --resolve-only --output-dir "${tmpdir}/argocd" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component cert-manager --resolve-only --output-dir "${tmpdir}/cert-manager" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component dns --resolve-only --output-dir "${tmpdir}/dns" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component external-secrets --resolve-only --output-dir "${tmpdir}/external-secrets" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component forgejo --resolve-only --output-dir "${tmpdir}/forgejo" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component garage --resolve-only --output-dir "${tmpdir}/garage" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component harbor --resolve-only --output-dir "${tmpdir}/harbor" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component istio --resolve-only --output-dir "${tmpdir}/istio" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component keycloak --resolve-only --output-dir "${tmpdir}/keycloak" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component kyverno --resolve-only --output-dir "${tmpdir}/kyverno" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component metallb --resolve-only --output-dir "${tmpdir}/metallb" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component nfs-provisioner --resolve-only --output-dir "${tmpdir}/nfs-provisioner" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component observability --resolve-only --output-dir "${tmpdir}/observability" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component platform-artifacts --resolve-only --output-dir "${tmpdir}/platform-artifacts" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component postgres --resolve-only --output-dir "${tmpdir}/postgres" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component step-ca --resolve-only --output-dir "${tmpdir}/step-ca" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component valkey --resolve-only --output-dir "${tmpdir}/valkey" >/dev/null
./tests/scripts/scan-trivy-ci.sh --component vault --resolve-only --output-dir "${tmpdir}/vault" >/dev/null
./tests/scripts/scan-trivy-ci.sh --profile platform-core --resolve-only --output-dir "${tmpdir}/platform-core" >/dev/null
./tests/scripts/scan-trivy-ci.sh --profile platform-foundations --resolve-only --output-dir "${tmpdir}/platform-foundations" >/dev/null
./tests/scripts/scan-trivy-ci.sh --profile platform-services --resolve-only --output-dir "${tmpdir}/platform-services" >/dev/null

mapfile -t workflow_paths < <(yq -r '.on.pull_request.paths[]?' "${workflow_file}")
if [[ "${#workflow_paths[@]}" -eq 0 ]]; then
  echo "error: ${workflow_file} is missing pull_request.paths entries" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 5) and ((.config_targets | length) == 1)' "${tmpdir}/argocd/resolved-targets.json" >/dev/null; then
  echo "error: argocd component should resolve 5 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 6)' "${tmpdir}/cert-manager/resolved-targets.json" >/dev/null; then
  echo "error: cert-manager component should resolve 6 image targets" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 3) and ((.config_targets | length) == 3)' "${tmpdir}/dns/resolved-targets.json" >/dev/null; then
  echo "error: dns component should resolve 3 image targets and 3 config targets" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 1) and ((.config_targets | length) == 1)' "${tmpdir}/external-secrets/resolved-targets.json" >/dev/null; then
  echo "error: external-secrets component should resolve 1 image target and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 2) and ((.config_targets | length) == 1)' "${tmpdir}/forgejo/resolved-targets.json" >/dev/null; then
  echo "error: forgejo component should resolve 2 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 1) and ((.config_targets | length) == 1)' "${tmpdir}/garage/resolved-targets.json" >/dev/null; then
  echo "error: garage component should resolve 1 image target and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 7) and ((.config_targets | length) == 1)' "${tmpdir}/harbor/resolved-targets.json" >/dev/null; then
  echo "error: harbor component should resolve 7 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 4) and ((.config_targets | length) == 1)' "${tmpdir}/istio/resolved-targets.json" >/dev/null; then
  echo "error: istio component should resolve 4 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 5) and ((.config_targets | length) == 1)' "${tmpdir}/kyverno/resolved-targets.json" >/dev/null; then
  echo "error: kyverno component should resolve 5 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 3) and ((.config_targets | length) == 1)' "${tmpdir}/metallb/resolved-targets.json" >/dev/null; then
  echo "error: metallb component should resolve 3 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 1) and ((.config_targets | length) == 1)' "${tmpdir}/nfs-provisioner/resolved-targets.json" >/dev/null; then
  echo "error: nfs-provisioner component should resolve 1 image target and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 3)' "${tmpdir}/platform-artifacts/resolved-targets.json" >/dev/null; then
  echo "error: platform-artifacts component should resolve 3 image targets" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 3) and ((.config_targets | length) == 1)' "${tmpdir}/keycloak/resolved-targets.json" >/dev/null; then
  echo "error: keycloak component should resolve 3 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 8) and ((.config_targets | length) == 1)' "${tmpdir}/observability/resolved-targets.json" >/dev/null; then
  echo "error: observability component should resolve 8 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 2) and ((.config_targets | length) == 1)' "${tmpdir}/postgres/resolved-targets.json" >/dev/null; then
  echo "error: postgres component should resolve 2 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 1) and ((.config_targets | length) == 1)' "${tmpdir}/step-ca/resolved-targets.json" >/dev/null; then
  echo "error: step-ca component should resolve 1 image target and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 1) and ((.config_targets | length) == 1)' "${tmpdir}/valkey/resolved-targets.json" >/dev/null; then
  echo "error: valkey component should resolve 1 image target and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "component") and ((.image_targets | length) == 2) and ((.config_targets | length) == 1)' "${tmpdir}/vault/resolved-targets.json" >/dev/null; then
  echo "error: vault component should resolve 2 image targets and 1 config target" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "profile") and ((.included_components | length) == 5)' "${tmpdir}/platform-core/resolved-targets.json" >/dev/null; then
  echo "error: platform-core profile should compose 5 components" >&2
  exit 1
fi

if ! jq -e '.image_targets | length == 23' "${tmpdir}/platform-core/resolved-targets.json" >/dev/null; then
  echo "error: platform-core profile should resolve 23 image targets" >&2
  exit 1
fi

if ! jq -e '.config_targets | length == 4' "${tmpdir}/platform-core/resolved-targets.json" >/dev/null; then
  echo "error: platform-core profile should resolve 4 config targets" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "profile") and ((.included_components | length) == 9)' "${tmpdir}/platform-foundations/resolved-targets.json" >/dev/null; then
  echo "error: platform-foundations profile should compose 9 components" >&2
  exit 1
fi

if ! jq -e '.image_targets | length == 24' "${tmpdir}/platform-foundations/resolved-targets.json" >/dev/null; then
  echo "error: platform-foundations profile should resolve 24 image targets" >&2
  exit 1
fi

if ! jq -e '.config_targets | length == 11' "${tmpdir}/platform-foundations/resolved-targets.json" >/dev/null; then
  echo "error: platform-foundations profile should resolve 11 config targets" >&2
  exit 1
fi

if ! jq -e '(.selection_mode == "profile") and ((.included_components | length) == 4)' "${tmpdir}/platform-services/resolved-targets.json" >/dev/null; then
  echo "error: platform-services profile should compose 4 components" >&2
  exit 1
fi

if ! jq -e '.image_targets | length == 11' "${tmpdir}/platform-services/resolved-targets.json" >/dev/null; then
  echo "error: platform-services profile should resolve 11 image targets" >&2
  exit 1
fi

if ! jq -e '.config_targets | length == 4' "${tmpdir}/platform-services/resolved-targets.json" >/dev/null; then
  echo "error: platform-services profile should resolve 4 config targets" >&2
  exit 1
fi

echo "==> Verifying PR target resolution"
pr_matrix="$(./tests/scripts/resolve-trivy-ci-targets.sh \
  --event-name pull_request \
  --changed-file platform/gitops/components/certificates/cert-manager/helm/values.yaml)"
jq -e 'type == "array" and length == 1 and .[0].mode == "component" and .[0].target == "cert-manager"' <<<"${pr_matrix}" >/dev/null

shared_pr_matrix="$(./tests/scripts/resolve-trivy-ci-targets.sh \
  --event-name pull_request \
  --changed-file tests/scripts/scan-trivy-ci.sh)"
jq -e 'type == "array" and length == 18' <<<"${shared_pr_matrix}" >/dev/null

default_profile_matrix="$(./tests/scripts/resolve-trivy-ci-targets.sh \
  --event-name push \
  --mode profile \
  --target __default__)"
jq -e 'type == "array" and length == 3 and any(.[]; .target == "platform-core") and any(.[]; .target == "platform-services") and any(.[]; .target == "platform-foundations")' <<<"${default_profile_matrix}" >/dev/null

echo "==> Verifying workflow path coverage for shared and component watch paths"
mapfile -t shared_watch_paths < <(yq -r '.shared_watch_paths[]?' "${inventory_file}")
for watch_path in "${shared_watch_paths[@]}"; do
  if ! workflow_covers_path "${watch_path}"; then
    echo "error: ${workflow_file} pull_request.paths does not cover shared watch path '${watch_path}'" >&2
    exit 1
  fi
done

mapfile -t component_names < <(yq -r '.components | keys[]' "${inventory_file}")
for component_name in "${component_names[@]}"; do
  component_file="$(yq -r ".components.\"${component_name}\".file" "${inventory_file}")"
  if ! workflow_covers_path "${component_file}"; then
    echo "error: ${workflow_file} pull_request.paths does not cover component file '${component_file}'" >&2
    exit 1
  fi

  mapfile -t component_watch_paths < <(yq -r '.watch_paths[]?' "${component_file}")
  for watch_path in "${component_watch_paths[@]}"; do
    if ! workflow_covers_path "${watch_path}"; then
      echo "error: ${workflow_file} pull_request.paths does not cover watch path '${watch_path}' from component '${component_name}'" >&2
      exit 1
    fi
  done
done

echo "==> Verifying package-index artifact coverage in the default aggregate set"
default_profile_refs_file="${tmpdir}/default-profile-refs.txt"
for profile_name in $(jq -r '.[].target' <<<"${default_profile_matrix}"); do
  ./tests/scripts/scan-trivy-ci.sh --profile "${profile_name}" --resolve-only --output-dir "${tmpdir}/${profile_name}-default-coverage" >/dev/null
  jq -r '.image_targets[]?.ref' "${tmpdir}/${profile_name}-default-coverage/resolved-targets.json"
done | sort -u > "${default_profile_refs_file}"

while IFS= read -r package_ref; do
  [[ -z "${package_ref}" ]] && continue
  if ! rg -n -q -F -- "${package_ref}" "${default_profile_refs_file}"; then
    echo "error: package-index image '${package_ref}' is not covered by the default centralized Trivy profile set" >&2
    exit 1
  fi
done < <(yq -r '.spec.images[]?.source' "${package_index_file}")

while IFS= read -r runtime_ref; do
  [[ -z "${runtime_ref}" ]] && continue
  if ! rg -n -q -F -- "${runtime_ref}" "${default_profile_refs_file}"; then
    echo "error: runtime-artifact-index image '${runtime_ref}' is not covered by the default centralized Trivy profile set" >&2
    exit 1
  fi
done < <(
  runtime_ref_field="$(yq -r '.artifact_catalogs."runtime-artifacts".ref_field // "distribution_ref"' "${inventory_file}")"
  yq -r ".spec.images[]?.${runtime_ref_field}" "${runtime_artifact_index_file}"
)

echo "==> Verifying central workflow and wrapper wiring"
rg -n --fixed-strings "./tests/scripts/scan-trivy-ci.sh" "${workflow_file}" >/dev/null
rg -n --fixed-strings "./tests/scripts/resolve-trivy-ci-targets.sh" "${workflow_file}" >/dev/null
rg -n --fixed-strings "./tests/scripts/publish-trivy-ci-metrics.sh" "${workflow_file}" >/dev/null
rg -n --fixed-strings "./tests/scripts/scan-trivy-ci.sh" "${wrapper_file}" >/dev/null
rg -n --fixed-strings -- "--component cert-manager" "${wrapper_file}" >/dev/null
rg -n --fixed-strings "shared_watch_paths" "${inventory_file}" >/dev/null
rg -n --fixed-strings "include_components" "${inventory_file}" >/dev/null

echo "validate-security-scanning-contract: OK"
