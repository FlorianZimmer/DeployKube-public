#!/bin/sh
set -eu

if ! kubectl -n vault-system get secret vault-init >/dev/null 2>&1; then
  echo "[vault-init] secret vault-system/vault-init missing; populate secrets/bootstrap/vault-init.secret.sops.yaml before syncing" >&2
  exit 1
fi

decode_field() {
  kubectl -n vault-system get secret vault-init -o jsonpath="{.data.$1}" | base64 -d 2>/dev/null || true
}

validate_field() {
  value="$1"
  field="$2"
  if [ -z "$value" ]; then
    echo "[vault-init] ${field} is empty in vault-init secret" >&2
    exit 1
  fi
  case "$value" in
    REPLACE_*|PLACEHOLDER*|CHANGEME*|changeme*|__*)
      echo "[vault-init] ${field} still contains placeholder (${value}); update the SOPS secret" >&2
      exit 1
      ;;
  esac
}

root_token=$(decode_field root-token)
recovery_key=$(decode_field recovery-key)
validate_field "$root_token" "root-token"
validate_field "$recovery_key" "recovery-key"

echo "[vault-init] vault-init secret already managed via GitOps; nothing to do"
