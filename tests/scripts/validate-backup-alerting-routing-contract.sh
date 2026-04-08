#!/usr/bin/env bash
# validate-backup-alerting-routing-contract.sh
# Enforce Queue #12 backup alert routing/ownership contract in repo manifests.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

require_pattern() {
  local file="$1"
  local label="$2"
  local pattern="$3"
  if ! rg -n -q --regexp "${pattern}" "${file}"; then
    echo "missing: ${label} (${file})" >&2
    failures=$((failures + 1))
  fi
}

echo "==> Validating backup alert routing contract"

secret_kustomization="platform/gitops/components/platform/observability/secrets/kustomization.yaml"
secret_manifest="platform/gitops/components/platform/observability/secrets/externalsecret-mimir-alertmanager-notifications.yaml"
mimir_values="platform/gitops/components/platform/observability/mimir/overlays/proxmox-talos/values.yaml"

require_pattern "${secret_kustomization}" "mimir alertmanager notification ExternalSecret included" "externalsecret-mimir-alertmanager-notifications\\.yaml"
require_pattern "${secret_manifest}" "ExternalSecret name" "^\\s*name:\\s*mimir-alertmanager-notifications\\s*$"
require_pattern "${secret_manifest}" "Vault key path" "^\\s*key:\\s*observability/alertmanager\\s*$"
require_pattern "${secret_manifest}" "platform webhook property" "^\\s*property:\\s*platformWebhookUrl\\s*$"
require_pattern "${secret_manifest}" "backup webhook property" "^\\s*property:\\s*backupWebhookUrl\\s*$"

require_pattern "${mimir_values}" "mimir alertmanager notification secret envFrom" "name:\\s*mimir-alertmanager-notifications"
require_pattern "${mimir_values}" "platform receiver" "name:\\s*platform-ops"
require_pattern "${mimir_values}" "platform receiver webhook env" "url:\\s*\\$\\{ALERTMANAGER_PLATFORM_WEBHOOK_URL\\}"
require_pattern "${mimir_values}" "backup receiver" "name:\\s*backup-system-platform-ops"
require_pattern "${mimir_values}" "backup receiver webhook env" "url:\\s*\\$\\{ALERTMANAGER_BACKUP_WEBHOOK_URL\\}"
require_pattern "${mimir_values}" "backup service route matcher" "service:\\s*backup-system"
require_pattern "${mimir_values}" "backup route repeat interval contract" "repeat_interval:\\s*15m"

if [[ "${failures}" -ne 0 ]]; then
  echo "" >&2
  echo "backup alert routing contract FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "backup alert routing contract PASSED"
