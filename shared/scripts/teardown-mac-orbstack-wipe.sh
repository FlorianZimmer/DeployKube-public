#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIPE_NFS_DATA=1 "${SCRIPT_DIR}/teardown-mac-orbstack.sh" "$@"
