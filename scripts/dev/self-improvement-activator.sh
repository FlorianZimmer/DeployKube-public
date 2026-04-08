#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./scripts/dev/self-improvement-activator.sh [--print-skill-path]

Runs the self-improving-agent activator from the newest installed skill version
under ~/.codex/skills/self-improving-agent-*.
USAGE
}

resolve_latest_skill_dir() {
  local base="${HOME}/.codex/skills"
  local best_dir=""
  local best_key=""

  shopt -s nullglob
  local candidates=("${base}"/self-improving-agent-*)
  shopt -u nullglob

  local dir
  for dir in "${candidates[@]}"; do
    [[ -d "${dir}" ]] || continue

    local version="${dir##*/}"
    version="${version#self-improving-agent-}"
    if [[ ! "${version}" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?([.-].*)?$ ]]; then
      continue
    fi

    local major="${BASH_REMATCH[1]:-0}"
    local minor="${BASH_REMATCH[3]:-0}"
    local patch="${BASH_REMATCH[5]:-0}"

    local key=""
    printf -v key '%08d%08d%08d' "${major:-0}" "${minor:-0}" "${patch:-0}"
    if [[ -z "${best_key}" || "${key}" > "${best_key}" ]]; then
      best_key="${key}"
      best_dir="${dir}"
    fi
  done

  if [[ -z "${best_dir}" ]]; then
    echo "ERROR: no self-improving-agent skill found under ${base}" >&2
    echo "Install it via the skill installer, then retry." >&2
    return 1
  fi

  printf '%s\n' "${best_dir}"
}

print_skill_path="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-skill-path)
      print_skill_path="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

skill_dir="$(resolve_latest_skill_dir)"
activator_script="${skill_dir}/scripts/activator.sh"

if [[ "${print_skill_path}" == "true" ]]; then
  printf '%s\n' "${skill_dir}"
  exit 0
fi

if [[ ! -x "${activator_script}" ]]; then
  echo "ERROR: activator script is missing or not executable: ${activator_script}" >&2
  exit 1
fi

"${activator_script}"
