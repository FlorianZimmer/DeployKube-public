#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KIND_CONFIG="${KIND_CONFIG:-${REPO_ROOT}/bootstrap/mac-orbstack/cluster/kind-config-single-worker.yaml}" \
CILIUM_VALUES="${CILIUM_VALUES:-${REPO_ROOT}/bootstrap/mac-orbstack/cilium/values-single.yaml}" \
ARGO_APP_PATH="${ARGO_APP_PATH:-apps/environments/mac-orbstack-single}" \
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-mac-orbstack-single}" \
DEPLOYKUBE_STORAGE_PROFILE="${DEPLOYKUBE_STORAGE_PROFILE:-local-path}" \
ENABLE_NFS_HOST="${ENABLE_NFS_HOST:-0}" \
LOCAL_REGISTRY_WARM_IMAGES="${LOCAL_REGISTRY_WARM_IMAGES:-0}" \
BOOTSTRAP_SKIP_VAULT_INIT=true \
BOOTSTRAP_WIPE_VAULT_DATA=false \
BOOTSTRAP_REINIT_VAULT=false \
BOOTSTRAP_FORCE_VAULT=false \
  "${SCRIPT_DIR}/bootstrap-mac-orbstack-orchestrator.sh" "$@"
