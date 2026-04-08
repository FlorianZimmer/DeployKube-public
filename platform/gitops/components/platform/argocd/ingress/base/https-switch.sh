#!/bin/sh
set -euo pipefail

SCRIPT_NAME="argocd-https-switch"
NAMESPACE="${NAMESPACE:-argocd}"
CONFIGMAP="argocd-cm"
PARAMS_CM="argocd-cmd-params-cm"
DEPLOYMENT="${DEPLOYMENT:-argo-cd-argocd-server}"
HTTPROUTE="${HTTPROUTE:-argocd}"
STATE_CONFIGMAP="${SWITCH_STATE_CONFIGMAP:-argocd-https-switch-state}"
IDEMPOTENCE_VERSION="${IDEMPOTENCE_VERSION:-2026-03-02-v1}"

DEPLOYMENT_CONFIG_FILE="${DEPLOYMENT_CONFIG_FILE:-/etc/deploykube/deployment-config/deployment-config.yaml}"

derive_hosts_from_deployment_config() {
  if [ -n "${ARGOCD_HOST:-}" ]; then
    return
  fi
  if [ ! -f "${DEPLOYMENT_CONFIG_FILE}" ]; then
    log "ARGOCD_HOST not set and deployment config missing at ${DEPLOYMENT_CONFIG_FILE}"
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    log "missing dependency: yq (needed to parse ${DEPLOYMENT_CONFIG_FILE})"
    exit 1
  fi
  ARGOCD_HOST="$(yq -r '.spec.dns.hostnames.argocd // ""' "${DEPLOYMENT_CONFIG_FILE}" 2>/dev/null || true)"
  if [ -z "${ARGOCD_HOST}" ]; then
    log "unable to derive ARGOCD_HOST from ${DEPLOYMENT_CONFIG_FILE}"
    exit 1
  fi
}

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  log "missing dependency: sha256sum or shasum"
  exit 1
}

wait_for_route() {
  log "waiting for HTTPRoute ${HTTPROUTE} to be Accepted"
  attempts=0
  while [ "${attempts}" -lt 60 ]; do
    status=$(kubectl -n "${NAMESPACE}" get httproute "${HTTPROUTE}" -o jsonpath='{range .status.parents[*]}{.conditions[?(@.type=="Accepted")].status}{" "}{end}' 2>/dev/null || true)
    if printf '%s' "${status}" | grep -q "True"; then
      return
    fi
    attempts=$((attempts + 1))
    sleep 5
  done
  log "HTTPRoute never reached Accepted state"
  exit 1
}

wait_for_rollout() {
  log "waiting for deployment/${DEPLOYMENT} rollout"
  attempts=0
  while [ "${attempts}" -lt 60 ]; do
    status_json="$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o json 2>/dev/null || true)"
    if [ -n "${status_json}" ]; then
      generation="$(printf '%s' "${status_json}" | jq -r '.metadata.generation // 0')"
      observed="$(printf '%s' "${status_json}" | jq -r '.status.observedGeneration // 0')"
      replicas="$(printf '%s' "${status_json}" | jq -r '.spec.replicas // 1')"
      updated="$(printf '%s' "${status_json}" | jq -r '.status.updatedReplicas // 0')"
      available="$(printf '%s' "${status_json}" | jq -r '.status.availableReplicas // 0')"
      unavailable="$(printf '%s' "${status_json}" | jq -r '.status.unavailableReplicas // 0')"
      if [ "${observed}" -ge "${generation}" ] && [ "${updated}" -ge "${replicas}" ] && [ "${available}" -ge "${replicas}" ] && [ "${unavailable}" -eq 0 ]; then
        return
      fi
    fi
    attempts=$((attempts + 1))
    sleep 5
  done
  log "deployment rollout timed out"
  exit 1
}

record_idempotence_marker() {
  existing_sha="$(kubectl -n "${NAMESPACE}" get configmap "${STATE_CONFIGMAP}" -o jsonpath='{.data.configSha256}' 2>/dev/null || true)"
  existing_version="$(kubectl -n "${NAMESPACE}" get configmap "${STATE_CONFIGMAP}" -o jsonpath='{.data.configVersion}' 2>/dev/null || true)"
  desired_sha="$(
    printf '%s' "${ARGOCD_HOST}|server.insecure=false|server.repo.server.strict.tls=true|${DEPLOYMENT}|${HTTPROUTE}" \
      | sha256_text
  )"
  if [ "${existing_sha}" = "${desired_sha}" ] && [ "${existing_version}" = "${IDEMPOTENCE_VERSION}" ]; then
    log "idempotence marker already current (${STATE_CONFIGMAP} sha=${desired_sha})"
    return
  fi

  now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kubectl -n "${NAMESPACE}" patch configmap "${STATE_CONFIGMAP}" --type merge -p "$(
    jq -n \
      --arg version "${IDEMPOTENCE_VERSION}" \
      --arg sha "${desired_sha}" \
      --arg ts "${now_utc}" \
      '{data:{"configVersion":$version,"configSha256":$sha,"lastAppliedAt":$ts}}'
  )"
  log "updated idempotence marker ${STATE_CONFIGMAP} (${IDEMPOTENCE_VERSION})"
}

derive_hosts_from_deployment_config

log "patching HTTPRoute/${HTTPROUTE} hostnames -> ${ARGOCD_HOST}"
kubectl -n "${NAMESPACE}" patch httproute "${HTTPROUTE}" --type merge \
  -p "{\"spec\":{\"hostnames\":[\"${ARGOCD_HOST}\"]}}" >/dev/null

wait_for_route

current_url=$(kubectl -n "${NAMESPACE}" get configmap "${CONFIGMAP}" -o jsonpath='{.data.url}')
if [ "${current_url}" = "https://${ARGOCD_HOST}" ]; then
  log "argocd-cm already points at https"
else
  log "patching ${CONFIGMAP} url"
  kubectl -n "${NAMESPACE}" patch configmap "${CONFIGMAP}" --type merge \
    -p "{\"data\":{\"url\":\"https://${ARGOCD_HOST}\"}}"
fi

log "patching ${PARAMS_CM}"
kubectl -n "${NAMESPACE}" patch configmap "${PARAMS_CM}" --type merge \
  -p '{"data":{"server.insecure":"false","server.repo.server.strict.tls":"true"}}'

args=$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)
if printf '%s' "${args}" | grep -q -- "--insecure"; then
  log "removing --insecure flag from deployment/${DEPLOYMENT}"
  idx="$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o json | jq -r '.spec.template.spec.containers[0].args | to_entries[] | select(.value==\"--insecure\") | .key' | head -n1)"
  if [ -n "${idx}" ]; then
    kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/${idx}\"}]"
  fi
else
  log "deployment/${DEPLOYMENT} already runs without --insecure"
fi

wait_for_rollout
record_idempotence_marker
