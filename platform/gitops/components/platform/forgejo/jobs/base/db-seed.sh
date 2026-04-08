#!/bin/sh
set -euo pipefail

ISTIO_HELPER="/helpers/istio-native-exit.sh"
if [ ! -f "$ISTIO_HELPER" ]; then
  echo "missing istio-native-exit helper" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$ISTIO_HELPER"

SCRIPT_NAME="forgejo-db-seed"
NAMESPACE="${NAMESPACE:-forgejo}"
SENTINEL_CM="${SCRIPT_NAME}-complete"
CLUSTER_NAME="${POSTGRES_CLUSTER_NAME:-postgres}"
DEPLOYMENT_NAME="${FORGEJO_DEPLOYMENT:-forgejo}"
LABEL_SELECTOR="${FORGEJO_LABEL_SELECTOR:-app.kubernetes.io/name=forgejo}"
DATA_DIR="${DATA_DIR:-/forgejo-data}"
SQL_ZIP="${DATA_DIR}/tmp/forgejo-db-dump.zip"
SQL_TMP_DIR="$(mktemp -d)"
POSTGRES_HOST="${POSTGRES_HOST:-postgres-rw}"
POSTGRES_DB="${POSTGRES_DB:-forgejo}"
POSTGRES_SUPERUSER_USER="${POSTGRES_SUPERUSER_USER:-postgres}"
POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}"
POSTGRES_APP_USER="${POSTGRES_APP_USER:-forgejo}"
POSTGRES_APP_PASSWORD="${POSTGRES_APP_PASSWORD:-}"
PGSSLMODE="${PGSSLMODE:-require}"
current_replicas="0"
scaled_down=false

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$1"
}

cleanup() {
  if [ "${scaled_down}" = true ] && [ "${current_replicas}" -gt 0 ]; then
    log "restoring Forgejo deployment to ${current_replicas} replicas"
    kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge -p "{\"spec\":{\"replicas\":${current_replicas}}}"
    kubectl -n "${NAMESPACE}" rollout status deployment "${DEPLOYMENT_NAME}" --timeout=600s >/dev/null 2>&1 || true
  fi
  rm -rf "${SQL_TMP_DIR}"
  deploykube_istio_quit_sidecar
}

trap cleanup EXIT INT TERM

if kubectl -n "${NAMESPACE}" get configmap "${SENTINEL_CM}" >/dev/null 2>&1; then
  log "sentinel ${SENTINEL_CM} found; skipping"
  exit 0
fi

require_var() {
  if [ -z "$2" ]; then
    log "missing required variable $1"
    exit 1
  fi
}

require_var POSTGRES_SUPERUSER_PASSWORD "${POSTGRES_SUPERUSER_PASSWORD:-}"
require_var POSTGRES_APP_PASSWORD "${POSTGRES_APP_PASSWORD:-}"

log "bootstrap tools image already provides PostgreSQL, sqlite, and unzip"

export PGSSLMODE

log "waiting for CloudNativePG cluster ${CLUSTER_NAME}"
if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready --timeout=600s cluster.postgresql.cnpg.io/"${CLUSTER_NAME}"; then
  log "CloudNativePG cluster ${CLUSTER_NAME} not ready; aborting"
  exit 1
fi

forgejo_pod="$(kubectl -n "${NAMESPACE}" get pods -l "${LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${forgejo_pod}" ]; then
  log "creating forgejo dump via pod ${forgejo_pod}"
  kubectl -n "${NAMESPACE}" exec "${forgejo_pod}" -- sh -c 'cd /data/tmp && rm -f forgejo-db-dump.zip && forgejo dump --database postgres --skip-repository --skip-log --skip-custom-dir --skip-lfs-data --skip-attachment-data --skip-package-data --skip-index --file forgejo-db-dump.zip'
else
  log "no running Forgejo pod detected; assuming dump already present"
fi

if [ ! -s "${SQL_ZIP}" ]; then
  log "expected dump ${SQL_ZIP} missing"
  exit 1
fi

current_replicas="$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT_NAME}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"

if [ "${current_replicas}" -gt 0 ]; then
  log "scaling Forgejo deployment ${DEPLOYMENT_NAME} to 0 replicas"
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge -p '{"spec":{"replicas":0}}'
  for _ in $(seq 1 60); do
    pod_count="$(kubectl -n "${NAMESPACE}" get pods -l "${LABEL_SELECTOR}" --no-headers 2>/dev/null | grep -c '^' || true)"
    if [ "${pod_count}" = "0" ]; then
      break
    fi
    sleep 5
  done
  if [ "${pod_count}" != "0" ]; then
    log "timed out waiting for Forgejo pods to terminate"
    exit 1
  fi
  scaled_down=true
fi

SQL_FILE="${SQL_TMP_DIR}/forgejo-db.sql"
log "extracting SQL payload"
unzip -p "${SQL_ZIP}" forgejo-db.sql > "${SQL_FILE}"

export PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}"
log "resetting Postgres schema"
psql -h "${POSTGRES_HOST}" -U "${POSTGRES_SUPERUSER_USER}" -d "${POSTGRES_DB}" <<SQL
SET client_min_messages TO WARNING;
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public AUTHORIZATION "${POSTGRES_APP_USER}";
GRANT ALL ON SCHEMA public TO "${POSTGRES_APP_USER}";
GRANT ALL ON SCHEMA public TO public;
SQL

export PGPASSWORD="${POSTGRES_APP_PASSWORD}"
log "importing Forgejo data into Postgres"
psql -h "${POSTGRES_HOST}" -U "${POSTGRES_APP_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -f "${SQL_FILE}"

rm -f "${SQL_ZIP}"

if [ "${current_replicas}" -gt 0 ]; then
  log "scaling Forgejo deployment back to ${current_replicas} replicas"
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT_NAME}" --type merge -p "{\"spec\":{\"replicas\":${current_replicas}}}"
  kubectl -n "${NAMESPACE}" rollout status deployment "${DEPLOYMENT_NAME}" --timeout=600s
  scaled_down=false
fi

kubectl -n "${NAMESPACE}" create configmap "${SENTINEL_CM}" --from-literal=cluster="${CLUSTER_NAME}" --from-literal=completedAt="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log "seed sentinel created"
