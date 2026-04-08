#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/learnings-distill.sh [options]

Scans .learnings/ERRORS.md and .learnings/LEARNINGS.md, detects stale pending entries,
and prints candidate actions for distillation.

Default output mode is compact (token-efficient for agent calls).

Options:
  --mode <compact|human|verbose>  Output mode (default: compact)
  --human                         Alias for --mode human
  --verbose                       Alias for --mode verbose
  --stale-days <n>                Pending age threshold for stale (default: 14)
  --max-ids <n>                   Max IDs printed per compact line (default: 20)
  --write-report <path>           Write markdown report
  --check                         Exit non-zero when stale pending entries exist
  --check-pending                 Exit non-zero when any pending entries exist
  -h, --help                      Show this help

Examples:
  ./scripts/dev/learnings-distill.sh
  ./scripts/dev/learnings-distill.sh --human
  ./scripts/dev/learnings-distill.sh --verbose --stale-days 7
  ./scripts/dev/learnings-distill.sh --check
  ./scripts/dev/learnings-distill.sh --write-report tmp/learnings-distill-report.md
EOF
}

require_positive_int() {
  local value="$1"
  local name="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be a non-negative integer: ${value}" >&2
    exit 2
  fi
}

iso_to_epoch() {
  local ts="$1"
  if [[ -z "${ts}" || "${ts}" == "unknown" ]]; then
    return 1
  fi
  if command -v gdate >/dev/null 2>&1; then
    gdate -u -d "${ts}" +%s 2>/dev/null
    return $?
  fi
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${ts}" +%s 2>/dev/null
}

join_ids_limited() {
  local max="$1"
  shift
  local total="$#"
  if [[ "${total}" == "0" ]]; then
    printf '%s' "-"
    return 0
  fi

  local n="${total}"
  if (( n > max )); then
    n="${max}"
  fi

  local out=""
  local i
  for (( i=1; i<=n; i++ )); do
    local id="${!i}"
    if [[ -z "${out}" ]]; then
      out="${id}"
    else
      out="${out},${id}"
    fi
  done

  if (( total > max )); then
    local extra=$(( total - max ))
    out="${out},+${extra}more"
  fi

  printf '%s' "${out}"
}

collect_entries() {
  local file="$1"
  awk -v source_file="${file}" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function emit() {
      if (id == "") return
      if (status == "") status = "unknown"
      if (priority == "") priority = "unknown"
      if (logged == "") logged = "unknown"
      if (area == "") area = "unknown"
      gsub(/\t/, " ", summary)
      print source_file "\t" id "\t" title "\t" status "\t" priority "\t" logged "\t" area "\t" summary
    }
    /^## \[/ {
      emit()
      id = ""; title = ""; status = ""; priority = ""; logged = ""; area = ""; summary = ""
      mode = ""

      line = $0
      sub(/^## \[/, "", line)
      split(line, parts, "] ")
      id = parts[1]
      title = substr(line, length(id) + 3)
      next
    }
    /^\*\*Logged\*\*:/   { logged = $2; next }
    /^\*\*Priority\*\*:/ { priority = $2; next }
    /^\*\*Status\*\*:/   { status = $2; next }
    /^\*\*Area\*\*:/     { area = $2; next }
    /^### Summary/       { mode = "summary"; next }
    /^### /              { mode = ""; next }
    {
      if (mode == "summary" && summary == "" && trim($0) != "") {
        summary = trim($0)
        mode = "summary_done"
      }
    }
    END {
      emit()
    }
  ' "${file}"
}

mode="compact"
stale_days=14
max_ids=20
write_report=""
check_stale="false"
check_pending="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --human)
      mode="human"
      shift
      ;;
    --verbose)
      mode="verbose"
      shift
      ;;
    --stale-days)
      stale_days="${2:-}"
      shift 2
      ;;
    --max-ids)
      max_ids="${2:-}"
      shift 2
      ;;
    --write-report)
      write_report="${2:-}"
      shift 2
      ;;
    --check)
      check_stale="true"
      shift
      ;;
    --check-pending)
      check_pending="true"
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

case "${mode}" in
  compact|human|verbose)
    ;;
  *)
    echo "ERROR: unsupported mode: ${mode}" >&2
    exit 2
    ;;
esac

require_positive_int "${stale_days}" "--stale-days"
require_positive_int "${max_ids}" "--max-ids"
if [[ "${max_ids}" == "0" ]]; then
  echo "ERROR: --max-ids must be greater than 0" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
learnings_dir="${repo_root}/.learnings"
errors_file="${learnings_dir}/ERRORS.md"
learnings_file="${learnings_dir}/LEARNINGS.md"

