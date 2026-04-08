#!/usr/bin/env bash
set -euo pipefail

# kustomize (as used by Argo CD) probes the helm binary using:
#   helm version -c --short
# Helm v3+ does not support the legacy "-c/--client" flag, so we strip it.

if [[ "${1:-}" == "version" ]]; then
  shift
  args=()
  for arg in "$@"; do
    case "${arg}" in
      -c|--client)
        ;;
      *)
        args+=("${arg}")
        ;;
    esac
  done
  exec helm version "${args[@]}"
fi

exec helm "$@"

