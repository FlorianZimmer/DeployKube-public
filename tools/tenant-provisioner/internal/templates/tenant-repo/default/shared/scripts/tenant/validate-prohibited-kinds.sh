#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: validate-prohibited-kinds.sh [--config <path>] <rendered.yaml...>

Validates that rendered tenant manifests do not contain prohibited kinds.

Notes:
- This gate is intended for tenant workload repos (repo-per-project product mode).
- It is a static gate: it does not require cluster access.
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

config="${script_dir}/../../contracts/tenant-prohibited-kinds.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --config)
      config="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "${config}" ]]; then
  echo "error: --config requires a value" >&2
  exit 2
fi

if [[ ! -f "${config}" ]]; then
  echo "error: prohibited kinds config not found: ${config}" >&2
  exit 2
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

require yq

mapfile -t prohibited < <(yq -r '.items[] | [.group, .kind] | @tsv' "${config}")
if [[ "${#prohibited[@]}" -eq 0 ]]; then
  echo "error: prohibited kinds config is empty: ${config}" >&2
  exit 2
fi

failures=0

for f in "$@"; do
  if [[ ! -f "${f}" ]]; then
    echo "error: input file not found: ${f}" >&2
    exit 2
  fi

  while IFS=$'\t' read -r api_version kind name namespace; do
    if [[ -z "${api_version}" || -z "${kind}" ]]; then
      continue
    fi

    group=""
    if [[ "${api_version}" == */* ]]; then
      group="${api_version%%/*}"
    fi

    for entry in "${prohibited[@]}"; do
      p_group="${entry%%$'\t'*}"
      p_kind="${entry#*$'\t'}"

      if [[ "${p_group}" != "*" && "${p_group}" != "${group}" ]]; then
        continue
      fi
      if [[ "${p_kind}" != "*" && "${p_kind}" != "${kind}" ]]; then
        continue
      fi

      id=""
      if [[ -n "${namespace}" && -n "${name}" ]]; then
        id=" ${namespace}/${name}"
      elif [[ -n "${name}" ]]; then
        id=" ${name}"
      fi

      echo "FAIL: ${f}: prohibited kind: ${api_version} ${kind}${id}" >&2
      failures=$((failures + 1))
      break
    done
  done < <(yq eval-all -r '. | select(.apiVersion and .kind) | [.apiVersion, .kind, (.metadata.name // ""), (.metadata.namespace // "")] | @tsv' "${f}")
done

if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi
