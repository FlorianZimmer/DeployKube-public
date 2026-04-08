#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./scripts/dev/self-improvement-error-detector.sh [options]

Runs the self-improving-agent error detector from the newest installed skill
version and applies hardened checks.

Options:
  --exit-code <n>      Exit code of the command that was run (recommended)
  --command <text>     Command text that produced the output
  --output <text>      Command output text (appended to CLAUDE_TOOL_OUTPUT)
  --output-file <path> File containing command output text
  --print-skill-path   Print resolved self-improving-agent skill directory
  -h, --help           Show this help

Notes:
- This detector is signal-based. It cannot prove correctness.
- Syntax/lint/render checks can pass while runtime behavior is still wrong.
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

is_syntax_or_render_only_command() {
  local cmd="$1"
  [[ -z "${cmd}" ]] && return 1

  if [[ "${cmd}" =~ (^|[[:space:]])(sh|bash|zsh|dash)[[:space:]]+-n([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "${cmd}" =~ (^|[[:space:]])shellcheck([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "${cmd}" =~ (^|[[:space:]])(yamllint|jsonlint|kubeval|kubeconform)([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "${cmd}" =~ (^|[[:space:]])helm[[:space:]]+lint([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "${cmd}" =~ (^|[[:space:]])kustomize[[:space:]]+build([[:space:]]|$) ]]; then
    return 0
  fi

  return 1
}

exit_code=""
command_text="${SELF_IMPROVEMENT_COMMAND:-}"
output_text="${CLAUDE_TOOL_OUTPUT:-${SELF_IMPROVEMENT_OUTPUT:-}}"
output_file=""
print_skill_path="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exit-code)
      exit_code="${2:-}"
      shift 2
      ;;
    --command)
      command_text="${2:-}"
      shift 2
      ;;
    --output)
      if [[ -n "${output_text}" ]]; then
        output_text+=$'\n'
      fi
      output_text+="${2:-}"
      shift 2
      ;;
    --output-file)
      output_file="${2:-}"
      shift 2
      ;;
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

if [[ -n "${output_file}" ]]; then
  if [[ ! -f "${output_file}" ]]; then
    echo "ERROR: output file does not exist: ${output_file}" >&2
    exit 2
  fi
  file_text="$(cat "${output_file}")"
  if [[ -n "${file_text}" ]]; then
    if [[ -n "${output_text}" ]]; then
      output_text+=$'\n'
    fi
    output_text+="${file_text}"
  fi
fi

skill_dir="$(resolve_latest_skill_dir)"
base_detector="${skill_dir}/scripts/error-detector.sh"

if [[ "${print_skill_path}" == "true" ]]; then
  printf '%s\n' "${skill_dir}"
  exit 0
fi

if [[ ! -x "${base_detector}" ]]; then
  echo "ERROR: error-detector script is missing or not executable: ${base_detector}" >&2
  exit 1
fi

# Keep base detector behavior for compatibility.
if [[ -n "${output_text}" ]]; then
  CLAUDE_TOOL_OUTPUT="${output_text}" "${base_detector}" || true
else
  "${base_detector}" || true
fi

contains_error_signal="false"
signal_reasons=()

if [[ -n "${exit_code}" ]]; then
  if [[ ! "${exit_code}" =~ ^-?[0-9]+$ ]]; then
    echo "ERROR: --exit-code must be an integer: ${exit_code}" >&2
    exit 2
  fi
  if (( exit_code != 0 )); then
    contains_error_signal="true"
    signal_reasons+=("non-zero exit code (${exit_code})")
  fi
fi

if [[ -n "${output_text}" ]]; then
  error_regex='error:|failed|command not found|no such file|permission denied|fatal:|exception|traceback|npm err!|modulenotfounderror|syntaxerror|typeerror|non-zero|panic:|timed out|timeout'
  if printf '%s' "${output_text}" | grep -Eiq "${error_regex}"; then
    contains_error_signal="true"
    signal_reasons+=("error text pattern")
  fi
fi

if [[ "${contains_error_signal}" == "true" ]]; then
  reason_text="${signal_reasons[*]}"
  cat <<WARN
<hardened-error-detector>
Error signal detected (${reason_text}).
If this required debugging, log it in .learnings/ERRORS.md.
</hardened-error-detector>
WARN
fi

# Scope reminder: passing syntax/lint/render checks is necessary but not sufficient.
if is_syntax_or_render_only_command "${command_text}"; then
  cat <<'WARN'
<validation-scope-warning>
Detected a syntax/lint/render-only command. A PASS here does not prove behavior is correct.
Follow with at least one functional validation that exercises runtime semantics.
</validation-scope-warning>
WARN
fi