tmp_entries="$(mktemp)"
cleanup() {
  rm -f "${tmp_entries}"
}
trap cleanup EXIT

if [[ -f "${errors_file}" ]]; then
  collect_entries "${errors_file}" >> "${tmp_entries}"
fi
if [[ -f "${learnings_file}" ]]; then
  collect_entries "${learnings_file}" >> "${tmp_entries}"
fi

total=0
errors_count=0
learnings_count=0
pending=0
stale=0
promoted=0
resolved=0
in_progress=0
wont_fix=0
other=0

pending_ids=()
stale_ids=()
promote_candidate_ids=()
resolve_candidate_ids=()
pending_entries=()
stale_entries=()
all_entries=()

now_epoch="$(date -u +%s)"
now_iso="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"

if [[ -s "${tmp_entries}" ]]; then
  while IFS=$'\t' read -r source_file id title status priority logged area summary; do
    [[ -z "${id}" ]] && continue

    local_kind="learning"
    if [[ "${source_file}" == *"/ERRORS.md" ]]; then
      local_kind="error"
      errors_count=$(( errors_count + 1 ))
    else
      learnings_count=$(( learnings_count + 1 ))
    fi

    age_days="-1"
    if logged_epoch="$(iso_to_epoch "${logged}")"; then
      delta=$(( now_epoch - logged_epoch ))
      if (( delta < 0 )); then
        delta=0
      fi
      age_days=$(( delta / 86400 ))
    fi

    entry="${id}"$'\t'"${local_kind}"$'\t'"${status}"$'\t'"${priority}"$'\t'"${logged}"$'\t'"${age_days}"$'\t'"${area}"$'\t'"${summary}"$'\t'"${source_file}"$'\t'"${title}"
    all_entries+=( "${entry}" )
    total=$(( total + 1 ))

    case "${status}" in
      pending)
        pending=$(( pending + 1 ))
        pending_ids+=( "${id}" )
        pending_entries+=( "${entry}" )
        if [[ "${local_kind}" == "learning" ]]; then
          promote_candidate_ids+=( "${id}" )
        else
          resolve_candidate_ids+=( "${id}" )
        fi
        if [[ "${age_days}" != "-1" ]] && (( age_days >= stale_days )); then
          stale=$(( stale + 1 ))
          stale_ids+=( "${id}" )
          stale_entries+=( "${entry}" )
        fi
        ;;
      promoted)
        promoted=$(( promoted + 1 ))
        ;;
      resolved)
        resolved=$(( resolved + 1 ))
        ;;
      in_progress)
        in_progress=$(( in_progress + 1 ))
        ;;
      wont_fix)
        wont_fix=$(( wont_fix + 1 ))
        ;;
      *)
        other=$(( other + 1 ))
        ;;
    esac
  done < "${tmp_entries}"
fi

