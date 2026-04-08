#!/usr/bin/env bash
# scan-trivy-ci.sh
# Centralized repo-owned Trivy runner for the CI scanning plane.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

inventory_file="${TRIVY_CI_INVENTORY:-tests/trivy/central-ci-inventory.yaml}"
profile="platform-core"
component=""
output_dir="${TRIVY_CI_OUTPUT_DIR:-${root_dir}/tmp/trivy-ci-scan}"
resolve_only=0
skip_sarif=0
skip_sbom=0
severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
trivy_image="${TRIVY_IMAGE:-aquasec/trivy:0.58.2}"
cache_dir="${TRIVY_CACHE_DIR:-${root_dir}/tmp/trivy-cache/central-ci}"
registry_rewrite_from="${TRIVY_CI_REGISTRY_REWRITE_FROM:-}"
registry_rewrite_to="${TRIVY_CI_REGISTRY_REWRITE_TO:-}"
registry_rewrite_rules="${TRIVY_CI_REGISTRY_REWRITE_RULES:-}"
insecure_remote_prefixes_raw="${TRIVY_CI_INSECURE_REMOTE_PREFIXES:-}"
docker_platform="${TRIVY_CI_DOCKER_PLATFORM:-}"
declare -a rewrite_rule_froms=()
declare -a rewrite_rule_tos=()
declare -a insecure_remote_prefixes=()
declare -A image_overrides=()

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/scan-trivy-ci.sh [options]

Options:
  --inventory PATH     Inventory YAML (default tests/trivy/central-ci-inventory.yaml)
  --profile NAME       Aggregate profile to run (default platform-core)
  --component NAME     Component fragment to run directly
  --output-dir PATH    Output directory for raw/sarif/sbom/summary files
  --resolve-only       Resolve targets without running Trivy
  --image-override ID=REF
                       Override one resolved image target ref (repeatable)
  --skip-sarif         Do not generate SARIF reports
  --skip-sbom          Do not generate CycloneDX reports for image targets
  --help               Show this message

