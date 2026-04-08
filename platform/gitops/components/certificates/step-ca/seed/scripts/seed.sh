#!/bin/sh
set -euo pipefail

ISTIO_HELPER="/helpers/istio-native-exit.sh"
if [ ! -f "$ISTIO_HELPER" ]; then
  echo "missing istio-native-exit helper" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$ISTIO_HELPER"

TMP_DIR=""
cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  deploykube_istio_quit_sidecar
}

trap cleanup EXIT INT TERM

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing dependency: $1" >&2
    exit 1
  fi
}

require sops
require jq
require yq
require kubectl

SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-/var/run/sops/age.key}
STEP_CA_SEED_FILE=${STEP_CA_SEED_FILE:-/config/step-ca-vault-seed.secret.sops.yaml}
VAULT_ADDR=${VAULT_ADDR:-http://vault.vault-system.svc:8200}
VAULT_NAMESPACE=${VAULT_NAMESPACE:-vault-system}
VAULT_STATEFULSET=${VAULT_STATEFULSET:-vault}
VAULT_POD_SELECTOR=${VAULT_POD_SELECTOR:-app.kubernetes.io/name=vault}
VAULT_LOCAL_ADDR=${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}
VAULT_CONFIGURE_JOB=${VAULT_CONFIGURE_JOB:-vault-configure}
STATEFULSET_WAIT_ATTEMPTS=${STATEFULSET_WAIT_ATTEMPTS:-180}
JOB_WAIT_ATTEMPTS=${JOB_WAIT_ATTEMPTS:-180}
CONFIGURE_SENTINEL="${CONFIGURE_SENTINEL:-vault-configure-complete}"
VAULT_POD=""
ROOT_TOKEN=""

if [ ! -s "$SOPS_AGE_KEY_FILE" ]; then
  echo "SOPS_AGE_KEY_FILE must point to a readable Age key" >&2
  exit 1
fi

if [ ! -f "$STEP_CA_SEED_FILE" ]; then
  echo "seed file $STEP_CA_SEED_FILE missing" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)

SEED_YAML="$TMP_DIR/seed.yaml"
sops -d "$STEP_CA_SEED_FILE" >"$SEED_YAML"

# Placeholder guardrail (DSB contract): refuse to write placeholder seed material into Vault.
placeholder="$(yq -r '.["darksite.cloud/placeholder"] // ""' "$SEED_YAML" 2>/dev/null || true)"
if [ "$placeholder" = "true" ] || [ "$placeholder" = "\"true\"" ]; then
  echo "refusing to run with placeholder seed file (darksite.cloud/placeholder=true): $STEP_CA_SEED_FILE" >&2
  exit 1
fi

SEED_JSON="$TMP_DIR/seed.json"
yq -o=json '.' "$SEED_YAML" >"$SEED_JSON"

wait_for_vault_statefulset() {
  echo "waiting for Vault StatefulSet replicas"
  for attempt in $(seq 1 "$STATEFULSET_WAIT_ATTEMPTS"); do
    status_json=$(kubectl -n "$VAULT_NAMESPACE" get statefulset/"$VAULT_STATEFULSET" -o json 2>/dev/null || true)
    if [ -n "$status_json" ]; then
      ready=$(printf '%s' "$status_json" | jq -r '.status.readyReplicas // 0')
      replicas=$(printf '%s' "$status_json" | jq -r '.status.replicas // 0')
      if [ "$replicas" -gt 0 ] && [ "$ready" -eq "$replicas" ]; then
        echo "Vault StatefulSet Ready ($ready/$replicas)"
        return
      fi
    fi
    echo "Vault StatefulSet not ready (attempt $attempt)"
    sleep 5
  done
  echo "Vault StatefulSet did not report Ready replicas" >&2
  exit 1
}

wait_for_configmap() {
  namespace=$1
  name=$2
  echo "waiting for configmap ${name}.${namespace}"
  for attempt in $(seq 1 "$JOB_WAIT_ATTEMPTS"); do
    if kubectl -n "$namespace" get configmap "$name" >/dev/null 2>&1; then
      echo "configmap ${name}.${namespace} present"
      return
    fi
    echo "configmap ${name}.${namespace} not ready (attempt $attempt)"
    sleep 5
  done
  echo "configmap ${name}.${namespace} did not appear within timeout" >&2
  exit 1
}

