#!/usr/bin/env bash
# resolve-trivy-ci-targets.sh
# Selects centralized Trivy scan targets for CI events.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

inventory_file="${TRIVY_CI_INVENTORY:-tests/trivy/central-ci-inventory.yaml}"
event_name=""
base_ref=""
head_ref="HEAD"
mode="profile"
target="platform-core"
declare -a changed_files_override=()

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/resolve-trivy-ci-targets.sh [options]

Options:
  --inventory PATH     Inventory YAML (default tests/trivy/central-ci-inventory.yaml)
  --event-name NAME    GitHub event name (pull_request|push|schedule|workflow_dispatch)
  --base REF           Base git ref/sha for pull_request diff resolution
  --head REF           Head git ref/sha for pull_request diff resolution (default HEAD)
  --changed-file PATH  Explicit changed file for pull_request resolution (repeatable)
  --mode MODE          Non-PR target mode: profile|component (default profile)
  --target NAME        Non-PR target name (default platform-core; use __default__ for the standard aggregate set)
  --help               Show this message

Output:
  JSON array describing scan targets for workflow matrix use.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

matches_watch_path() {
  local changed_file="$1"
  local watch_path="$2"
  [[ "${changed_file}" == "${watch_path}" || "${changed_file}" == "${watch_path}/"* ]]
}

artifact_label() {
  local target_mode="$1"
  local target_name="$2"
  if [[ "${target_mode}" == "component" ]]; then
    printf 'component-%s\n' "${target_name}"
  else
    printf '%s\n' "${target_name}"
  fi
}

emit_default_profile_matrix() {
  jq -n '
    [
      {mode: "profile", target: "platform-core", artifact_label: "platform-core"},
      {mode: "profile", target: "platform-services", artifact_label: "platform-services"},
      {mode: "profile", target: "platform-foundations", artifact_label: "platform-foundations"}
    ]
  '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory)
      inventory_file="$2"
      shift 2
      ;;
    --event-name)
      event_name="$2"
      shift 2
      ;;
    --base)
      base_ref="$2"
      shift 2
      ;;
    --head)
      head_ref="$2"
      shift 2
      ;;
    --changed-file)
      changed_files_override+=("$2")
      shift 2
      ;;
    --mode)
      mode="$2"
      shift 2
      ;;
    --target)
      target="$2"
      shift 2
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

require_cmd git
require_cmd jq
require_cmd yq

if [[ ! -f "${inventory_file}" ]]; then
  echo "error: inventory file '${inventory_file}' not found" >&2
  exit 1
fi

inventory_json="$(yq -o=json '.' "${inventory_file}")"

if [[ -z "${event_name}" ]]; then
  echo "error: --event-name is required" >&2
  exit 1
fi

if [[ "${event_name}" != "pull_request" ]]; then
  if [[ "${mode}" != "profile" && "${mode}" != "component" ]]; then
    echo "error: --mode must be profile or component" >&2
    exit 1
  fi
  if [[ "${mode}" == "profile" && "${target}" == "__default__" ]]; then
    emit_default_profile_matrix
    exit 0
  fi
  jq -n \
    --arg mode "${mode}" \
    --arg target "${target}" \
    --arg artifact_label "$(artifact_label "${mode}" "${target}")" \
    '[{mode: $mode, target: $target, artifact_label: $artifact_label}]'
  exit 0
fi

if [[ "${#changed_files_override[@]}" -gt 0 ]]; then
  changed_files=("${changed_files_override[@]}")
else
  if [[ -z "${base_ref}" ]]; then
    echo "error: --base is required for pull_request resolution when --changed-file is not used" >&2
    exit 1
  fi
  mapfile -t changed_files < <(git diff --name-only "${base_ref}...${head_ref}")
fi
if [[ "${#changed_files[@]}" -eq 0 ]]; then
  printf '[]\n'
  exit 0
fi

force_all_components=0
mapfile -t shared_watch_paths < <(printf '%s' "${inventory_json}" | jq -r '.shared_watch_paths[]?')
for changed_file in "${changed_files[@]}"; do
  for watch_path in "${shared_watch_paths[@]}"; do
    if matches_watch_path "${changed_file}" "${watch_path}"; then
      force_all_components=1
      break 2
    fi
  done
done

selected_components_jsonl=""
mapfile -t component_names < <(printf '%s' "${inventory_json}" | jq -r '.components | keys[]')
for component_name in "${component_names[@]}"; do
  component_file="$(printf '%s' "${inventory_json}" | jq -r --arg component_name "${component_name}" '.components[$component_name].file')"
  component_json="$(yq -o=json '.' "${component_file}")"
  mapfile -t watch_paths < <(printf '%s' "${component_json}" | jq -r '.watch_paths[]?')
  watch_paths+=("${component_file}")

  component_selected=0
  if [[ "${force_all_components}" -eq 1 ]]; then
    component_selected=1
  else
    for changed_file in "${changed_files[@]}"; do
      for watch_path in "${watch_paths[@]}"; do
        if matches_watch_path "${changed_file}" "${watch_path}"; then
          component_selected=1
          break 2
        fi
      done
    done
  fi

  if [[ "${component_selected}" -eq 1 ]]; then
    selected_components_jsonl+=$(jq -n \
      --arg mode "component" \
      --arg target "${component_name}" \
      --arg artifact_label "$(artifact_label "component" "${component_name}")" \
      '{mode: $mode, target: $target, artifact_label: $artifact_label}')
    selected_components_jsonl+=$'\n'
  fi
done

if [[ -z "${selected_components_jsonl}" ]]; then
  printf '[]\n'
  exit 0
fi

printf '%s' "${selected_components_jsonl}" | jq -sc 'sort_by(.target)'
