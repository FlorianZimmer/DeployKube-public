#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require kustomize
require yq

echo "==> Validating protected CronJobs are not scheduled at :00 hourly"

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

schedule_for() {
  local rendered="$1"
  local namespace="$2"
  local name="$3"
  printf '%s\n' "${rendered}" | yq -r "
    select(.kind == \"CronJob\" and .metadata.name == \"${name}\" and (.metadata.namespace // \"\") == \"${namespace}\")
    | .spec.schedule // \"\"
  " | head -n 1
}

is_forbidden_hourly_minute_zero() {
  local schedule="$1"
  # Only guard against the main offender pattern: hourly at top-of-hour.
  # (Daily/weekly schedules at minute 0 are allowed.)
  printf '%s' "${schedule}" | grep -Eq '^0[[:space:]]+(\*|\*/1)[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*$'
}

check() {
  local rendered="$1"
  local namespace="$2"
  local name="$3"

  local schedule
  schedule="$(schedule_for "${rendered}" "${namespace}" "${name}")"
  if [ -z "${schedule}" ]; then
    fail "CronJob/${name} in namespace ${namespace}: schedule not found in rendered manifests"
    return 0
  fi

  if is_forbidden_hourly_minute_zero "${schedule}"; then
    fail "CronJob/${name} in namespace ${namespace}: schedule='${schedule}' (forbidden top-of-hour hourly schedule)"
    return 0
  fi

  echo "OK: ${namespace}/CronJob/${name} schedule='${schedule}'"
}

render_backup_system="$(kustomize build platform/gitops/components/storage/backup-system/overlays/proxmox-talos)"
check "${render_backup_system}" "backup-system" "storage-s3-mirror-to-backup-target"
check "${render_backup_system}" "backup-system" "storage-smoke-backup-target-write"

render_vault="$(kustomize build platform/gitops/components/secrets/vault/overlays/proxmox-talos/config)"
check "${render_vault}" "vault-system" "vault-raft-backup"

render_pg_keycloak="$(kustomize build platform/gitops/components/data/postgres/keycloak/overlays/proxmox-talos)"
check "${render_pg_keycloak}" "keycloak" "postgres-backup"

render_pg_powerdns="$(kustomize build platform/gitops/components/data/postgres/powerdns/overlays/proxmox-talos)"
check "${render_pg_powerdns}" "dns-system" "postgres-backup"

render_pg_forgejo="$(kustomize build platform/gitops/components/platform/forgejo/postgres/overlays/proxmox-talos)"
check "${render_pg_forgejo}" "forgejo" "postgres-backup"

if [ "${failures}" -ne 0 ]; then
  echo "" >&2
  echo "de-herd schedule validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "de-herd schedule validation PASSED"
