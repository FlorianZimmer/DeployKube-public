#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl not found (needed for 'kubectl kustomize')" >&2
  exit 1
fi

mapfile -t kustomizations < <(
  find platform/gitops/components -type f -name kustomization.yaml \
    | rg '/(tests|smoke-tests|smoke)/' \
    | sort
)

if [ "${#kustomizations[@]}" -eq 0 ]; then
  echo "no validation kustomizations found under platform/gitops/components/**/{tests,smoke-tests,smoke}" >&2
  exit 1
fi

failures=0

check_required() {
  local doc="$1"
  local kind="$2"
  local name="$3"
  shift 3
  local missing=0
  for key in "$@"; do
    if ! rg -n -q "^[[:space:]]*${key}[[:space:]]*:" "${doc}"; then
      echo "  missing: ${key}:" >&2
      missing=1
    fi
  done
  if [ "${missing}" -ne 0 ]; then
    echo "FAIL: ${kind}/${name} missing required fields" >&2
    return 1
  fi
  return 0
}

scan_smoke_files() {
  echo ""
  echo "==> scanning for smoke Jobs/CronJobs outside kustomize bundles"

  mapfile -t smoke_files < <(
    rg -l "\\bsmoke\\b" platform/gitops/components \
      -g'*.yaml' \
      -g'!**/charts/**' \
      -g'!**/helm/charts/**' \
      -g'!**/templates/tests/**' \
      -g'!**/overlays/**/patch-*.yaml' \
      | sort
  )

  local sf
  for sf in "${smoke_files[@]}"; do
    # Skip files already covered by kustomize bundle checks (keeps output smaller).
    if [[ "${sf}" == */tests/* ]] || [[ "${sf}" == */smoke-tests/* ]]; then
      continue
    fi

    local file_tmp
    file_tmp="$(mktemp -d)"
    cp "${sf}" "${file_tmp}/all.yaml"

    awk -v out="${file_tmp}/doc-" '
      BEGIN { n=0; f=sprintf("%s%03d.yaml", out, n) }
      /^---$/ { n++; f=sprintf("%s%03d.yaml", out, n); next }
      { print > f }
    ' "${file_tmp}/all.yaml"

    local found_local=0
    local doc kind name
    for doc in "${file_tmp}"/doc-*.yaml; do
      [ -s "${doc}" ] || continue
      kind="$(awk -F': *' '/^kind:/{print $2; exit}' "${doc}")"
      name="$(awk '/^metadata:/{m=1} m && /^  name:/{print $2; exit}' "${doc}")"
      [ -n "${kind}" ] || continue
      [ -n "${name}" ] || name="(unknown)"

      if [ "${kind}" != "Job" ] && [ "${kind}" != "CronJob" ]; then
        continue
      fi

      # Only enforce for actual smoke jobs (name or labels mention "smoke").
      if ! echo "${name}" | rg -q "smoke"; then
        if ! rg -n -q "smoke" "${doc}"; then
          continue
        fi
      fi

      found_local=1
      echo "==> ${sf}"

      if [ "${kind}" = "Job" ]; then
        echo "- Job/${name}"
        if ! check_required "${doc}" "${kind}" "${name}" "activeDeadlineSeconds" "backoffLimit" "ttlSecondsAfterFinished" "restartPolicy"; then
          failures=$((failures + 1))
        fi
      else
        echo "- CronJob/${name}"
        if ! check_required "${doc}" "${kind}" "${name}" "schedule" "concurrencyPolicy" "startingDeadlineSeconds" "successfulJobsHistoryLimit" "failedJobsHistoryLimit"; then
          failures=$((failures + 1))
        fi
        if ! rg -n -q "^[[:space:]]*ttlSecondsAfterFinished[[:space:]]*:" "${doc}"; then
          echo "  missing: ttlSecondsAfterFinished: (under jobTemplate)" >&2
          failures=$((failures + 1))
        fi
        if ! rg -n -q "^[[:space:]]*activeDeadlineSeconds[[:space:]]*:" "${doc}"; then
          echo "  missing: activeDeadlineSeconds: (under jobTemplate)" >&2
          failures=$((failures + 1))
        fi
        if ! rg -n -q "^[[:space:]]*backoffLimit[[:space:]]*:" "${doc}"; then
          echo "  missing: backoffLimit: (under jobTemplate)" >&2
          failures=$((failures + 1))
        fi
        if ! rg -n -q "^[[:space:]]*restartPolicy[[:space:]]*:" "${doc}"; then
          echo "  missing: restartPolicy: (under jobTemplate.template.spec)" >&2
          failures=$((failures + 1))
        fi
      fi
    done

    rm -rf "${file_tmp}"
    if [ "${found_local}" -eq 0 ]; then
      continue
    fi
  done
}

for kfile in "${kustomizations[@]}"; do
  dir="$(dirname "${kfile}")"
  echo "==> ${dir}"

  rendered="$(kubectl kustomize "${dir}" 2>&1)" || {
    echo "${rendered}" >&2
    echo "FAIL: kustomize render failed for ${dir}" >&2
    failures=$((failures + 1))
    continue
  }

  tmpdir="$(mktemp -d)"
  printf '%s\n' "${rendered}" > "${tmpdir}/all.yaml"

  # Split multi-doc YAML on '---' (portable; macOS csplit lacks GNU flags).
  awk -v out="${tmpdir}/doc-" '
    BEGIN { n=0; f=sprintf("%s%03d.yaml", out, n) }
    /^---$/ { n++; f=sprintf("%s%03d.yaml", out, n); next }
    { print > f }
  ' "${tmpdir}/all.yaml"

  found=0
  for doc in "${tmpdir}"/doc-*.yaml; do
    [ -s "${doc}" ] || continue
    kind="$(awk -F': *' '/^kind:/{print $2; exit}' "${doc}")"
    name="$(awk '/^metadata:/{m=1} m && /^  name:/{print $2; exit}' "${doc}")"
    [ -n "${kind}" ] || continue
    [ -n "${name}" ] || name="(unknown)"

    if [ "${kind}" = "Job" ]; then
      found=1
      echo "- Job/${name}"
      if ! check_required "${doc}" "${kind}" "${name}" "activeDeadlineSeconds" "backoffLimit" "ttlSecondsAfterFinished" "restartPolicy"; then
        failures=$((failures + 1))
      fi
    elif [ "${kind}" = "CronJob" ]; then
      found=1
      echo "- CronJob/${name}"
      if ! check_required "${doc}" "${kind}" "${name}" "schedule" "concurrencyPolicy" "startingDeadlineSeconds" "successfulJobsHistoryLimit" "failedJobsHistoryLimit"; then
        failures=$((failures + 1))
      fi
      if ! rg -n -q "^[[:space:]]*jobTemplate[[:space:]]*:" "${doc}"; then
        echo "  missing: jobTemplate:" >&2
        echo "FAIL: ${kind}/${name} missing required fields" >&2
        failures=$((failures + 1))
      fi
      if ! rg -n -q "^[[:space:]]*activeDeadlineSeconds[[:space:]]*:" "${doc}"; then
        echo "  missing: activeDeadlineSeconds: (under jobTemplate)" >&2
        failures=$((failures + 1))
      fi
      if ! rg -n -q "^[[:space:]]*ttlSecondsAfterFinished[[:space:]]*:" "${doc}"; then
        echo "  missing: ttlSecondsAfterFinished: (under jobTemplate)" >&2
        failures=$((failures + 1))
      fi
      if ! rg -n -q "^[[:space:]]*backoffLimit[[:space:]]*:" "${doc}"; then
        echo "  missing: backoffLimit: (under jobTemplate)" >&2
        failures=$((failures + 1))
      fi
      if ! rg -n -q "^[[:space:]]*restartPolicy[[:space:]]*:" "${doc}"; then
        echo "  missing: restartPolicy: (under jobTemplate.template.spec)" >&2
        failures=$((failures + 1))
      fi
    fi
  done

  rm -rf "${tmpdir}"

  if [ "${found}" -eq 0 ]; then
    echo "FAIL: no Job/CronJob found in rendered output (directory name suggests validation bundle)" >&2
    failures=$((failures + 1))
  fi
done

scan_smoke_files

if [ "${failures}" -ne 0 ]; then
  echo "" >&2
  echo "validation job lint FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo ""
echo "validation job lint PASSED"
