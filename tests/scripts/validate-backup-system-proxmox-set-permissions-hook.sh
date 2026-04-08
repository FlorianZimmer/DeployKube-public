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

overlay_dir="platform/gitops/components/storage/backup-system/overlays/proxmox-talos"
rendered="$(kubectl kustomize "${overlay_dir}" 2>&1)" || {
  echo "${rendered}" >&2
  echo "FAIL: kustomize render failed for ${overlay_dir}" >&2
  exit 1
}

tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT
printf '%s\n' "${rendered}" > "${tmpfile}"

require_render_pattern() {
  local pattern="$1"
  local description="$2"
  if ! rg -F -q -- "${pattern}" "${tmpfile}"; then
    echo "FAIL: ${overlay_dir} missing ${description}" >&2
    exit 1
  fi
}

require_render_pattern 'name: backup-set-permissions-repair' "backup-set-permissions-repair job"
require_render_pattern 'argocd.argoproj.io/hook: Sync' "Sync hook annotation"
require_render_pattern 'claimName: backup-target' "backup-target PVC mount"
require_render_pattern 'runAsUser: 0' "root repair security context"
require_render_pattern 'sets_root="/backup/${deployment_id}/sets"' "sets root repair path"
require_render_pattern 'find "${path}" -type d -exec chmod 2775 {} +' "recursive set directory mode repair"

base_manifest="platform/gitops/components/storage/backup-system/base/cronjob-backup-set-assemble.yaml"
if ! rg -F -q 'runAsUser: 65532' "${base_manifest}"; then
  echo "FAIL: ${base_manifest} missing non-root runAsUser 65532" >&2
  exit 1
fi
if ! rg -F -q 'fsGroup: 65532' "${base_manifest}"; then
  echo "FAIL: ${base_manifest} missing fsGroup 65532" >&2
  exit 1
fi
if ! rg -F -q 'readOnlyRootFilesystem: true' "${base_manifest}"; then
  echo "FAIL: ${base_manifest} missing readOnlyRootFilesystem hardening" >&2
  exit 1
fi

echo "backup-system proxmox set permissions hook validation PASSED"
