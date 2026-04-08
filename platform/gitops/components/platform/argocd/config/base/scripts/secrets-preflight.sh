#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="argocd-secrets-preflight"
NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-24}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

wait_for_secret_key() {
  local secret="$1" key="$2" attempt=0 value=""
  local jsonpath_key
  jsonpath_key=${key//./\\.}
  while (( attempt < WAIT_ATTEMPTS )); do
    value="$(kubectl -n "${NAMESPACE}" get secret "${secret}" -o jsonpath="{.data.${jsonpath_key}}" 2>/dev/null || true)"
    if [[ -n "${value}" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for secret ${secret} key ${key} (${attempt}/${WAIT_ATTEMPTS})"
    sleep "${WAIT_INTERVAL}"
  done
  log "required secret key missing: ${secret}.${key}"
  return 1
}

main() {
  wait_for_secret_key "repo-forgejo-platform" "username"
  wait_for_secret_key "repo-forgejo-platform" "password"
  wait_for_secret_key "argocd-secret" "oidc.clientSecret"
  wait_for_secret_key "argocd-oidc-ca" "ca.crt"
  log "all required secrets are present"
}

main "$@"
