#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

lock_file="${root_dir}/versions.lock.yaml"
write_report=""
declare -a selected_classes=()
declare -a raw_sets=()

usage() {
  cat <<'EOF'
Usage:
  ./scripts/dev/version-bump-proposal.sh [--class <class_id> ...] [--set <component_id>=<version> ...] [--write-report <path>]

What it does:
  - Reads the curated machine-readable catalog in versions.lock.yaml
  - Renders a grouped Markdown proposal/report by bump class
  - Optionally overlays proposed target versions without editing repo files

Examples:
  ./scripts/dev/version-bump-proposal.sh
  ./scripts/dev/version-bump-proposal.sh --class tier0-security
  ./scripts/dev/version-bump-proposal.sh --class tier0-security --set cert-manager-chart=v1.19.3
  ./scripts/dev/version-bump-proposal.sh --set cilium-stage0-chart=1.18.6 --write-report tmp/cilium-bump.md
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)
      selected_classes+=("$2")
      shift 2
      ;;
    --set)
      raw_sets+=("$2")
      shift 2
      ;;
    --write-report)
      write_report="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd jq
require_cmd yq

if [[ ! -f "${lock_file}" ]]; then
  echo "error: missing ${lock_file}" >&2
  exit 1
fi

lock_json="$(yq -o=json '.' "${lock_file}")"

declare -A proposed_versions=()
for item in "${raw_sets[@]}"; do
  component_id="${item%%=*}"
  proposed_version="${item#*=}"
  if [[ -z "${component_id}" || -z "${proposed_version}" || "${component_id}" == "${proposed_version}" ]]; then
    echo "error: invalid --set value '${item}' (expected component_id=version)" >&2
    exit 1
  fi
  if ! printf '%s' "${lock_json}" | jq -e --arg component_id "${component_id}" '.components[] | select(.id == $component_id)' >/dev/null 2>&1; then
    echo "error: unknown component id '${component_id}' in --set" >&2
    exit 1
  fi
  proposed_versions["${component_id}"]="${proposed_version}"
done

if [[ "${#selected_classes[@]}" -eq 0 ]]; then
  mapfile -t selected_classes < <(printf '%s' "${lock_json}" | jq -r '.classes[].id')
fi

for class_id in "${selected_classes[@]}"; do
  if ! printf '%s' "${lock_json}" | jq -e --arg class_id "${class_id}" '.classes[] | select(.id == $class_id)' >/dev/null 2>&1; then
    echo "error: unknown class id '${class_id}'" >&2
    exit 1
  fi
done

generate_report() {
  local generated_at selected_list class_id class_json title description component_count
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  selected_list="$(printf '%s, ' "${selected_classes[@]}")"
  selected_list="${selected_list%, }"

  cat <<EOF
# DeployKube version bump proposal

Generated: ${generated_at}
Catalog: \`versions.lock.yaml\`
Selected classes: ${selected_list}

This report is proposal-only. It does not edit repo files.

EOF

  for class_id in "${selected_classes[@]}"; do
    class_json="$(printf '%s' "${lock_json}" | jq -c --arg class_id "${class_id}" '.classes[] | select(.id == $class_id)')"
    title="$(printf '%s' "${class_json}" | jq -r '.title')"
    description="$(printf '%s' "${class_json}" | jq -r '.description')"
    component_count="$(printf '%s' "${lock_json}" | jq -r --arg class_id "${class_id}" '[.components[] | select(.class == $class_id)] | length')"

    cat <<EOF
## ${title} (\`${class_id}\`)

${description}

Shared validations:
EOF
    mapfile -t shared_validations < <(printf '%s' "${class_json}" | jq -r '.shared_validations[]')
    for validation in "${shared_validations[@]}"; do
      printf -- '- %s\n' "${validation}"
    done
    printf '\n'

    if [[ "${component_count}" -eq 0 ]]; then
      echo "_No components currently registered in this class._"
      echo ""
      continue
    fi

    mapfile -t components < <(printf '%s' "${lock_json}" | jq -c --arg class_id "${class_id}" '.components[] | select(.class == $class_id)')
    for component in "${components[@]}"; do
      component_id="$(printf '%s' "${component}" | jq -r '.id')"
      component_title="$(printf '%s' "${component}" | jq -r '.title')"
      current_version="$(printf '%s' "${component}" | jq -r '.version')"
      summary="$(printf '%s' "${component}" | jq -r '.summary')"
      proposed_version="${proposed_versions[${component_id}]:--}"

      printf -- '- `%s` (%s): current `%s`, proposed `%s`\n' "${component_id}" "${component_title}" "${current_version}" "${proposed_version}"
      printf '  %s\n' "${summary}"

      mapfile -t notes < <(printf '%s' "${component}" | jq -r '.proposal_notes[]?')
      if [[ "${#notes[@]}" -gt 0 ]]; then
        echo "  Notes:"
        for note in "${notes[@]}"; do
          printf '  - %s\n' "${note}"
        done
      fi

      mapfile -t reference_paths < <(printf '%s' "${component}" | jq -r '.references[].path')
      echo "  Repo references:"
      for ref_path in "${reference_paths[@]}"; do
        printf '  - %s\n' "${ref_path}"
      done

      mapfile -t validations < <(printf '%s' "${component}" | jq -r '.validations[]?')
      if [[ "${#validations[@]}" -gt 0 ]]; then
        echo "  Component-specific validations:"
        for validation in "${validations[@]}"; do
          printf '  - %s\n' "${validation}"
        done
      fi
      echo ""
    done
  done
}

if [[ -n "${write_report}" ]]; then
  mkdir -p "$(dirname "${write_report}")"
  generate_report > "${write_report}"
  echo "wrote ${write_report}"
else
  generate_report
fi
