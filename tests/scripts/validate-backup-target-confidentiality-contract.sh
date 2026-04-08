#!/usr/bin/env bash
# validate-backup-target-confidentiality-contract.sh
# Repo-only guardrail for the "hostile NFS" confidentiality contract.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency '${bin}'" >&2
    exit 1
  fi
}

require rg
require yq

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

require_pattern() {
  local file="$1"
  local label="$2"
  local pattern="$3"
  if ! rg -n -q --regexp "${pattern}" "${file}"; then
    fail "${label} (${file})"
  fi
}

echo "==> Validating backup target confidentiality contract"

proxmox_config="platform/gitops/deployments/proxmox-talos/config.yaml"
backup_readme="platform/gitops/components/storage/backup-system/README.md"
backup_guide="docs/guides/backups-and-dr.md"
synology_guide="docs/guides/synology-dsm-nfs-backup-target.md"
backup_set_assemble="platform/gitops/components/storage/backup-system/base/cronjob-backup-set-assemble.yaml"
backup_pvc_restic="platform/gitops/components/storage/backup-system/base/cronjob-pvc-restic-backup.yaml"

mirror_mode="$(yq -r '.spec.backup.s3Mirror.mode // ""' "${proxmox_config}")"
if [[ "${mirror_mode}" != "s3-replication" ]]; then
  fail "proxmox deployment config must set spec.backup.s3Mirror.mode=s3-replication (got '${mirror_mode}')"
fi

require_pattern "${backup_set_assemble}" "recovery bundle encrypted with age" 'recovery-bundle\.json\.age'
require_pattern "${backup_set_assemble}" "recovery bundle plaintext removed after encryption" 'recovery_plain_path\.unlink'
require_pattern "${backup_pvc_restic}" "restic repos initialized on backup target" 'restic init'
require_pattern "${backup_pvc_restic}" "restic repos written via restic backup" 'restic backup --one-file-system'

require_pattern "${backup_readme}" "README hostile NFS contract" 'treat the backup target as hostile'
require_pattern "${backup_readme}" "README S3 payload stays off NFS in prod" '`mode=s3-replication` keeps S3 backup payload out of the NFS target'
require_pattern "${backup_readme}" "README restic repos documented as encrypted" 'restic repositories under `/backup/<deploymentId>/pvc-restic/` are encrypted at rest by restic'
require_pattern "${backup_readme}" "README recovery bundles documented as age-encrypted" 'Recovery bundles are encrypted-at-rest on the backup target using `age`'

require_pattern "${backup_guide}" "guide hostile NFS contract" 'DeployKube treats the backup target as hostile'
require_pattern "${backup_guide}" "guide marker-only S3 path" 'Marker \(still on NFS\)'
require_pattern "${backup_guide}" "guide restic repos documented as encrypted" 'Restic repositories under `/volume1/deploykube/backups/<deploymentId>/pvc-restic/` are encrypted at rest by restic'
require_pattern "${backup_guide}" "guide recovery bundles documented as age-encrypted" 'Recovery bundles use the same Age recipient model'

require_pattern "${synology_guide}" "synology guide states NAS encryption is defense-in-depth" 'defense-in-depth only'

if [[ "${failures}" -ne 0 ]]; then
  echo "" >&2
  echo "backup target confidentiality contract FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "backup target confidentiality contract PASSED"
