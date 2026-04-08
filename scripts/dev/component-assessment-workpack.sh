#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/component-assessment-workpack.sh --all [--run-id <id>] [--output-root <path>] [--catalog <path>]
  ./scripts/dev/component-assessment-workpack.sh --component <component_id> [--component <component_id> ...] [--run-id <id>] [--output-root <path>] [--catalog <path>]
  ./scripts/dev/component-assessment-workpack.sh --all [--prompt-set <code|docs|all>] [--run-id <id>] [--output-root <path>] [--catalog <path>]
  ./scripts/dev/component-assessment-workpack.sh --all --no-incremental [--prompt-set <code|docs|all>] ...
  ./scripts/dev/component-assessment-workpack.sh --all --only-changed-since <fingerprints.tsv> [--prompt-set <code|docs|all>] ...

Generates component-scoped workpacks for docs/ai/prompt-templates/component-assessment templates.
Workpacks contain:
  - rendered prompts (all categories)
  - component-only context manifests
  - output skeletons for finding consolidation

This script does not perform analysis and does not update docs/component-issues/*.md.

Incremental runs:
  - Default for --all: if tmp state exists, skip unchanged components automatically.
  - Each run writes a fingerprints index: tmp/component-assessment/<run-id>/fingerprints.tsv
  - State lives under: <output_root>/_state/
    - last-fingerprints-<prompt-set>.tsv and last-fingerprints-<prompt-set>/fingerprints/<component_id>.tsv (baseline for next run)
    - by-commit/<git_commit>/<prompt-set>/fingerprints.tsv (archive when worktree is clean)
  - Use --no-incremental to force generating all components.
  - Use --only-changed-since to pin the baseline explicitly.
  - With --write-changed-files (baseline required), the run emits per-component changed file lists (A/M/D).
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
catalog_path="${repo_root}/docs/ai/prompt-templates/component-assessment/component-catalog.tsv"
output_root="${repo_root}/tmp/component-assessment"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
select_all="false"
prompt_set="all"
no_incremental="false"
only_changed_since=""
write_per_file_fingerprints="true"
write_changed_files="false"
declare -a selected_components=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog)
      catalog_path="$2"
      shift 2
      ;;
    --output-root)
      output_root="$2"
      shift 2
      ;;
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --all)
      select_all="true"
      shift
      ;;
    --prompt-set)
      prompt_set="$2"
      shift 2
      ;;
    --component)
      selected_components+=("$2")
      shift 2
      ;;
    --no-incremental)
      no_incremental="true"
      shift
      ;;
    --only-changed-since)
      only_changed_since="$2"
      shift 2
      ;;
    --write-per-file-fingerprints)
      # Backward-compatible no-op: per-file fingerprints are default-on now.
      write_per_file_fingerprints="true"
      shift
      ;;
    --no-per-file-fingerprints)
      write_per_file_fingerprints="false"
      shift
      ;;
    --write-changed-files)
      write_changed_files="true"
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

if [[ "${select_all}" == "true" && ${#selected_components[@]} -gt 0 ]]; then
  echo "ERROR: use either --all or --component (not both)" >&2
  exit 1
fi

if [[ "${select_all}" != "true" && ${#selected_components[@]} -eq 0 ]]; then
  echo "ERROR: specify --all or at least one --component" >&2
  exit 1
fi

case "${prompt_set}" in
  code|docs|all) ;;
  *)
    echo "ERROR: invalid --prompt-set '${prompt_set}' (expected: code|docs|all)" >&2
    exit 2
    ;;
esac

"${repo_root}/scripts/dev/component-assessment-catalog-check.sh" --catalog "${catalog_path}" >/dev/null

mapfile -t template_files < <(
  find \
    "${repo_root}/docs/ai/prompt-templates/component-assessment/operational" \
    "${repo_root}/docs/ai/prompt-templates/component-assessment/security" \
    -maxdepth 1 -type f -name '*.md' | sort
)

if [[ ${#template_files[@]} -eq 0 ]]; then
  echo "ERROR: no templates found under docs/ai/prompt-templates/component-assessment/{operational,security}" >&2
  exit 1
fi

compute_templates_fingerprint() {
  local sha_tool="$1"
  local p=""
  for p in "${selected_template_files[@]}"; do
    [[ ! -f "${p}" ]] && continue
    printf '%s\t%s\n' "$(sha256_of_file "${sha_tool}" "${p}")" "${p#${repo_root}/}"
  done | sort -t $'\t' -k2,2 | sha256_of_stdin "${sha_tool}"
}

uses_docs_allowlist() {
  local template_path="$1"
  local base
  base="$(basename "${template_path}")"
  case "${base}" in
    10-documentation-coverage-and-freshness.md|11-design-doc-vs-implementation-drift.md|13-operations-runbooks-and-usability.md|14-runtime-e2e-matrix-and-release-gating.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

should_include_template() {
  local template_path="$1"
  local rel="${template_path#${repo_root}/docs/ai/prompt-templates/component-assessment/}"
  local dir="${rel%%/*}"

  case "${prompt_set}" in
    code)
      [[ "${dir}" == "security" ]] && return 0
      [[ "${dir}" == "operational" ]] && ! uses_docs_allowlist "${template_path}" && return 0
      return 1
      ;;
    docs)
      [[ "${dir}" == "operational" ]] && uses_docs_allowlist "${template_path}" && return 0
      return 1
      ;;
    all)
      return 0
      ;;
  esac
}

mapfile -t selected_template_files < <(
  for t in "${template_files[@]}"; do
    if should_include_template "${t}"; then
      printf '%s\n' "${t}"
    fi
  done
)

if [[ ${#selected_template_files[@]} -eq 0 ]]; then
  echo "ERROR: no templates selected for --prompt-set ${prompt_set}" >&2
  exit 1
fi

should_include_component() {
  local component_id="$1"
  if [[ "${select_all}" == "true" ]]; then
    return 0
  fi
  local c
  for c in "${selected_components[@]}"; do
    if [[ "${c}" == "${component_id}" ]]; then
      return 0
    fi
  done
  return 1
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

detect_sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
    return 0
  fi
  return 1
}

sha256_of_file() {
  local sha_tool="$1"
  local file="$2"
  # sha256sum/shasum both output "<hash>  <path>".
  ${sha_tool} "${file}" | awk '{print $1}'
}

sha256_of_stdin() {
  local sha_tool="$1"
  # sha256sum/shasum both output "<hash>  -".
  ${sha_tool} | awk '{print $1}'
}

acquire_lock_dir() {
  # mkdir-based lock to avoid relying on flock (not portable on macOS).
  local lock_dir="$1"
  local attempts="${2:-50}"
  local i=0
  while [[ ${i} -lt ${attempts} ]]; do
    if mkdir "${lock_dir}" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

collect_component_files() {
  local out_file="$1"
  shift
  local include_paths=("$@")

  : > "${out_file}"
  local p
  for p in "${include_paths[@]}"; do
    if [[ -f "${repo_root}/${p}" ]]; then
      printf '%s\n' "${p}" >> "${out_file}"
      continue
    fi
    find "${repo_root}/${p}" -type f \
      ! -path '*/.git/*' \
      ! -path '*/tmp/*' \
      ! -path '*/helm/charts/*' \
      ! -path '*/charts/*' \
      ! -path '*/vendor/*' \
      | sed "s|^${repo_root}/||" >> "${out_file}"
  done
}

collect_component_context_files() {
  # Like collect_component_files, but for fingerprinting purposes:
  # - Only hashes files in catalog context paths (not trackers).
  # - Keeps output stable and repo-relative.
  local out_file="$1"
  shift
  local include_paths=("$@")

  collect_component_files "${out_file}" "${include_paths[@]}"
  sort -u -o "${out_file}" "${out_file}"
}

compute_component_fingerprint() {
  local sha_tool="$1"
  local out_manifest="$2" # repo-relative-path<TAB>sha256
  shift 2
  local include_paths=("$@")

  local tmp_list
  tmp_list="$(mktemp)"
  collect_component_context_files "${tmp_list}" "${include_paths[@]}"

  : > "${out_manifest}"
  local rel=""
  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    [[ ! -f "${repo_root}/${rel}" ]] && continue
    printf '%s\t%s\n' "${rel}" "$(sha256_of_file "${sha_tool}" "${repo_root}/${rel}")" >> "${out_manifest}"
  done < "${tmp_list}"

  rm -f "${tmp_list}"

  # Deterministic combined hash: sha256 of lines "sha<TAB>path\n" ordered by path.
  sort -t $'\t' -k1,1 "${out_manifest}" | awk -F'\t' '{print $2 "\t" $1}' | sha256_of_stdin "${sha_tool}"
}

compute_fingerprint_from_file_list() {
  local sha_tool="$1"
  local out_manifest="$2" # repo-relative-path<TAB>sha256
  local file_list="$3"    # repo-relative-path per line

  : > "${out_manifest}"
  local rel=""
  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    [[ "${rel}" =~ ^# ]] && continue
    [[ ! -f "${repo_root}/${rel}" ]] && continue
    printf '%s\t%s\n' "${rel}" "$(sha256_of_file "${sha_tool}" "${repo_root}/${rel}")" >> "${out_manifest}"
  done < "${file_list}"

  sort -t $'\t' -k1,1 "${out_manifest}" | awk -F'\t' '{print $2 "\t" $1}' | sha256_of_stdin "${sha_tool}"
}

collect_docs_matches() {
  local out_file="$1"
  local component_id="$2"
  local issue_slug="$3"
  local primary_path="$4"

  : > "${out_file}"
  # Component docs are best-effort: include docs that mention the component id/slug/path to keep scope tight.
  # This keeps docs-only assessments from being invalidated by unrelated doc edits.
  rg -l -F \
    -e "${component_id}" \
    -e "${issue_slug}" \
    -e "${primary_path}" \
    docs/apis docs/design docs/guides docs/runbooks docs/toils \
    --glob '*.md' 2>/dev/null \
    | sed "s|^${repo_root}/||" \
    | sort -u >> "${out_file}" || true
}

run_dir="${output_root}/${run_id}"
mkdir -p "${run_dir}"

index_file="${run_dir}/index.tsv"
  {
    echo -e "component_id\tissue_slug\tprimary_path\tworkpack_dir\ttemplate_count\ttarget_scope"
  } > "${index_file}"

fingerprints_index="${run_dir}/fingerprints.tsv"
sha_tool="$(detect_sha_tool || true)"
if [[ -z "${sha_tool}" ]]; then
  echo "ERROR: could not find sha256 tool (need sha256sum or shasum)" >&2
  exit 1
fi

templates_fp="$(compute_templates_fingerprint "${sha_tool}")"

state_root="${output_root}/_state"
state_lock="${state_root}/.lock"
last_baseline_fp="${state_root}/last-fingerprints-${prompt_set}.tsv"
last_baseline_per_file_dir="${state_root}/last-fingerprints-${prompt_set}/fingerprints"

if [[ "${select_all}" == "true" && "${no_incremental}" != "true" && -z "${only_changed_since}" && -f "${last_baseline_fp}" ]]; then
  only_changed_since="${last_baseline_fp}"
  # For incremental runs, per-file fingerprints are useful and cheap; keep them enabled unless explicitly disabled.
  # Also default to emitting changed-file lists when the baseline has per-file manifests.
  if [[ "${write_per_file_fingerprints}" == "true" && -d "${last_baseline_per_file_dir}" ]]; then
    write_changed_files="true"
  fi
fi

run_commit="$(git rev-parse HEAD 2>/dev/null || echo "UNKNOWN")"
worktree_clean="unknown"
if git diff --quiet --no-ext-diff >/dev/null 2>&1 && git diff --cached --quiet --no-ext-diff >/dev/null 2>&1; then
  worktree_clean="true"
else
  worktree_clean="false"
fi

{
  echo "# run_id: ${run_id}"
  echo "# git_commit: ${run_commit}"
  echo "# worktree_clean: ${worktree_clean}"
  echo "# templates_sha256: ${templates_fp}"
  echo "# prompt_set: ${prompt_set}"
  echo -e "component_id\tfingerprint_sha256\tfile_count\tbaseline_fingerprint_sha256\tchanged_since_baseline"
} > "${fingerprints_index}"

if [[ -n "${only_changed_since}" && ! -f "${only_changed_since}" ]]; then
  echo "ERROR: baseline fingerprints file not found: ${only_changed_since}" >&2
  exit 1
fi

declare -A baseline_fingerprints=()
baseline_templates_fp=""
templates_changed_since_baseline="unknown"
if [[ -n "${only_changed_since}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ^#\ templates_sha256:\  ]]; then
      baseline_templates_fp="${line#\# templates_sha256: }"
      continue
    fi
    if [[ "${line}" =~ ^# ]]; then
      continue
    fi
    if [[ "${line}" == component_id$'\t'* ]]; then
      continue
    fi
    IFS=$'\t' read -r baseline_component_id baseline_fp baseline_file_count baseline_baseline_fp baseline_changed <<< "${line}"
    [[ -z "${baseline_component_id}" ]] && continue
    baseline_fingerprints["${baseline_component_id}"]="${baseline_fp}"
  done < "${only_changed_since}"

  if [[ -n "${baseline_templates_fp}" ]]; then
    if [[ "${baseline_templates_fp}" == "${templates_fp}" ]]; then
      templates_changed_since_baseline="false"
    else
      templates_changed_since_baseline="true"
    fi
  else
    templates_changed_since_baseline="unknown"
  fi
fi

fingerprints_dir=""
if [[ "${write_per_file_fingerprints}" == "true" ]]; then
  fingerprints_dir="${run_dir}/fingerprints"
  mkdir -p "${fingerprints_dir}"
fi

changed_files_dir=""
changed_components_file=""
baseline_run_dir=""
baseline_per_file_dir=""
if [[ -n "${only_changed_since}" ]]; then
  baseline_run_dir="$(cd "$(dirname "${only_changed_since}")" && pwd -P)"
  if [[ "$(basename "${only_changed_since}")" == "last-fingerprints-${prompt_set}.tsv" ]]; then
    baseline_per_file_dir="${baseline_run_dir}/last-fingerprints-${prompt_set}/fingerprints"
  else
    baseline_per_file_dir="${baseline_run_dir}/fingerprints"
  fi
fi

if [[ "${write_changed_files}" == "true" ]]; then
  if [[ "${prompt_set}" == "all" ]]; then
    echo "ERROR: --write-changed-files is not supported with --prompt-set all (run code and docs separately)" >&2
    exit 1
  fi
  if [[ -z "${only_changed_since}" ]]; then
    echo "ERROR: --write-changed-files requires --only-changed-since" >&2
    exit 1
  fi
  if [[ "${write_per_file_fingerprints}" != "true" ]]; then
    echo "ERROR: --write-changed-files requires per-file fingerprints (default on). Use --no-per-file-fingerprints only when not using --write-changed-files." >&2
    exit 1
  fi
  if [[ ! -d "${baseline_per_file_dir}" ]]; then
    echo "ERROR: baseline per-file fingerprints dir not found: ${baseline_per_file_dir}" >&2
    echo "Hint: generate the baseline with per-file fingerprints (default) so the baseline fingerprints directory exists." >&2
    exit 1
  fi

  changed_files_dir="${run_dir}/changed-files"
  mkdir -p "${changed_files_dir}"
  changed_components_file="${run_dir}/changed-components.tsv"
  echo -e "component_id\tadded\tmodified\tdeleted\tbaseline_fingerprint_sha256\tfingerprint_sha256" > "${changed_components_file}"
fi

generated=0
skipped_disabled=0
skipped_unselected=0
skipped_unchanged=0

while IFS=$'\037' read -r component_id enabled issue_slug primary_path context_paths_csv notes target_scope; do
  [[ -z "${component_id}" ]] && continue

  if ! should_include_component "${component_id}"; then
    skipped_unselected=$((skipped_unselected + 1))
    continue
  fi

  if [[ "${enabled}" != "true" ]]; then
    skipped_disabled=$((skipped_disabled + 1))
    continue
  fi

  if [[ -z "${target_scope}" ]]; then
    target_scope="component"
  fi

  IFS=',' read -r -a context_paths <<< "${context_paths_csv}"

  # Fingerprints:
  # - code fingerprint: only the component catalog context paths (stable, component-scoped)
  # - docs fingerprint: code files + docs matches (component-scoped best-effort)
  tmp_code_files="$(mktemp)"
  collect_component_context_files "${tmp_code_files}" "${context_paths[@]}"
  tmp_code_manifest="$(mktemp)"
  code_fp="$(compute_fingerprint_from_file_list "${sha_tool}" "${tmp_code_manifest}" "${tmp_code_files}")"

  tmp_docs_matches="$(mktemp)"
  tmp_docs_files="$(mktemp)"
  tmp_docs_manifest="$(mktemp)"
  docs_fp="NA"
  if [[ "${prompt_set}" != "code" ]]; then
    collect_docs_matches "${tmp_docs_matches}" "${component_id}" "${issue_slug}" "${primary_path}"
    : > "${tmp_docs_files}"
    cat "${tmp_code_files}" >> "${tmp_docs_files}"
    cat "${tmp_docs_matches}" >> "${tmp_docs_files}"
    # Include component tracker docs as additional context for docs-only prompts.
    if [[ -f "${repo_root}/docs/component-issues/${issue_slug}.md" ]]; then
      printf '%s\n' "docs/component-issues/${issue_slug}.md" >> "${tmp_docs_files}"
    fi
    sort -u -o "${tmp_docs_files}" "${tmp_docs_files}"
    docs_fp="$(compute_fingerprint_from_file_list "${sha_tool}" "${tmp_docs_manifest}" "${tmp_docs_files}")"
  fi

  tmp_manifest="$(mktemp)"
  current_fp=""
  current_file_count="0"
  case "${prompt_set}" in
    code)
      mv "${tmp_code_manifest}" "${tmp_manifest}"
      current_fp="${code_fp}"
      ;;
    docs)
      mv "${tmp_docs_manifest}" "${tmp_manifest}"
      current_fp="${docs_fp}"
      ;;
    all)
      # Combined fingerprint ensures either code or docs changes trigger inclusion.
      current_fp="$(printf '%s\n%s\n' "${code_fp}" "${docs_fp}" | sha256_of_stdin "${sha_tool}")"
      # Per-file manifest for all is not meaningful; keep an empty manifest.
      : > "${tmp_manifest}"
      ;;
  esac
  current_file_count="$(wc -l < "${tmp_manifest}" | tr -d ' ')"

  baseline_fp="NA"
  changed_since_baseline="unknown"
  if [[ -n "${only_changed_since}" ]]; then
    if [[ -n "${baseline_fingerprints[${component_id}]:-}" ]]; then
      baseline_fp="${baseline_fingerprints[${component_id}]}"
      if [[ "${baseline_fp}" == "${current_fp}" ]]; then
        changed_since_baseline="false"
      else
        changed_since_baseline="true"
      fi
    else
      changed_since_baseline="true"
    fi
  fi

  if [[ "${templates_changed_since_baseline}" == "true" ]]; then
    # Even if component content didn't change, template changes warrant re-running prompts.
    changed_since_baseline="true"
  fi

  echo -e "${component_id}\t${current_fp}\t${current_file_count}\t${baseline_fp}\t${changed_since_baseline}" >> "${fingerprints_index}"

  if [[ -n "${fingerprints_dir}" ]]; then
    if [[ "${prompt_set}" != "all" ]]; then
      mv "${tmp_manifest}" "${fingerprints_dir}/${component_id}.tsv"
    else
      rm -f "${tmp_manifest}"
    fi
  else
    rm -f "${tmp_manifest}"
  fi
  # tmp_code_files/tmp_docs_* are cleaned up once we know whether we generate a workpack.

  if [[ -n "${changed_files_dir}" && "${changed_since_baseline}" == "true" && -f "${baseline_per_file_dir}/${component_id}.tsv" ]]; then
    # Emit a per-component changed-files list as: <A|M|D>\t<repo-relative-path>
    awk -F'\t' '
      FNR==NR { base[$1]=$2; next }
      { cur[$1]=$2 }
      END {
        for (p in base) {
          if (!(p in cur)) { print "D\t" p }
          else if (cur[p] != base[p]) { print "M\t" p }
        }
        for (p in cur) {
          if (!(p in base)) { print "A\t" p }
        }
      }
    ' "${baseline_per_file_dir}/${component_id}.tsv" "${fingerprints_dir}/${component_id}.tsv" \
      | sort > "${changed_files_dir}/${component_id}.tsv"

    added_count="$(awk -F'\t' '$1=="A"{c++} END{print c+0}' "${changed_files_dir}/${component_id}.tsv")"
    modified_count="$(awk -F'\t' '$1=="M"{c++} END{print c+0}' "${changed_files_dir}/${component_id}.tsv")"
    deleted_count="$(awk -F'\t' '$1=="D"{c++} END{print c+0}' "${changed_files_dir}/${component_id}.tsv")"
    echo -e "${component_id}\t${added_count}\t${modified_count}\t${deleted_count}\t${baseline_fp}\t${current_fp}" >> "${changed_components_file}"
  fi

  if [[ -n "${only_changed_since}" && "${changed_since_baseline}" == "false" ]]; then
    skipped_unchanged=$((skipped_unchanged + 1))
    rm -f "${tmp_code_files}" "${tmp_docs_matches}" "${tmp_docs_files}" "${tmp_code_manifest}" "${tmp_docs_manifest}"
    continue
  fi

  component_dir="${run_dir}/${component_id}"
  mkdir -p \
    "${component_dir}/context" \
    "${component_dir}/prompts" \
    "${component_dir}/outputs/category-results"

  issue_file="docs/component-issues/${issue_slug}.md"

  {
    echo "RUN_ID=${run_id}"
    echo "COMPONENT_ID=${component_id}"
    echo "TARGET_SCOPE=${target_scope}"
    echo "COMPONENT_NAME=${issue_slug}"
    echo "COMPONENT_PATH=${primary_path}"
    echo "ISSUE_FILE=${issue_file}"
    echo "CONTEXT_PATHS=${context_paths_csv}"
    echo "FINGERPRINT_SHA256=${current_fp}"
    echo "CODE_FINGERPRINT_SHA256=${code_fp}"
    echo "DOCS_FINGERPRINT_SHA256=${docs_fp}"
    echo "PROMPT_SET=${prompt_set}"
  } > "${component_dir}/meta.env"

  {
    printf '%s\n' "${context_paths[@]}"
    printf '%s\n' "${issue_file}"
  } > "${component_dir}/context/paths.txt"

  cp "${tmp_code_files}" "${component_dir}/context/file-list.code.txt"
  sort -u -o "${component_dir}/context/file-list.code.txt" "${component_dir}/context/file-list.code.txt"

  if [[ "${prompt_set}" != "code" ]]; then
    cp "${tmp_docs_files}" "${component_dir}/context/file-list.docs.txt"
    sort -u -o "${component_dir}/context/file-list.docs.txt" "${component_dir}/context/file-list.docs.txt"
    cp "${tmp_docs_matches}" "${component_dir}/context/docs-matches.txt"
  fi

  # Backward-compat: keep file-list.txt as the code allowlist.
  cp "${component_dir}/context/file-list.code.txt" "${component_dir}/context/file-list.txt"

  rm -f "${tmp_code_files}" "${tmp_docs_matches}" "${tmp_docs_files}" "${tmp_code_manifest}" "${tmp_docs_manifest}"

  if [[ -n "${fingerprints_dir}" && -f "${fingerprints_dir}/${component_id}.tsv" ]]; then
    cp "${fingerprints_dir}/${component_id}.tsv" "${component_dir}/context/fingerprint.tsv"
    printf '%s\n' "${current_fp}" > "${component_dir}/context/fingerprint.sha256"
  fi

  if [[ -n "${changed_files_dir}" && -f "${changed_files_dir}/${component_id}.tsv" ]]; then
    cp "${changed_files_dir}/${component_id}.tsv" "${component_dir}/context/changed-files.tsv"
  fi

  cat > "${component_dir}/context/context-contract.md" <<EOF
# Context Contract

- Assessment unit scope: single unit
- Target scope: ${target_scope}
- Component id: ${component_id}
- Canonical issue tracker: \`${issue_file}\`
- Allowed evidence files:
  - Code prompts: \`context/file-list.code.txt\`
  - Docs/ops prompts (operational 10/11/13/14): \`context/file-list.docs.txt\`

Rules:
1. Use only files listed in the prompt's referenced allowlist.
2. Do not pull evidence from other components.
3. If evidence is insufficient for a topic, return the template's NA format.
EOF

  template_count=0
  template_path=""
  for template_path in "${selected_template_files[@]}"; do
    template_rel="${template_path#${repo_root}/docs/ai/prompt-templates/component-assessment/}"
    template_dir="${template_rel%%/*}"
    template_base="$(basename "${template_path}")"
    prompt_name="${template_dir}-${template_base}"
    prompt_out="${component_dir}/prompts/${prompt_name}"
    result_out="${component_dir}/outputs/category-results/${prompt_name}"

    allowlist_path="${component_dir}/context/file-list.code.txt"
    if uses_docs_allowlist "${template_path}"; then
      allowlist_path="${component_dir}/context/file-list.docs.txt"
    fi

    runtime_context_value="Use only files listed in ${allowlist_path}"
    if [[ -f "${component_dir}/context/changed-files.tsv" ]]; then
      runtime_context_value="${runtime_context_value}; start with changed files list: ${component_dir}/context/changed-files.tsv"
    fi
    sed -e "s/<TARGET_SCOPE>/$(escape_sed "${target_scope}")/g" \
        -e "s/<COMPONENT_NAME>/$(escape_sed "${issue_slug}")/g" \
        -e "s/<COMPONENT_PATH>/$(escape_sed "${primary_path}")/g" \
        -e "s/<RUNTIME_CONTEXT>/$(escape_sed "${runtime_context_value}")/g" \
        "${template_path}" > "${prompt_out}"

    cat > "${result_out}" <<EOF
# Result Skeleton: ${prompt_name}

Topic:
Relevance:
Findings (JSONL):
EOF

    template_count=$((template_count + 1))
  done

  cat > "${component_dir}/outputs/merge-template.md" <<EOF
# ${component_id} Consolidation Template

Source files:
- outputs/category-results/*.md

Deduped Findings (for ${issue_file}):
1. <class + severity + title + evidence + recommendation>

Notes:
- Remove duplicates across categories before writing tracker updates.
- Preserve explicit NA entries only in working notes, not in final tracker docs.
EOF

  echo -e "${component_id}\t${issue_slug}\t${primary_path}\t${component_dir}\t${template_count}\t${target_scope}" >> "${index_file}"
  generated=$((generated + 1))
done < <(
  awk -F'\t' '
    BEGIN { OFS = "\037" }
    NF == 0 || $1 ~ /^#/ { next }
    { print $1, $2, $3, $4, $5, $6, $7 }
  ' "${catalog_path}"
)

if [[ "${select_all}" != "true" ]]; then
  c=""
  for c in "${selected_components[@]}"; do
    if ! rg -n "^${c}\ttrue\t" "${catalog_path}" >/dev/null; then
      echo "WARNING: requested component '${c}' is not enabled in catalog or missing." >&2
    fi
  done
fi

cat <<EOF
Workpack run id: ${run_id}
Output root: ${run_dir}
Generated components: ${generated}
Skipped (disabled in catalog): ${skipped_disabled}
Skipped (not selected): ${skipped_unselected}
Skipped (unchanged since baseline): ${skipped_unchanged}
Templates per component: ${#selected_template_files[@]}
Index: ${index_file}
Fingerprints: ${fingerprints_index}
Changed components: ${changed_components_file:-NA}
EOF

if [[ "${select_all}" == "true" ]]; then
  # Persist baseline for the next --all run. Even with a dirty worktree this is useful for local incremental loops.
  # When the worktree is clean, also archive by commit SHA for reproducibility.
  mkdir -p "${state_root}"
  if acquire_lock_dir "${state_lock}" 50; then
    trap 'rmdir "${state_lock}" 2>/dev/null || true' EXIT

    tmp_fp="${state_root}/.last-fingerprints-${prompt_set}.tsv.tmp"
    cp "${fingerprints_index}" "${tmp_fp}"
    mv "${tmp_fp}" "${last_baseline_fp}"

    if [[ "${write_per_file_fingerprints}" == "true" && -d "${fingerprints_dir}" ]]; then
      mkdir -p "${last_baseline_per_file_dir}"
      rm -f "${last_baseline_per_file_dir}/"*.tsv 2>/dev/null || true
      cp "${fingerprints_dir}/"*.tsv "${last_baseline_per_file_dir}/" 2>/dev/null || true
    fi

    if [[ "${worktree_clean}" == "true" && "${run_commit}" != "UNKNOWN" ]]; then
      by_commit_dir="${state_root}/by-commit/${run_commit}/${prompt_set}"
      mkdir -p "${by_commit_dir}"
      cp "${fingerprints_index}" "${by_commit_dir}/fingerprints.tsv"
      if [[ "${write_per_file_fingerprints}" == "true" && -d "${fingerprints_dir}" ]]; then
        mkdir -p "${by_commit_dir}/fingerprints"
        rm -f "${by_commit_dir}/fingerprints/"*.tsv 2>/dev/null || true
        cp "${fingerprints_dir}/"*.tsv "${by_commit_dir}/fingerprints/" 2>/dev/null || true
      fi
    fi

    printf '%s\n' "${run_commit}" > "${state_root}/last-commit.txt"
    printf '%s\n' "${run_id}" > "${state_root}/last-run-id.txt"
    printf '%s\n' "${worktree_clean}" > "${state_root}/last-worktree-clean.txt"
    trap - EXIT
    rmdir "${state_lock}" 2>/dev/null || true
  else
    echo "WARNING: could not acquire state lock at ${state_lock}; skipping baseline update" >&2
  fi
fi
