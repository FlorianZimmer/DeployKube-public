#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "FAIL: kubectl not found (needed for 'kubectl kustomize')" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "FAIL: rg not found" >&2
  exit 1
fi

manifest="platform/gitops/components/storage/backup-system/base/cronjob-smoke-full-restore-staleness.yaml"
rendered="$(kubectl kustomize platform/gitops/components/storage/backup-system/base 2>&1)" || {
  echo "${rendered}" >&2
  echo "FAIL: kustomize render failed for backup-system base" >&2
  exit 1
}

tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT
printf '%s\n' "${rendered}" > "${tmpfile}"

cronjob_block="$(awk '
  /^---$/ { capture=0 }
  /^kind: CronJob$/ { kind=1; block=$0 ORS; next }
  kind {
    block = block $0 ORS
    if ($0 == "  name: storage-smoke-full-restore-staleness") {
      capture=1
    }
    if (capture && /^spec:$/) {
      print block
      exit
    }
  }
' "${tmpfile}")"

if [ -z "${cronjob_block}" ]; then
  echo "FAIL: rendered backup-system base is missing CronJob/storage-smoke-full-restore-staleness" >&2
  exit 1
fi

if ! printf '%s\n' "${cronjob_block}" | rg -F -q 'argocd.argoproj.io/ignore-healthcheck: "true"'; then
  echo "FAIL: rendered backup-system base is missing ignore-healthcheck on storage-smoke-full-restore-staleness" >&2
  echo "expected source manifest: ${manifest}" >&2
  exit 1
fi

echo "backup-system full-restore healthcheck ignore validation PASSED"
