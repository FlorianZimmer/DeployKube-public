#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

NAMESPACE="${POD_NAMESPACE:-keycloak-upstream-sim}"
UPSTREAM_KEYCLOAK_URL="${UPSTREAM_KEYCLOAK_URL:-http://keycloak-upstream-sim.keycloak-upstream-sim.svc.cluster.local:8080}"
UPSTREAM_REALM="${UPSTREAM_REALM:-upstream-sim}"
DOWNSTREAM_REALM="${DOWNSTREAM_REALM:-deploykube-admin}"
DEPLOYMENT_CONFIG_NAMESPACE="${DEPLOYMENT_CONFIG_NAMESPACE:-argocd}"
DEPLOYMENT_CONFIG_NAME="${DEPLOYMENT_CONFIG_NAME:-}"
STATUS_CONFIGMAP="${STATUS_CONFIGMAP:-keycloak-upstream-sim-smoke-status}"
UPSTREAM_SIM_ISSUER_HOST="${UPSTREAM_SIM_ISSUER_HOST:-keycloak-upstream-sim.keycloak-upstream-sim.svc.cluster.local}"
REQUIRE_DEPLOYMENTCONFIG_MATCH="${REQUIRE_DEPLOYMENTCONFIG_MATCH:-false}"
UPSTREAM_DEPLOYMENT_NAME="${UPSTREAM_DEPLOYMENT_NAME:-keycloak-upstream-sim}"
UPSTREAM_STARTUP_TIMEOUT_SECONDS="${UPSTREAM_STARTUP_TIMEOUT_SECONDS:-300}"
AUTO_SCALE_UPSTREAM_SIM="${AUTO_SCALE_UPSTREAM_SIM:-true}"
SCALE_DOWN_AFTER_TEST="${SCALE_DOWN_AFTER_TEST:-true}"
BOOTSTRAP_BEFORE_TEST="${BOOTSTRAP_BEFORE_TEST:-true}"
BOOTSTRAP_STATUS_CONFIGMAP="${BOOTSTRAP_STATUS_CONFIGMAP:-keycloak-upstream-sim-status}"

ORIGINAL_REPLICAS=""
SCALED_FOR_TEST="false"

status_set() {
  local key="$1"
  local value="$2"
  local patch

  patch="$(jq -n --arg k "$key" --arg v "$value" '{data:{($k):$v}}')"
  kubectl -n "$NAMESPACE" patch configmap "$STATUS_CONFIGMAP" --type merge -p "$patch" >/dev/null 2>&1 || \
    kubectl -n "$NAMESPACE" create configmap "$STATUS_CONFIGMAP" --from-literal "$key=$value" >/dev/null
}

resolve_deployment_config_name() {
  if [[ -n "$DEPLOYMENT_CONFIG_NAME" ]]; then
    return 0
  fi

  DEPLOYMENT_CONFIG_NAME="$(kubectl -n "$DEPLOYMENT_CONFIG_NAMESPACE" get deploymentconfigs.platform.darksite.cloud -o json | jq -r '.items[0].metadata.name // empty')"
  [[ -n "$DEPLOYMENT_CONFIG_NAME" ]] || {
    echo "no DeploymentConfig found in namespace $DEPLOYMENT_CONFIG_NAMESPACE" >&2
    exit 1
  }
}

deployment_cfg() {
  local expr="$1"
  kubectl -n "$DEPLOYMENT_CONFIG_NAMESPACE" get deploymentconfigs.platform.darksite.cloud "$DEPLOYMENT_CONFIG_NAME" -o json | jq -r "$expr // \"\""
}

sim_secret_field() {
  local key="$1"
  kubectl -n "$NAMESPACE" get secret keycloak-upstream-sim-values -o json | jq -r --arg key "$key" '.data[$key] // empty' | base64 -d
}

scale_upstream_for_test() {
  local replicas timeout

  if [[ "$AUTO_SCALE_UPSTREAM_SIM" != "true" ]]; then
    return 0
  fi

  replicas="$(kubectl -n "$NAMESPACE" get deployment "$UPSTREAM_DEPLOYMENT_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ORIGINAL_REPLICAS="${replicas:-0}"
  status_set "upstream.originalReplicas" "$ORIGINAL_REPLICAS"

  if [[ "$ORIGINAL_REPLICAS" != "0" ]]; then
    return 0
  fi

  log "scaling upstream simulator deployment to 1 replica for smoke run"
  kubectl -n "$NAMESPACE" scale deployment "$UPSTREAM_DEPLOYMENT_NAME" --replicas=1 >/dev/null
  timeout="${UPSTREAM_STARTUP_TIMEOUT_SECONDS}s"
  kubectl -n "$NAMESPACE" rollout status deployment "$UPSTREAM_DEPLOYMENT_NAME" --timeout="$timeout" >/dev/null
  SCALED_FOR_TEST="true"
  status_set "upstream.scaledForTest" "true"
}

