#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: run-tenant-pr-gates.sh --org-id <orgId> --project-id <projectId> [--repo-root <dir>] [--skip-secret-scan]

Runs the standard static PR gates for a tenant workload repo:
- renderability (kustomize build for each overlay)
- prohibited kinds
- namespace boundary checks
- policy-aware lint
- secret scanning (gitleaks)
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

org_id=""
project_id=""
repo_root="."
skip_secret_scan="false"
overlays_dir="overlays"

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
    --repo-root)
      repo_root="${2:-}"
      shift 2
      ;;
    --overlays-dir)
      overlays_dir="${2:-}"
      shift 2
      ;;
    --skip-secret-scan)
      skip_secret_scan="true"
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${org_id}" || -z "${project_id}" ]]; then
  echo "error: --org-id and --project-id are required" >&2
  usage >&2
  exit 2
fi

if [[ -z "${repo_root}" || ! -d "${repo_root}" ]]; then
  echo "error: --repo-root must be a directory (got: ${repo_root})" >&2
  exit 2
fi

repo_root="$(cd "${repo_root}" && pwd)"
overlays_path="${repo_root}/${overlays_dir}"

if [[ ! -d "${overlays_path}" ]]; then
  echo "error: missing overlays dir: ${overlays_path}" >&2
  exit 2
fi

require kustomize

mapfile -t overlay_dirs < <(find "${overlays_path}" -maxdepth 1 -mindepth 1 -type d | sort)
if [[ "${#overlay_dirs[@]}" -eq 0 ]]; then
  echo "error: no overlays found under ${overlays_path}" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}" || true
}
trap cleanup EXIT INT TERM

failures=0

for overlay in "${overlay_dirs[@]}"; do
  overlay_name="$(basename "${overlay}")"
  out="${tmpdir}/rendered-${overlay_name}.yaml"

  echo "==> render: overlays/${overlay_name}"
  if ! kustomize build "${overlay}" --enable-helm >"${out}" 2>"${out}.stderr"; then
    echo "FAIL: kustomize build failed for overlays/${overlay_name}" >&2
    sed -n '1,120p' "${out}.stderr" >&2 || true
    failures=$((failures + 1))
    continue
  fi

  if ! "${script_dir}/validate-prohibited-kinds.sh" "${out}"; then
    failures=$((failures + 1))
  fi

  if ! "${script_dir}/validate-namespace-boundary.sh" --org-id "${org_id}" --project-id "${project_id}" "${out}"; then
    failures=$((failures + 1))
  fi

  if ! "${script_dir}/validate-policy-aware-lint.sh" --org-id "${org_id}" "${out}"; then
    failures=$((failures + 1))
  fi
done

if [[ "${skip_secret_scan}" != "true" ]]; then
  echo "==> secret scan: gitleaks"
  if ! "${script_dir}/validate-no-secrets-in-git.sh" --source "${repo_root}"; then
    failures=$((failures + 1))
  fi
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "tenant PR gates FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "tenant PR gates PASSED"
