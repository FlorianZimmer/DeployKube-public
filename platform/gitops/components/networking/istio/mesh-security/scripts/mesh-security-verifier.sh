#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[mesh-security] jq is required" >&2
  exit 1
fi

NAMESPACES=${MESH_NAMESPACES:-"forgejo keycloak vault-system dns-system cert-manager step-system cnpg-system external-secrets"}
REPORT_PATH=${MESH_REPORT_PATH:-/tmp/mesh-security/report.json}
TIMEOUT_SECONDS=${MESH_WAIT_TIMEOUT:-180}

mkdir -p "$(dirname "${REPORT_PATH}")"

declare -a entries=()
errors=0

escape_json() {
  if command -v jq >/dev/null 2>&1; then
    # jq -Rs . wraps the string in quotes, so strip the first/last char
    jq -Rs . <<<"$1" | sed 's/^"//; s/"$//'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"$1"
  else
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
}

log() {
  printf '[mesh-security] %s\n' "$1"
}

for ns in ${NAMESPACES}; do
  status="ready"
  message="namespace ready for STRICT"
  has_injection=false
  sidecars_present=false
  pods_ready=false

  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    status="error"
    message="namespace missing"
    errors=1
  else
    label_value=$(kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)
    if [[ "${label_value}" == "enabled" ]] || [[ -n "${label_value}" && "${label_value}" != "disabled" ]]; then
      has_injection=true
    else
      status="error"
      message="istio-injection label missing or disabled"
      errors=1
    fi
    pod_json=$(kubectl get pods -n "${ns}" --field-selector=status.phase!=Succeeded -o json 2>/dev/null || printf '')
    eligible_pod_names=$(printf '%s' "${pod_json}" | jq -r '
      .items[]
      | select(((.metadata.ownerReferences // []) | map(.kind) | index("Job")) | not)
      | select((.metadata.annotations["sidecar.istio.io/inject"] // "") != "false")
      | .metadata.name
    ' 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
    eligible_count=$(printf '%s\n' "${eligible_pod_names}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ ${eligible_count} -gt 0 ]]; then
      if kubectl wait --for=condition=Ready pod -n "${ns}" --timeout="${TIMEOUT_SECONDS}s" ${eligible_pod_names} >/dev/null 2>&1; then
        pods_ready=true
      else
        status="error"
        message="pods failed readiness wait"
        errors=1
      fi
      missing_sidecars=$(printf '%s' "${pod_json}" | jq -r '
        .items[]
        | select(((.metadata.ownerReferences // []) | map(.kind) | index("Job")) | not)
        | select((.metadata.annotations["sidecar.istio.io/inject"] // "") != "false")
        | select(.metadata.annotations["sidecar.istio.io/status"] == null)
        | .metadata.name
      ' 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
      if [[ -n "${missing_sidecars}" ]]; then
        status="error"
        message="mesh-eligible pods without sidecars: ${missing_sidecars}"
        errors=1
      else
        sidecars_present=true
      fi
    else
      # No mesh-eligible pods to check yet (e.g., only `inject=false` workloads like DBs, or namespace has no pods).
      status="warning"
      message="no mesh-eligible pods found; skip readiness check"
    fi
  fi

  escaped_message=$(escape_json "${message}")
  entry=$(printf '{"name":"%s","status":"%s","hasInjection":%s,"podsReady":%s,"sidecarsPresent":%s,"message":"%s"}' \
    "${ns}" "${status}" "${has_injection}" "${pods_ready}" "${sidecars_present}" "${escaped_message}")
  entries+=("${entry}")
  log "${ns}: ${message}"

done

(
  printf '{"namespaces":['
  if [[ ${#entries[@]} -gt 0 ]]; then
    ( IFS=,; printf '%s' "${entries[*]}" )
  fi
  printf ']}\n'
) > "${REPORT_PATH}"

log "report written to ${REPORT_PATH}"

exit ${errors}
