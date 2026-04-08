#!/usr/bin/env bash
# DeployKube Proxmox Talos Bootstrap
# Wrapper script that delegates to the orchestrator in shared/scripts/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${REPO_ROOT}/shared/scripts/bootstrap-proxmox-talos-orchestrator.sh" "$@"