print_compact() {
  echo "SUMMARY total=${total} errors=${errors_count} learnings=${learnings_count} pending=${pending} stale=${stale} resolved=${resolved} promoted=${promoted} in_progress=${in_progress} wont_fix=${wont_fix} other=${other} stale_days=${stale_days}"
  if (( pending > 0 )); then
    echo "PENDING_IDS $(join_ids_limited "${max_ids}" "${pending_ids[@]}")"
  fi
  if (( stale > 0 )); then
    echo "STALE_IDS $(join_ids_limited "${max_ids}" "${stale_ids[@]}")"
  fi
  if (( ${#promote_candidate_ids[@]} > 0 )); then
    echo "PROMOTE_CANDIDATES $(join_ids_limited "${max_ids}" "${promote_candidate_ids[@]}")"
  fi
  if (( ${#resolve_candidate_ids[@]} > 0 )); then
    echo "RESOLVE_CANDIDATES $(join_ids_limited "${max_ids}" "${resolve_candidate_ids[@]}")"
  fi
}

print_human_entries() {
  local label="$1"
  shift
  local entries=( "$@" )
  echo "${label}: ${#entries[@]}"
  local row
  for row in "${entries[@]}"; do
    IFS=$'\t' read -r id kind status priority logged age_days area summary source_file title <<< "${row}"
    local age_view="unknown"
    if [[ "${age_days}" != "-1" ]]; then
      age_view="${age_days}d"
    fi
    printf '  - %s | %s | %s | priority=%s | age=%s | %s\n' "${id}" "${kind}" "${status}" "${priority}" "${age_view}" "${summary}"
  done
}

print_human() {
  echo "Learnings Distillation"
  echo "Repo: ${repo_root}"
  echo "Generated: ${now_iso}"
  echo "Stale threshold: ${stale_days}d"
  echo
  echo "Counts: total=${total} errors=${errors_count} learnings=${learnings_count} pending=${pending} stale=${stale} resolved=${resolved} promoted=${promoted} in_progress=${in_progress} wont_fix=${wont_fix} other=${other}"
  echo
  print_human_entries "Pending entries" "${pending_entries[@]}"
  echo
  print_human_entries "Stale pending entries" "${stale_entries[@]}"
  echo
  if (( ${#promote_candidate_ids[@]} > 0 )); then
    echo "Promote candidates (learning pending IDs): $(join_ids_limited 9999 "${promote_candidate_ids[@]}")"
  else
    echo "Promote candidates: -"
  fi
  if (( ${#resolve_candidate_ids[@]} > 0 )); then
    echo "Resolve candidates (error pending IDs): $(join_ids_limited 9999 "${resolve_candidate_ids[@]}")"
  else
    echo "Resolve candidates: -"
  fi
}

print_verbose() {
  echo -e "id\tkind\tstatus\tpriority\tlogged\tage_days\tarea\tsummary\ttitle\tsource_file"
  local row
  for row in "${all_entries[@]}"; do
    IFS=$'\t' read -r id kind status priority logged age_days area summary source_file title <<< "${row}"
    echo -e "${id}\t${kind}\t${status}\t${priority}\t${logged}\t${age_days}\t${area}\t${summary}\t${title}\t${source_file}"
  done
}

write_markdown_report() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"

  {
    echo "# Learnings Distillation Report"
    echo
    echo "- Generated: ${now_iso}"
    echo "- Repo: \`${repo_root}\`"
    echo "- Stale threshold: ${stale_days} days"
    echo
    echo "## Summary"
    echo
    echo "| total | errors | learnings | pending | stale | resolved | promoted | in_progress | wont_fix | other |"
    echo "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    echo "| ${total} | ${errors_count} | ${learnings_count} | ${pending} | ${stale} | ${resolved} | ${promoted} | ${in_progress} | ${wont_fix} | ${other} |"
    echo
    echo "## Pending Entries"
    echo
    if (( ${#pending_entries[@]} == 0 )); then
      echo "_None._"
    else
      echo "| id | kind | priority | age_days | logged | area | summary | suggested_action |"
      echo "|---|---|---|---:|---|---|---|---|"
      local row
      for row in "${pending_entries[@]}"; do
        IFS=$'\t' read -r id kind status priority logged age_days area summary source_file title <<< "${row}"
        local action="resolve"
        if [[ "${kind}" == "learning" ]]; then
          action="promote_or_resolve"
        fi
        local age_cell="${age_days}"
        if [[ "${age_cell}" == "-1" ]]; then
          age_cell="unknown"
        fi
        printf '| `%s` | %s | %s | %s | %s | %s | %s | %s |\n' \
          "${id}" "${kind}" "${priority}" "${age_cell}" "${logged}" "${area}" "${summary}" "${action}"
      done
    fi
    echo
    echo "## Stale Pending Entries"
    echo
    if (( ${#stale_entries[@]} == 0 )); then
      echo "_None._"
    else
      echo "| id | kind | priority | age_days | logged | area | summary |"
      echo "|---|---|---|---:|---|---|---|"
      local stale_row
      for stale_row in "${stale_entries[@]}"; do
        IFS=$'\t' read -r id kind status priority logged age_days area summary source_file title <<< "${stale_row}"
        printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' \
          "${id}" "${kind}" "${priority}" "${age_days}" "${logged}" "${area}" "${summary}"
      done
    fi
    echo
    echo "## Candidate ID Sets"
    echo
    echo "- Promote candidates: $(join_ids_limited 9999 "${promote_candidate_ids[@]}")"
    echo "- Resolve candidates: $(join_ids_limited 9999 "${resolve_candidate_ids[@]}")"
  } > "${path}"
}

case "${mode}" in
  compact)
    print_compact
    ;;
  human)
    print_human
    ;;
  verbose)
    print_verbose
    ;;
esac

if [[ -n "${write_report}" ]]; then
  write_markdown_report "${write_report}"
fi

check_failed="false"
if [[ "${check_stale}" == "true" ]] && (( stale > 0 )); then
  echo "CHECK_FAILED stale_pending=${stale} threshold_days=${stale_days}" >&2
  check_failed="true"
fi
if [[ "${check_pending}" == "true" ]] && (( pending > 0 )); then
  echo "CHECK_FAILED pending=${pending}" >&2
  check_failed="true"
fi

if [[ "${check_failed}" == "true" ]]; then
  exit 1
fi