Outputs:
  - resolved-targets.json (always)
  - summary.json (scan mode only)
  - raw/{image,config}/*.json
  - sarif/{image,config}/*.sarif
  - sbom/image/*.cdx.json

Environment:
  TRIVY_CI_REGISTRY_REWRITE_FROM   Optional image prefix to rewrite
  TRIVY_CI_REGISTRY_REWRITE_TO     Replacement prefix (for local mirror paths)
  TRIVY_CI_REGISTRY_REWRITE_RULES  Optional ';'-separated FROM=TO rewrite rules
  TRIVY_CI_INSECURE_REMOTE_PREFIXES Optional ';'-separated image prefixes to scan
                                    directly with 'trivy image --insecure' instead
                                    of docker pull/save (useful for HTTP caches)
  TRIVY_CI_DOCKER_PLATFORM         Optional Docker platform (for example
                                    linux/amd64) for local pull/run validation
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

json_array_or_empty() {
  local file="$1"
  if [[ -s "${file}" ]]; then
    jq -s '.' "${file}"
  else
    printf '[]\n'
  fi
}

metric_count() {
  local raw_file="$1"
  local field="$2"
  local severity_name="$3"
  jq --arg field "${field}" --arg severity_name "${severity_name}" '
    [.Results[]?[$field][]? | select(.Severity == $severity_name)] | length
  ' "${raw_file}"
}

sanitize_id() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

append_rewrite_rule() {
  local from="$1"
  local to="$2"
  [[ -n "${from}" && -n "${to}" ]] || return 0
  rewrite_rule_froms+=("${from}")
  rewrite_rule_tos+=("${to}")
}

load_rewrite_rules() {
  local raw_rule
  local from
  local to

  if [[ -n "${registry_rewrite_rules}" ]]; then
    IFS=';' read -r -a raw_rules <<<"${registry_rewrite_rules}"
    for raw_rule in "${raw_rules[@]}"; do
      [[ -n "${raw_rule}" ]] || continue
      if [[ "${raw_rule}" != *=* ]]; then
        echo "error: invalid TRIVY_CI_REGISTRY_REWRITE_RULES entry '${raw_rule}'" >&2
        exit 1
      fi
      from="${raw_rule%%=*}"
      to="${raw_rule#*=}"
      append_rewrite_rule "${from}" "${to}"
    done
  fi

  if [[ -n "${registry_rewrite_from}" && -n "${registry_rewrite_to}" ]]; then
    append_rewrite_rule "${registry_rewrite_from}" "${registry_rewrite_to}"
  fi
}

load_insecure_remote_prefixes() {
  local raw_prefix

  if [[ -z "${insecure_remote_prefixes_raw}" ]]; then
    return 0
  fi

  IFS=';' read -r -a raw_prefixes <<<"${insecure_remote_prefixes_raw}"
  for raw_prefix in "${raw_prefixes[@]}"; do
    [[ -n "${raw_prefix}" ]] || continue
    insecure_remote_prefixes+=("${raw_prefix}")
  done
}

apply_registry_rewrite() {
  local ref="$1"
  local i
  local best_idx="-1"
  local best_len=0
  local candidate_from

  for i in "${!rewrite_rule_froms[@]}"; do
    candidate_from="${rewrite_rule_froms[$i]}"
    if [[ "${ref}" == "${candidate_from}" || "${ref}" == "${candidate_from}/"* ]]; then
      if (( ${#candidate_from} > best_len )); then
        best_idx="$i"
        best_len="${#candidate_from}"
      fi
    fi
  done

  if (( best_idx >= 0 )); then
    printf '%s\n' "${rewrite_rule_tos[$best_idx]}${ref#${rewrite_rule_froms[$best_idx]}}"
    return 0
  fi

  printf '%s\n' "${ref}"
}

ref_uses_insecure_remote_scan() {
  local ref="$1"
  local prefix

  for prefix in "${insecure_remote_prefixes[@]}"; do
    if [[ "${ref}" == "${prefix}" || "${ref}" == "${prefix}/"* ]]; then
      return 0
    fi
  done

  return 1
}

trivy_run() {
  local -a docker_args=(run --rm)
  if [[ -n "${docker_platform}" ]]; then
    docker_args+=(--platform "${docker_platform}")
  fi
  docker "${docker_args[@]}" \
    -v "${cache_dir}:/root/.cache" \
    -v "${root_dir}:/repo:ro" \
    -v "${output_dir}:/scan" \
    -w /repo \
    "${trivy_image}" "$@"
}

resolve_inventory_json() {
  yq -o=json '.' "${inventory_file}"
}

resolve_component_file() {
  local component_name="$1"
  printf '%s' "${inventory_json}" | jq -r --arg component_name "${component_name}" '
    .components[$component_name].file // empty
  '
}

load_component_json() {
  local component_name="$1"
  local component_file

  component_file="$(resolve_component_file "${component_name}")"
  if [[ -z "${component_file}" ]]; then
    echo "error: component '${component_name}' not found in ${inventory_file}" >&2
    exit 1
  fi
  if [[ ! -f "${component_file}" ]]; then
    echo "error: component file '${component_file}' not found" >&2
    exit 1
  fi

  yq -o=json '.' "${component_file}" | jq -c --arg component_name "${component_name}" --arg component_file "${component_file}" '
    . + {component: $component_name, component_file: $component_file}
  '
}

check_unique_target_ids() {
  local selection_json="$1"
  local target_kind="$2"
  local duplicates

  duplicates="$(printf '%s' "${selection_json}" | jq -r --arg target_kind "${target_kind}" '
    [(.[$target_kind][]?.id)] | group_by(.) | map(select(length > 1) | .[0]) | .[]
  ' || true)"
  if [[ -n "${duplicates}" ]]; then
    echo "error: duplicate ${target_kind} ids in selection:" >&2
    printf '%s\n' "${duplicates}" >&2
    exit 1
  fi
}

resolve_catalog_spec_json() {
  local catalog_name="$1"
  printf '%s' "${inventory_json}" | jq -c --arg catalog_name "${catalog_name}" '
    .artifact_catalogs[$catalog_name] // empty
  '
}

resolve_catalog_file() {
  local catalog_name="$1"
  local catalog_spec_json

  catalog_spec_json="$(resolve_catalog_spec_json "${catalog_name}")"
  if [[ -z "${catalog_spec_json}" || "${catalog_spec_json}" == "null" ]]; then
    echo "error: artifact catalog '${catalog_name}' not found in ${inventory_file}" >&2
    exit 1
  fi

  printf '%s' "${catalog_spec_json}" | jq -r '.file // empty'
}

resolve_catalog_ref() {
  local catalog_name="$1"
  local artifact_name="$2"
  local ref_field_override="$3"
  local catalog_spec_json
  local catalog_file
  local ref_field
  local ref

  catalog_spec_json="$(resolve_catalog_spec_json "${catalog_name}")"
  if [[ -z "${catalog_spec_json}" || "${catalog_spec_json}" == "null" ]]; then
    echo "error: artifact catalog '${catalog_name}' not found in ${inventory_file}" >&2
    exit 1
  fi

  catalog_file="$(printf '%s' "${catalog_spec_json}" | jq -r '.file // empty')"
  ref_field="$(printf '%s' "${catalog_spec_json}" | jq -r '.ref_field // empty')"
  if [[ -n "${ref_field_override}" ]]; then
    ref_field="${ref_field_override}"
  fi
  if [[ -z "${catalog_file}" || -z "${ref_field}" ]]; then
    echo "error: artifact catalog '${catalog_name}' is missing file/ref_field metadata" >&2
    exit 1
  fi
  if [[ ! -f "${catalog_file}" ]]; then
    echo "error: artifact catalog file '${catalog_file}' not found" >&2
    exit 1
  fi

  ref="$(yq -o=json '.' "${catalog_file}" | jq -r --arg artifact_name "${artifact_name}" --arg ref_field "${ref_field}" '
    first(.spec.images[]? | select(.name == $artifact_name) | .[$ref_field]) // empty
  ')"
  if [[ -z "${ref}" || "${ref}" == "null" ]]; then
    echo "error: artifact '${artifact_name}' with ref field '${ref_field}' resolved empty from catalog '${catalog_name}'" >&2
    exit 1
  fi

  printf '%s\n' "${ref}"
}

resolve_selection_json() {
  if [[ -n "${component}" ]]; then
    component_json="$(load_component_json "${component}")"
    printf '%s' "${component_json}" | jq -c '
      {
        description: (.description // ""),
        include_components: [.component],
        image_targets: (.image_targets // []),
        config_targets: (.config_targets // [])
      }
    '
    return 0
  fi

  profile_spec_json="$(printf '%s' "${inventory_json}" | jq -c --arg profile "${profile}" '.profiles[$profile] // empty')"
  if [[ -z "${profile_spec_json}" || "${profile_spec_json}" == "null" ]]; then
    echo "error: profile '${profile}' not found in ${inventory_file}" >&2
    exit 1
  fi

  mapfile -t included_components < <(printf '%s' "${profile_spec_json}" | jq -r '.include_components[]?')
  if [[ "${#included_components[@]}" -eq 0 ]]; then
    echo "error: profile '${profile}' does not include any components" >&2
    exit 1
  fi

  component_docs_jsonl=""
  for component_name in "${included_components[@]}"; do
    component_docs_jsonl+=$(load_component_json "${component_name}")
    component_docs_jsonl+=$'\n'
  done

  printf '%s' "${component_docs_jsonl}" | jq -sc --arg description "$(printf '%s' "${profile_spec_json}" | jq -r '.description // empty')" '
    {
      description: $description,
      include_components: [.[].component],
      image_targets: [.[].image_targets[]?],
      config_targets: [.[].config_targets[]?]
    }
  '
}

resolve_image_ref() {
  local target_json="$1"
  local ref
  local target_file
  local target_expr
  local artifact_catalog
  local artifact_name
  local catalog_ref_field

  ref="$(printf '%s' "${target_json}" | jq -r '.ref // empty')"
  if [[ -n "${ref}" ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi

  artifact_catalog="$(printf '%s' "${target_json}" | jq -r '.artifact_catalog // empty')"
  artifact_name="$(printf '%s' "${target_json}" | jq -r '.artifact_name // empty')"
  catalog_ref_field="$(printf '%s' "${target_json}" | jq -r '.catalog_ref_field // empty')"
  if [[ -n "${artifact_catalog}" || -n "${artifact_name}" ]]; then
    if [[ -z "${artifact_catalog}" || -z "${artifact_name}" ]]; then
      echo "error: image target must set both artifact_catalog and artifact_name" >&2
      exit 1
    fi
    resolve_catalog_ref "${artifact_catalog}" "${artifact_name}" "${catalog_ref_field}"
    return 0
  fi

  target_file="$(printf '%s' "${target_json}" | jq -r '.file // empty')"
  target_expr="$(printf '%s' "${target_json}" | jq -r '.expression // empty')"
  if [[ -z "${target_file}" || -z "${target_expr}" ]]; then
    echo "error: image target is missing either ref or file/expression" >&2
    exit 1
  fi
  if [[ ! -f "${target_file}" ]]; then
    echo "error: missing inventory source file '${target_file}'" >&2
    exit 1
  fi

  ref="$(yq -r "${target_expr}" "${target_file}")"
  if [[ -z "${ref}" || "${ref}" == "null" ]]; then
    echo "error: inventory expression resolved empty for '${target_file}'" >&2
    exit 1
  fi
  printf '%s\n' "${ref}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory)
      inventory_file="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --component)
      component="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --resolve-only)
      resolve_only=1
      shift
      ;;
    --image-override)
      override_arg="$2"
      if [[ "${override_arg}" != *=* ]]; then
        echo "error: --image-override must use ID=REF syntax" >&2
        exit 1
      fi
      override_id="${override_arg%%=*}"
      override_ref="${override_arg#*=}"
      image_overrides["${override_id}"]="${override_ref}"
      shift 2
      ;;
    --skip-sarif)
      skip_sarif=1
      shift
      ;;
    --skip-sbom)
      skip_sbom=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd jq
require_cmd yq
if [[ "${resolve_only}" -ne 1 ]]; then
  require_cmd docker
fi

if [[ ! -f "${inventory_file}" ]]; then
  echo "error: inventory file '${inventory_file}' not found" >&2
  exit 1
fi

if [[ -n "${component}" && "${profile}" != "platform-core" ]]; then
  echo "error: use either --profile or --component, not both" >&2
  exit 1
fi

if [[ "${output_dir}" != /* ]]; then
  output_dir="${root_dir}/${output_dir#./}"
fi
if [[ "${cache_dir}" != /* ]]; then
  cache_dir="${root_dir}/${cache_dir#./}"
fi

inventory_json="$(resolve_inventory_json)"
load_rewrite_rules
load_insecure_remote_prefixes
if [[ -n "${component}" ]]; then
  selection_mode="component"
  selection_name="${component}"
else
  selection_mode="profile"
  selection_name="${profile}"
fi
selection_json="$(resolve_selection_json)"
check_unique_target_ids "${selection_json}" "image_targets"
check_unique_target_ids "${selection_json}" "config_targets"

mkdir -p "${output_dir}/raw/image" "${output_dir}/raw/config" "${output_dir}/sarif/image" \
  "${output_dir}/sarif/config" "${output_dir}/sbom/image" "${output_dir}/tmp"
mkdir -p "${cache_dir}"

resolved_images_jsonl="${output_dir}/tmp/resolved-images.jsonl"
resolved_configs_jsonl="${output_dir}/tmp/resolved-configs.jsonl"
image_results_jsonl="${output_dir}/tmp/image-results.jsonl"
config_results_jsonl="${output_dir}/tmp/config-results.jsonl"
: > "${resolved_images_jsonl}"
: > "${resolved_configs_jsonl}"
: > "${image_results_jsonl}"
: > "${config_results_jsonl}"

while IFS= read -r target_json; do
  [[ -n "${target_json}" ]] || continue
  id="$(printf '%s' "${target_json}" | jq -r '.id')"
  ref="$(resolve_image_ref "${target_json}")"
  if [[ -n "${image_overrides[${id}]:-}" ]]; then
    ref="${image_overrides[${id}]}"
  elif [[ "${#rewrite_rule_froms[@]}" -gt 0 ]]; then
    ref="$(apply_registry_rewrite "${ref}")"
  fi
  source_file="$(printf '%s' "${target_json}" | jq -r '.file // empty')"
  artifact_catalog="$(printf '%s' "${target_json}" | jq -r '.artifact_catalog // empty')"
  artifact_name="$(printf '%s' "${target_json}" | jq -r '.artifact_name // empty')"
  if [[ -z "${source_file}" && -n "${artifact_catalog}" ]]; then
    source_file="$(resolve_catalog_file "${artifact_catalog}")"
  fi
  jq -n \
    --arg id "${id}" \
    --arg ref "${ref}" \
    --arg source_file "${source_file}" \
    --arg artifact_catalog "${artifact_catalog}" \
    --arg artifact_name "${artifact_name}" \
    '{id: $id, ref: $ref, source_file: $source_file, artifact_catalog: $artifact_catalog, artifact_name: $artifact_name}' >> "${resolved_images_jsonl}"

  if [[ "${resolve_only}" -eq 1 ]]; then
    continue
  fi

  safe_id="$(sanitize_id "${id}")"
  archive_rel="tmp/${safe_id}.tar"
  archive_path="${output_dir}/${archive_rel}"
  raw_rel="raw/image/${safe_id}.json"
  sarif_rel="sarif/image/${safe_id}.sarif"
  sbom_rel="sbom/image/${safe_id}.cdx.json"

  echo "==> [image] ${id}: ${ref}"
  if ref_uses_insecure_remote_scan "${ref}"; then
    trivy_run image \
      --insecure \
      --severity "${severity}" \
      --ignore-unfixed \
      --format json \
      --output "/scan/${raw_rel}" \
      --quiet \
      "${ref}"
  else
    if [[ -n "${docker_platform}" && "${ref}" != *@sha256:* ]]; then
      docker pull --platform "${docker_platform}" "${ref}" >/dev/null
    else
      docker pull "${ref}" >/dev/null
    fi
    docker save "${ref}" -o "${archive_path}" >/dev/null
    trivy_run image \
      --input "/scan/${archive_rel}" \
      --severity "${severity}" \
      --ignore-unfixed \
      --format json \
      --output "/scan/${raw_rel}" \
      --quiet
    rm -f "${archive_path}"
  fi

  if [[ "${skip_sarif}" -ne 1 ]]; then
    trivy_run convert \
      --format sarif \
      --output "/scan/${sarif_rel}" \
      "/scan/${raw_rel}" >/dev/null
  fi
  if [[ "${skip_sbom}" -ne 1 ]]; then
    trivy_run convert \
      --format cyclonedx \
      --output "/scan/${sbom_rel}" \
      "/scan/${raw_rel}" >/dev/null
  fi

  critical="$(metric_count "${output_dir}/${raw_rel}" "Vulnerabilities" "CRITICAL")"
  high="$(metric_count "${output_dir}/${raw_rel}" "Vulnerabilities" "HIGH")"
  jq -n \
    --arg id "${id}" \
    --arg ref "${ref}" \
    --arg source_file "${source_file}" \
    --arg raw_report "${raw_rel}" \
    --arg sarif_report "${sarif_rel}" \
    --arg sbom_report "${sbom_rel}" \
    --argjson critical "${critical}" \
    --argjson high "${high}" \
    '{
      id: $id,
      ref: $ref,
      source_file: $source_file,
      raw_report: $raw_report,
      sarif_report: $sarif_report,
      sbom_report: $sbom_report,
      critical: $critical,
      high: $high
    }' >> "${image_results_jsonl}"
done < <(printf '%s' "${selection_json}" | jq -c '.image_targets[]?')

while IFS= read -r target_json; do
  [[ -n "${target_json}" ]] || continue
  id="$(printf '%s' "${target_json}" | jq -r '.id')"
  path="$(printf '%s' "${target_json}" | jq -r '.path')"
  if [[ ! -e "${path}" ]]; then
    echo "error: config target path '${path}' does not exist" >&2
    exit 1
  fi
  jq -n \
    --arg id "${id}" \
    --arg path "${path}" \
    '{id: $id, path: $path}' >> "${resolved_configs_jsonl}"

  if [[ "${resolve_only}" -eq 1 ]]; then
    continue
  fi

  safe_id="$(sanitize_id "${id}")"
  raw_rel="raw/config/${safe_id}.json"
  sarif_rel="sarif/config/${safe_id}.sarif"

  echo "==> [config] ${id}: ${path}"
  trivy_run config \
    --severity "${severity}" \
    --format json \
    --output "/scan/${raw_rel}" \
    --quiet \
    "/repo/${path}"

  if [[ "${skip_sarif}" -ne 1 ]]; then
    trivy_run convert \
      --format sarif \
      --output "/scan/${sarif_rel}" \
      "/scan/${raw_rel}" >/dev/null
  fi

  critical="$(metric_count "${output_dir}/${raw_rel}" "Misconfigurations" "CRITICAL")"
  high="$(metric_count "${output_dir}/${raw_rel}" "Misconfigurations" "HIGH")"
  jq -n \
    --arg id "${id}" \
    --arg path "${path}" \
    --arg raw_report "${raw_rel}" \
    --arg sarif_report "${sarif_rel}" \
    --argjson critical "${critical}" \
    --argjson high "${high}" \
    '{
      id: $id,
      path: $path,
      raw_report: $raw_report,
      sarif_report: $sarif_report,
      critical: $critical,
      high: $high
    }' >> "${config_results_jsonl}"
done < <(printf '%s' "${selection_json}" | jq -c '.config_targets[]?')

resolved_images_json="$(json_array_or_empty "${resolved_images_jsonl}")"
resolved_configs_json="$(json_array_or_empty "${resolved_configs_jsonl}")"
jq -n \
  --arg inventory "${inventory_file}" \
  --arg profile "${selection_name}" \
  --arg selection_mode "${selection_mode}" \
  --argjson included_components "$(printf '%s' "${selection_json}" | jq '.include_components // []')" \
  --argjson image_targets "${resolved_images_json}" \
  --argjson config_targets "${resolved_configs_json}" \
  '{
    inventory: $inventory,
    profile: $profile,
    selection_mode: $selection_mode,
    included_components: $included_components,
    image_targets: $image_targets,
    config_targets: $config_targets
  }' > "${output_dir}/resolved-targets.json"

if [[ "${resolve_only}" -eq 1 ]]; then
  echo "resolved targets written to ${output_dir}/resolved-targets.json"
  exit 0
fi

image_results_json="$(json_array_or_empty "${image_results_jsonl}")"
config_results_json="$(json_array_or_empty "${config_results_jsonl}")"
image_targets_total="$(printf '%s' "${image_results_json}" | jq 'length')"
config_targets_total="$(printf '%s' "${config_results_json}" | jq 'length')"
image_critical_total="$(printf '%s' "${image_results_json}" | jq '[.[].critical] | add // 0')"
image_high_total="$(printf '%s' "${image_results_json}" | jq '[.[].high] | add // 0')"
config_critical_total="$(printf '%s' "${config_results_json}" | jq '[.[].critical] | add // 0')"
config_high_total="$(printf '%s' "${config_results_json}" | jq '[.[].high] | add // 0')"

jq -n \
  --arg inventory "${inventory_file}" \
  --arg profile "${selection_name}" \
  --arg selection_mode "${selection_mode}" \
  --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg trivy_image "${trivy_image}" \
  --arg severity "${severity}" \
  --argjson included_components "$(printf '%s' "${selection_json}" | jq '.include_components // []')" \
  --argjson image_results "${image_results_json}" \
  --argjson config_results "${config_results_json}" \
  --argjson image_targets_total "${image_targets_total}" \
  --argjson config_targets_total "${config_targets_total}" \
  --argjson image_critical_total "${image_critical_total}" \
  --argjson image_high_total "${image_high_total}" \
  --argjson config_critical_total "${config_critical_total}" \
  --argjson config_high_total "${config_high_total}" \
  '{
    inventory: $inventory,
    profile: $profile,
    selection_mode: $selection_mode,
    included_components: $included_components,
    generated_at: $generated_at,
    trivy_image: $trivy_image,
    severity: $severity,
    image_results: $image_results,
    config_results: $config_results,
    totals: {
      image_targets: $image_targets_total,
      config_targets: $config_targets_total,
      image_critical_total: $image_critical_total,
      image_high_total: $image_high_total,
      config_critical_total: $config_critical_total,
      config_high_total: $config_high_total
    }
  }' > "${output_dir}/summary.json"

echo "summary written to ${output_dir}/summary.json"
