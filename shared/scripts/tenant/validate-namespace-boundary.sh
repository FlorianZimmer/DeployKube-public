#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: validate-namespace-boundary.sh --org-id <orgId> --project-id <projectId> <rendered.yaml...>

Fails if any rendered namespaced resource explicitly targets a namespace outside the
expected tenant namespace prefix:

  t-<orgId>-p-<projectId>-*

Notes:
- Resources without metadata.namespace are allowed (Argo applies them into the Application destination namespace).
- This is a static PR gate: it does not require cluster access.
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

org_id=""
project_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --org-id)
      org_id="${2:-}"
      shift 2
      ;;
    --project-id)
      project_id="${2:-}"
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

if [[ -z "${org_id}" || -z "${project_id}" ]]; then
  echo "error: --org-id and --project-id are required" >&2
  usage >&2
  exit 2
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

require yq

expected_prefix="t-${org_id}-p-${project_id}-"
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
    if [[ -z "${namespace}" ]]; then
      continue
    fi
    if [[ "${namespace}" != "${expected_prefix}"* ]]; then
      id=" ${namespace}/${name}"
      if [[ -z "${name}" ]]; then
        id=" ${namespace}"
      fi
      echo "FAIL: ${f}: namespace boundary violation: ${api_version} ${kind}${id} (expected prefix: ${expected_prefix})" >&2
      failures=$((failures + 1))
    fi
  done < <(yq eval-all -r '. | select(.apiVersion and .kind) | [.apiVersion, .kind, (.metadata.name // ""), (.metadata.namespace // "")] | @tsv' "${f}")
done

if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi
