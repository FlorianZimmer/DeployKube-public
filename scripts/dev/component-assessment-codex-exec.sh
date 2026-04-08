#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/component-assessment-codex-exec.sh [options]

Runs component-assessment workpacks through Codex CLI (non-interactive) and writes results into the workpack outputs.

Options:
  --model <model>              Codex model (passed to `codex exec -m`).
  --prompt-set <both|code|docs>
                               Which prompt sets to evaluate. Default: both.
  --mode <full|changed>        full: evaluate all enabled components
                               changed: evaluate only components selected by incremental fingerprints (default).
  --component <component_id>   Evaluate only a specific component (repeatable). Forces full workpack generation
                               for the selected components (ignores incremental mode selection).
  --run-id <id>                Base run id. Default: UTC timestamp (YYYYMMDDTHHMMSSZ).
  --output-root <path>         Output root for workpacks. Default: tmp/component-assessment
  --parallel <n>               Concurrent Codex workers per prompt-set. Default: 4.
  --codex-arg <arg>            Extra arg forwarded to `codex exec` (repeatable).
  --execute                    Actually run Codex (default).
  --dry-run                    Workpacks only (no Codex execution, no promotion).
  --promote <none|candidates|apply>
                               After execution, parse outputs and write promotion artifacts.
                               candidates: write net-new findings JSONL under tmp/component-assessment/promotion-candidates/
                               apply: also merge findings into docs/component-issues/<component>.md (machine block).
                               Default: apply.
  --render-open                After promotion, render an LLM-deduped Open backlog snippet into each affected
                               `docs/component-issues/<issue_slug>.md` under `## Open` (marker-delimited).
                               Default: enabled (when `--promote apply`).
  --no-render-open             Disable Open backlog rendering even when promoting/applying findings.