scale_down_upstream_after_test() {
  if [[ "$AUTO_SCALE_UPSTREAM_SIM" != "true" || "$SCALE_DOWN_AFTER_TEST" != "true" ]]; then
    return 0
  fi

  if [[ "$SCALED_FOR_TEST" != "true" ]]; then
    return 0
  fi

  log "scaling upstream simulator deployment back to ${ORIGINAL_REPLICAS:-0} replicas"
  kubectl -n "$NAMESPACE" scale deployment "$UPSTREAM_DEPLOYMENT_NAME" --replicas="${ORIGINAL_REPLICAS:-0}" >/dev/null 2>&1 || true
  status_set "upstream.replicasAfterSmoke" "${ORIGINAL_REPLICAS:-0}"
}

run_bootstrap_if_enabled() {
  if [[ "$BOOTSTRAP_BEFORE_TEST" != "true" ]]; then
    return 0
  fi

  log "running upstream bootstrap reconciliation before smoke checks"
  STATUS_CONFIGMAP="$BOOTSTRAP_STATUS_CONFIGMAP" /scripts/bootstrap.sh
}

wait_for_upstream() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS "${UPSTREAM_KEYCLOAK_URL%/}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "upstream keycloak not ready: $UPSTREAM_KEYCLOAK_URL" >&2
  exit 1
}

check_discovery() {
  local issuer
  issuer="$(curl -fsS "${UPSTREAM_KEYCLOAK_URL%/}/realms/${UPSTREAM_REALM}/.well-known/openid-configuration" | jq -r '.issuer // empty')"
  [[ -n "$issuer" ]] || {
    echo "missing issuer in upstream discovery" >&2
    exit 1
  }
  status_set "upstream.discoveryIssuer" "$issuer"

  if [[ "$issuer" != *"${UPSTREAM_SIM_ISSUER_HOST}"* ]]; then
    echo "issuer host mismatch (wanted host fragment ${UPSTREAM_SIM_ISSUER_HOST}, got ${issuer})" >&2
    exit 1
  fi
}

check_token_grant() {
  local username password token

  username="$(sim_secret_field simUserUsername)"
  password="$(sim_secret_field simUserPassword)"
  [[ -n "$username" && -n "$password" ]] || {
    echo "simulation credentials missing in keycloak-upstream-sim-values" >&2
    exit 1
  }

  token="$(curl -fsS -X POST "${UPSTREAM_KEYCLOAK_URL%/}/realms/${UPSTREAM_REALM}/protocol/openid-connect/token" \
    -d grant_type=password \
    -d client_id=admin-cli \
    -d username="$username" \
    -d password="$password" | jq -r '.access_token // empty')"

  [[ -n "$token" ]] || {
    echo "failed to obtain upstream token for simulation user" >&2
    exit 1
  }
}

check_deployment_config_binding() {
  local mode upstream_type issuer_url

  resolve_deployment_config_name
  mode="$(deployment_cfg '.spec.iam.mode')"
  upstream_type="$(deployment_cfg '.spec.iam.upstream.type')"
  issuer_url="$(deployment_cfg '.spec.iam.upstream.oidc.issuerUrl')"

  status_set "deploymentConfig.name" "$DEPLOYMENT_CONFIG_NAME"
  status_set "deploymentConfig.iam.mode" "$mode"
  status_set "deploymentConfig.iam.upstream.type" "$upstream_type"
  status_set "deploymentConfig.iam.upstream.oidc.issuerUrl" "$issuer_url"

  if [[ "$REQUIRE_DEPLOYMENTCONFIG_MATCH" != "true" ]]; then
    return 0
  fi

  if [[ "$mode" != "hybrid" && "$mode" != "downstream" ]]; then
    echo "REQUIRE_DEPLOYMENTCONFIG_MATCH=true but mode is $mode" >&2
    exit 1
  fi

  if [[ "$upstream_type" != "oidc" ]]; then
    echo "REQUIRE_DEPLOYMENTCONFIG_MATCH=true but upstream type is $upstream_type" >&2
    exit 1
  fi

  if [[ "$issuer_url" != "${UPSTREAM_KEYCLOAK_URL%/}/realms/${UPSTREAM_REALM}" ]]; then
    echo "deployment config issuer mismatch: $issuer_url" >&2
    exit 1
  fi
}

cleanup() {
  scale_down_upstream_after_test
}

main() {
  trap cleanup EXIT

  status_set "status" "running"
  status_set "lastStartTime" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  scale_upstream_for_test
  run_bootstrap_if_enabled
  wait_for_upstream
  check_discovery
  check_token_grant
  check_deployment_config_binding

  status_set "status" "ready"
  status_set "lastSuccessTime" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  log "upstream simulation smoke check completed"
}

main "$@"
