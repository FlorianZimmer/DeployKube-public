#!/usr/bin/env bash
# validate-backup-system-deployment-config-snapshot.sh - Repo-only guardrail
#
# backup-system CronJobs mount ConfigMap/<ns>/deploykube-deployment-config.
# That snapshot must be controller-owned (from the DeploymentConfig CR), not a repo-copied YAML blob.
# This script also guards the controller-owned backup-system wiring cutover
# (Cron schedules + static PV NFS mount fields).
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

require rg

overlay_kustomization="platform/gitops/components/storage/backup-system/overlays/proxmox-talos/kustomization.yaml"
legacy_snapshot="platform/gitops/components/storage/backup-system/overlays/proxmox-talos/configmap-deploykube-deployment-config.yaml"
controller_deploy="platform/gitops/components/platform/deployment-config-controller/base/deployment.yaml"
controller_rbac="platform/gitops/components/platform/deployment-config-controller/base/rbac.yaml"
backup_system_app="platform/gitops/apps/environments/proxmox-talos/resources/storage-backup-system.yaml"
proxmox_config="platform/gitops/deployments/proxmox-talos/config.yaml"

if [[ ! -f "${overlay_kustomization}" ]]; then
  echo "error: missing ${overlay_kustomization}" >&2
  exit 1
fi
if [[ -f "${legacy_snapshot}" ]]; then
  echo "FAIL: legacy backup-system DeploymentConfig snapshot must not be repo-authored anymore:" >&2
  echo "  - file: ${legacy_snapshot}" >&2
  echo "Fix:" >&2
  echo "  - remove the snapshot ConfigMap file and rely on the deployment-config-controller to publish it" >&2
  exit 1
fi
if rg -n -q -F -- "configmap-deploykube-deployment-config.yaml" "${overlay_kustomization}"; then
  echo "FAIL: backup-system overlay must not reference a repo-authored deploykube-deployment-config snapshot ConfigMap" >&2
  echo "  - file: ${overlay_kustomization}" >&2
  exit 1
fi

if [[ ! -f "${controller_deploy}" ]]; then
  echo "FAIL: missing deployment-config-controller (required to publish deploykube-deployment-config for backup-system)" >&2
  echo "  - expected: ${controller_deploy}" >&2
  exit 1
fi

if ! rg -n -q -- '--snapshot-namespaces=.*backup-system' "${controller_deploy}"; then
  echo "FAIL: deployment-config-controller must publish snapshots into backup-system namespace" >&2
  echo "  - file: ${controller_deploy}" >&2
  echo "  - expected args to include: --snapshot-namespaces=...backup-system..." >&2
  exit 1
fi
if ! rg -n -q -F -- '--backup-system-wiring-observe-only=false' "${controller_deploy}"; then
  echo "FAIL: deployment-config-controller must run backup-system wiring in apply-mode" >&2
  echo "  - file: ${controller_deploy}" >&2
  echo "  - expected arg: --backup-system-wiring-observe-only=false" >&2
  exit 1
fi

if [[ ! -f "${controller_rbac}" ]]; then
  echo "FAIL: missing deployment-config-controller RBAC (required for backup-system wiring)" >&2
  echo "  - expected: ${controller_rbac}" >&2
  exit 1
fi
if ! rg -n -q 'resources:\s*\["cronjobs"\]' "${controller_rbac}"; then
  echo "FAIL: deployment-config-controller RBAC must include batch/cronjobs access" >&2
  echo "  - file: ${controller_rbac}" >&2
  exit 1
fi
if ! rg -n -q 'resources:\s*\["persistentvolumes"\]' "${controller_rbac}"; then
  echo "FAIL: deployment-config-controller RBAC must include core/persistentvolumes access" >&2
  echo "  - file: ${controller_rbac}" >&2
  exit 1
fi

if [[ ! -f "${backup_system_app}" ]]; then
  echo "FAIL: missing backup-system Argo application" >&2
  echo "  - expected: ${backup_system_app}" >&2
  exit 1
fi
if ! rg -n -q -F -- 'RespectIgnoreDifferences=true' "${backup_system_app}"; then
  echo "FAIL: backup-system Argo app must set RespectIgnoreDifferences=true for controller-owned fields" >&2
  echo "  - file: ${backup_system_app}" >&2
  exit 1
fi
if ! rg -n -q -F -- '/spec/schedule' "${backup_system_app}"; then
  echo "FAIL: backup-system Argo app must ignore controller-owned CronJob schedules" >&2
  echo "  - file: ${backup_system_app}" >&2
  exit 1
fi
if ! rg -n -q -F -- '/spec/nfs/server' "${backup_system_app}" || \
   ! rg -n -q -F -- '/spec/nfs/path' "${backup_system_app}" || \
   ! rg -n -q -F -- '/spec/mountOptions' "${backup_system_app}"; then
  echo "FAIL: backup-system Argo app must ignore controller-owned static PV NFS mount fields" >&2
  echo "  - file: ${backup_system_app}" >&2
  exit 1
fi

if [[ ! -f "${proxmox_config}" ]]; then
  echo "FAIL: missing proxmox deployment config (required for backup schedule contract)" >&2
  echo "  - expected: ${proxmox_config}" >&2
  exit 1
fi
for key in \
  s3Mirror \
  smokeBackupTargetWrite \
  smokeBackupsFreshness \
  backupSetAssemble \
  pvcResticBackup \
  smokePvcResticCredentials \
  pruneTier0 \
  smokeFullRestoreStaleness; do
  if ! rg -n -q -F -- "${key}:" "${proxmox_config}"; then
    echo "FAIL: proxmox DeploymentConfig is missing spec.backup.schedules.${key}" >&2
    echo "  - file: ${proxmox_config}" >&2
    exit 1
  fi
done

echo "backup-system DeploymentConfig snapshot/wiring validation PASSED (controller-owned)"