Notes:
  - This script intentionally does NOT update issue trackers; it writes per-prompt results into:
      <run-dir>/<component_id>/outputs/category-results/*.md
  - For parallelism, this script runs Codex in multiple processes but each process is scoped to one component workpack.
  - Default behavior promotes into `docs/component-issues/*` and renders a human-friendly Open snippet.
    Use `--dry-run` to generate workpacks only, or `--promote candidates` to review net-new findings without editing trackers.

Examples:
  ./scripts/dev/component-assessment-codex-exec.sh --model gpt-5.2 --mode changed
  ./scripts/dev/component-assessment-codex-exec.sh --model gpt-5.2 --component certificates-smoke-tests
  ./scripts/dev/component-assessment-codex-exec.sh --model gpt-5.2 --mode full --parallel 8 --prompt-set code --promote candidates --no-render-open
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
output_root="${repo_root}/tmp/component-assessment"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
mode="changed"
prompt_set="both"
parallel="4"
model=""
execute="true"
promote="apply"
render_open="true"
render_open_explicit="false"
declare -a codex_extra_args=()
declare -a codex_user_args=()
declare -a components=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      model="$2"
      shift 2
      ;;
    --prompt-set)
      prompt_set="$2"
      shift 2
      ;;
    --mode)
      mode="$2"
      shift 2
      ;;
    --component)
      components+=("$2")
      shift 2
      ;;
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --output-root)
      output_root="$2"
      shift 2
      ;;
    --parallel)
      parallel="$2"
      shift 2
      ;;
    --codex-arg)
      codex_user_args+=("$2")
      shift 2
      ;;
    --execute)
      execute="true"
      shift
      ;;
    --promote)
      promote="$2"
      shift 2
      ;;
    --render-open)
      render_open="true"
      render_open_explicit="true"
      shift
      ;;
    --no-render-open)
      render_open="false"
      render_open_explicit="true"
      shift
      ;;
    --dry-run)
      execute="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "${prompt_set}" in
  both|code|docs) ;;
  *)
    echo "ERROR: invalid --prompt-set '${prompt_set}' (expected: both|code|docs)" >&2
    exit 2
    ;;
esac

case "${mode}" in
  full|changed) ;;
  *)
    echo "ERROR: invalid --mode '${mode}' (expected: full|changed)" >&2
    exit 2
    ;;
esac

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex not found in PATH" >&2
  exit 1
fi

if [[ -n "${model}" ]]; then
  codex_extra_args+=("-m" "${model}")
fi
if [[ ${#codex_user_args[@]} -gt 0 ]]; then
  codex_extra_args+=("${codex_user_args[@]}")
fi

workpack_args=(--output-root "${output_root}")
if [[ ${#components[@]} -gt 0 ]]; then
  for c in "${components[@]}"; do
    workpack_args+=(--component "${c}")
  done
  # For explicit component runs, always generate workpacks (do not rely on incremental selection).
  workpack_args+=(--no-incremental)
else
  workpack_args=(--all --output-root "${output_root}")
  if [[ "${mode}" == "full" ]]; then
    workpack_args+=(--no-incremental)
  fi
fi

generate_workpacks() {
  local set="$1"
  local set_run_id="${run_id}-${set}"
  "${repo_root}/scripts/dev/component-assessment-workpack.sh" \
    "${workpack_args[@]}" \
    --prompt-set "${set}" \
    --run-id "${set_run_id}" >/dev/null
  printf '%s\n' "${output_root}/${set_run_id}"
}

run_set() {
  local set="$1"
  local run_dir="$2"

  local index="${run_dir}/index.tsv"
  if [[ ! -f "${index}" ]]; then
    echo "ERROR: missing index.tsv at ${index}" >&2
    exit 1
  fi

  mapfile -t components < <(awk -F'\t' 'NR>1 && $1 != "" {print $1}' "${index}")
  if [[ ${#components[@]} -eq 0 ]]; then
    echo "No components selected for prompt-set ${set} (index empty)."
    return 0
  fi

  local tasks_file
  tasks_file="$(mktemp)"
  for c in "${components[@]}"; do
    printf '%s\t%s\n' "${run_dir}/${c}" "${c}" >> "${tasks_file}"
  done

  echo "Running Codex for prompt-set ${set}: ${#components[@]} components (parallel=${parallel})"
  REPO_ROOT="${repo_root}" \
  PARALLEL="${parallel}" \
  TASKS_FILE="${tasks_file}" \
  CODEX_ARGS_NL="$(printf '%s\n' "${codex_extra_args[@]}")" \
  python3 - <<'PY'
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

repo_root = os.environ["REPO_ROOT"]
parallel = int(os.environ.get("PARALLEL", "4"))
tasks_file = Path(os.environ["TASKS_FILE"])
codex_args = [a for a in os.environ.get("CODEX_ARGS_NL", "").splitlines() if a.strip()]

tasks = []
for line in tasks_file.read_text().splitlines():
    if not line.strip():
        continue
    component_dir, component_id = line.split("\t", 1)
    tasks.append((component_dir, component_id))

def run_one(component_dir: str, component_id: str) -> tuple[str, int]:
    component_dir_path = Path(component_dir)
    (component_dir_path / "outputs").mkdir(parents=True, exist_ok=True)

    prompt_file = component_dir_path / "outputs" / "codex-driver-prompt.txt"
    prompt_file.write_text(f"""You are running a non-interactive DeployKube component assessment using a pre-generated workpack.

Workpack:
- Component id: {component_id}
- Directory: {component_dir}

Rules (non-negotiable):
1. For each prompt file in `{component_dir}/prompts/`:
   - Read the prompt file.
   - Follow its scope/evidence rules.
   - Write the final output (exactly one NA/Applicable block, no extra text) into:
     `{component_dir}/outputs/category-results/<same filename>`
     Overwrite the file completely.
2. Use targeted reading: do NOT read every file in the allowlist. Use ripgrep/spot reads to minimize tokens.
3. Secret handling: never copy secret values into outputs; redact as `***REDACTED***`.
4. If you must open extra repo files outside the prompt's allowlist to understand cross-component relationships:
   - Keep it minimal.
   - Do NOT cite those files as evidence in outputs.
   - Record each extra file path + 1-line reason in: `{component_dir}/context/extra-context-used.txt`.
5. Do not modify tracked files outside the workpack output directory.

When finished:
- Print exactly one line: `OK {component_id}`
""", encoding="utf-8")

    extra = component_dir_path / "context" / "extra-context-used.txt"
    extra.parent.mkdir(parents=True, exist_ok=True)
    extra.write_text("", encoding="utf-8")

    stdout_log = component_dir_path / "outputs" / "codex-exec.stdout.log"
    last_msg = component_dir_path / "outputs" / "codex-exec.last-message.txt"
    exitcode_file = component_dir_path / "outputs" / "codex-exec.exitcode"

    cmd = [
        "codex",
        "exec",
        "--cd",
        repo_root,
        "--sandbox",
        "workspace-write",
        "--ephemeral",
        "--output-last-message",
        str(last_msg),
        *codex_args,
        "-",
    ]
    # Avoid noisy/slow OTEL export attempts to a localhost collector.
    env = os.environ.copy()
    env["OTEL_LOGS_EXPORTER"] = "none"
    env["OTEL_TRACES_EXPORTER"] = "none"
    env["OTEL_METRICS_EXPORTER"] = "none"
    env["OTEL_EXPORTER_OTLP_ENDPOINT"] = ""
    env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] = ""
    env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = ""
    env["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] = ""
    with prompt_file.open("rb") as stdin, stdout_log.open("wb") as out:
        proc = subprocess.run(cmd, stdin=stdin, stdout=out, stderr=subprocess.STDOUT, env=env)
    exitcode_file.write_text(str(proc.returncode) + "\n", encoding="utf-8")
    return component_id, proc.returncode

failures = 0
with ThreadPoolExecutor(max_workers=parallel) as ex:
    futs = [ex.submit(run_one, d, cid) for d, cid in tasks]
    for fut in as_completed(futs):
        cid, rc = fut.result()
        if rc != 0:
            failures += 1

print(f"codex_exec_failures={failures}")
sys.exit(1 if failures else 0)
PY
  rm -f "${tasks_file}"
}

sets=()
if [[ "${prompt_set}" == "both" ]]; then
  sets=(code docs)
else
  sets=("${prompt_set}")
fi

run_dirs=()
for s in "${sets[@]}"; do
  run_dirs+=("$(generate_workpacks "${s}")")
done

if [[ "${execute}" != "true" ]]; then
  printf 'Generated workpacks:\n'
  printf '  %s\n' "${run_dirs[@]}"
  printf '\nPass --execute to run Codex.\n'
  exit 0
fi

i=0
for s in "${sets[@]}"; do
  run_set "${s}" "${run_dirs[$i]}"
  i=$((i + 1))
done

case "${promote}" in
  none|candidates|apply) ;;
  *)
    echo "ERROR: invalid --promote '${promote}' (expected: none|candidates|apply)" >&2
    exit 2
    ;;
esac

if [[ "${promote}" != "none" ]]; then
  promote_args=()
  for rd in "${run_dirs[@]}"; do
    promote_args+=(--run-dir "${rd}")
  done
  if [[ "${promote}" == "apply" ]]; then
    promote_args+=(--apply)
  fi
  "${repo_root}/scripts/dev/component-assessment-promote.sh" "${promote_args[@]}"
fi

if [[ "${render_open}" == "true" ]]; then
  if [[ "${promote}" != "apply" ]]; then
    if [[ "${render_open_explicit}" == "true" ]]; then
      echo "ERROR: --render-open requires --promote apply (so findings are in trackers)" >&2
      exit 2
    fi
    echo "NOTE: skipping Open rendering because --promote is '${promote}' (requires: apply)" >&2
    render_open="false"
  fi
fi

if [[ "${render_open}" == "true" ]]; then
  render_args=()
  for rd in "${run_dirs[@]}"; do
    render_args+=(--run-dir "${rd}")
  done
  if [[ -n "${model}" ]]; then
    render_args+=(--model "${model}")
  fi
  if [[ ${#codex_user_args[@]} -gt 0 ]]; then
    a=""
    for a in "${codex_user_args[@]}"; do
      render_args+=(--codex-arg "${a}")
    done
  fi
  # Keep render reasonably parallel without overwhelming local machine.
  "${repo_root}/scripts/dev/component-assessment-render-open.sh" "${render_args[@]}"
fi

echo "Done. Workpacks under: ${output_root}"