resolve_vault_pod() {
  kubectl -n "$VAULT_NAMESPACE" get pods -l "$VAULT_POD_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1
}

vault_exec() {
  if [ -z "${VAULT_POD:-}" ]; then
    VAULT_POD="$(resolve_vault_pod)"
  fi
  if [ -z "${VAULT_POD:-}" ]; then
    return 1
  fi

  if [ -n "${ROOT_TOKEN:-}" ]; then
    kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- env \
      BAO_ADDR="$VAULT_LOCAL_ADDR" \
      VAULT_ADDR="$VAULT_LOCAL_ADDR" \
      BAO_TOKEN="$ROOT_TOKEN" \
      VAULT_TOKEN="$ROOT_TOKEN" \
      "$@"
    return
  fi

  kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- env \
    BAO_ADDR="$VAULT_LOCAL_ADDR" \
    VAULT_ADDR="$VAULT_LOCAL_ADDR" \
    "$@"
}

wait_for_vault() {
  wait_for_vault_statefulset
  echo "waiting for Vault API (via kubectl exec into Vault pod)"
  for attempt in $(seq 1 60); do
    VAULT_POD="$(resolve_vault_pod)"
    if [ -z "${VAULT_POD:-}" ]; then
      echo "Vault pod not found (attempt $attempt); retrying"
      sleep 5
      continue
    fi
    status=$(vault_exec vault status -format=json 2>/dev/null || true)
    if printf '%s' "$status" | jq -e '.initialized == true and .sealed == false' >/dev/null 2>&1; then
      return
    fi
    echo "Vault sealed/uninitialized (attempt $attempt); retrying"
    sleep 5
  done
  echo "Vault did not become ready in time" >&2
  exit 1
}

get_root_token() {
  kubectl -n "$VAULT_NAMESPACE" get secret vault-init -o jsonpath='{.data.root-token}' | base64 -d
}

write_secret() {
  local path="$1"
  local file="$2"
  local payload_b64
  echo "writing kv secret secret/${path}"
  payload_b64=$(base64 <"$file" | tr -d '\n')
  vault_exec env SECRET_PATH="$path" PAYLOAD_B64="$payload_b64" sh -c '
set -eu
tmp_dir="/home/vault/tmp"
tmp_payload="${tmp_dir}/step-ca-seed-payload.json"
mkdir -p "${tmp_dir}"
printf "%s" "${PAYLOAD_B64}" | base64 -d >"${tmp_payload}"
vault write "secret/data/${SECRET_PATH}" @"${tmp_payload}" >/dev/null
rm -f "${tmp_payload}" >/dev/null 2>&1 || true
'
}

build_payload() {
  local jq_expr="$1"
  local outfile="$2"
  jq -c "$jq_expr" "$SEED_JSON" >"$outfile"
}

wait_for_vault
wait_for_configmap "$VAULT_NAMESPACE" "$CONFIGURE_SENTINEL"
ROOT_TOKEN=$(get_root_token)

build_payload '{data: {ca_json: .ca_json, defaults_json: .defaults_json, x509_leaf_tpl: .x509_leaf_tpl}}' "$TMP_DIR/config.json"
build_payload '{data: {root_ca_crt: .root_ca_crt, intermediate_ca_crt: .intermediate_ca_crt}}' "$TMP_DIR/certs.json"
build_payload '{data: {root_ca_key: .root_ca_key, intermediate_ca_key: .intermediate_ca_key}}' "$TMP_DIR/keys.json"
build_payload '{data: {ca_password: .ca_password, provisioner_password: .provisioner_password}}' "$TMP_DIR/passwords.json"

write_secret step-ca/config "$TMP_DIR/config.json"
write_secret step-ca/certs "$TMP_DIR/certs.json"
write_secret step-ca/keys "$TMP_DIR/keys.json"
write_secret step-ca/passwords "$TMP_DIR/passwords.json"

echo "step-ca vault seed completed"
