#!/bin/sh
set -eu

CONFIGMAP_NAME="${CONFIGMAP_NAME:-vault-configure-complete}"
ROOT_TOKEN_RETRIES="${ROOT_TOKEN_RETRIES:-60}"
ROOT_TOKEN_BACKOFF="${ROOT_TOKEN_BACKOFF:-5}"

if ! command -v jq >/dev/null 2>&1; then
  HAS_JQ=0
else
  HAS_JQ=1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl missing from bootstrap tools image; add it to shared/images/bootstrap-tools/Dockerfile" >&2
  exit 1
fi

KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-platform-admin}"
KEYCLOAK_DEV_USERNAME="${KEYCLOAK_DEV_USERNAME:-keycloak-dev-user}"
KEYCLOAK_ARGO_AUTOMATION_USERNAME="${KEYCLOAK_ARGO_AUTOMATION_USERNAME:-argocd-automation}"
KEYCLOAK_VAULT_AUTOMATION_USERNAME="${KEYCLOAK_VAULT_AUTOMATION_USERNAME:-vault-automation}"
KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
KEYCLOAK_DB_USERNAME="${KEYCLOAK_DB_USERNAME:-keycloak}"
KEYCLOAK_ARGO_CLIENT_ID="${KEYCLOAK_ARGO_CLIENT_ID:-argocd}"
KEYCLOAK_FORGEJO_CLIENT_ID="${KEYCLOAK_FORGEJO_CLIENT_ID:-forgejo}"
KEYCLOAK_KIALI_CLIENT_ID="${KEYCLOAK_KIALI_CLIENT_ID:-kiali}"
KEYCLOAK_HARBOR_CLIENT_ID="${KEYCLOAK_HARBOR_CLIENT_ID:-harbor}"
KEYCLOAK_HUBBLE_CLIENT_ID="${KEYCLOAK_HUBBLE_CLIENT_ID:-hubble}"
KEYCLOAK_VAULT_CLIENT_ID="${KEYCLOAK_VAULT_CLIENT_ID:-vault-cli}"

KEYCLOAK_OIDC_REALM="${KEYCLOAK_OIDC_REALM:-deploykube-admin}"
KEYCLOAK_OIDC_HOST="${KEYCLOAK_OIDC_HOST:-__KEYCLOAK_OIDC_HOST__}"
KEYCLOAK_OIDC_SCHEME="${KEYCLOAK_OIDC_SCHEME:-https}"
KEYCLOAK_OIDC_DISCOVERY_URL="${KEYCLOAK_OIDC_DISCOVERY_URL:-${KEYCLOAK_OIDC_SCHEME}://${KEYCLOAK_OIDC_HOST}/realms/${KEYCLOAK_OIDC_REALM}}"
KEYCLOAK_OIDC_ISSUER="${KEYCLOAK_OIDC_ISSUER:-${KEYCLOAK_OIDC_SCHEME}://${KEYCLOAK_OIDC_HOST}/realms/${KEYCLOAK_OIDC_REALM}}"
KEYCLOAK_OIDC_DISCOVERY_URL_INTERNAL="${KEYCLOAK_OIDC_DISCOVERY_URL_INTERNAL:-http://keycloak.keycloak.svc:8080/realms/${KEYCLOAK_OIDC_REALM}}"
KEYCLOAK_OIDC_JWKS_URL_INTERNAL="${KEYCLOAK_OIDC_JWKS_URL_INTERNAL:-http://keycloak.keycloak.svc:8080/realms/${KEYCLOAK_OIDC_REALM}/protocol/openid-connect/certs}"
KEYCLOAK_TOKEN_URL_INTERNAL="${KEYCLOAK_TOKEN_URL_INTERNAL:-http://keycloak.keycloak.svc:8080/realms/${KEYCLOAK_OIDC_REALM}/protocol/openid-connect/token}"
KEYCLOAK_VAULT_AUTOMATION_PATH="${KEYCLOAK_VAULT_AUTOMATION_PATH:-secret/keycloak/vault-automation-user}"
KEYCLOAK_VAULT_CLIENT_PATH="${KEYCLOAK_VAULT_CLIENT_PATH:-secret/keycloak/vault-client}"
VAULT_JWT_MOUNT="${VAULT_JWT_MOUNT:-jwt}"
VAULT_AUTOMATION_ROLE="${VAULT_AUTOMATION_ROLE:-vault-automation}"
VAULT_AUTOMATION_AUDIENCE="${VAULT_AUTOMATION_AUDIENCE:-${KEYCLOAK_VAULT_CLIENT_ID}}"
VAULT_AUTOMATION_BOUND_AUDIENCE="${VAULT_AUTOMATION_BOUND_AUDIENCE:-${VAULT_AUTOMATION_AUDIENCE}}"
VAULT_AUTOMATION_GROUP="${VAULT_AUTOMATION_GROUP:-dk-bot-vault-writer}"
VAULT_AUTOMATION_SUBJECT="${VAULT_AUTOMATION_SUBJECT:-}"
KEYCLOAK_JWKS_WAIT_MODE="${KEYCLOAK_JWKS_WAIT_MODE:-auto}"

log() {
  printf '[vault-configure] %s\n' "$*"
}

# shellcheck disable=SC2034 # function historically retried; keep helper for future debug
wait_for_valid_root_token() {
  if kubectl -n vault-system get secret vault-init >/dev/null 2>&1; then
    kubectl -n vault-system get secret vault-init -o jsonpath='{.data.root-token}' | base64 -d
    return
  fi
  echo "vault-init secret missing" >&2
  exit 1
}

# best-effort check for placeholder-ish values
is_placeholder_token() {
  case "$1" in
    ""|REPLACE_*|PLACEHOLDER*|CHANGEME*|changeme*|__* )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

is_placeholder_value() {
  case "$1" in
    ""|REPLACE_*|PLACEHOLDER*|CHANGEME*|changeme*|__* )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# wait for a running vault pod with the "vault" container
wait_for_vault_pod() {
  while true; do
    pod=$(kubectl get pods -n vault-system -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
      containers=$(kubectl get pod "$pod" -n vault-system -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
      # Prefer exec readiness over Pod phase so bootstrap doesn't hang on stale status updates
      # (e.g. after forced deletions during wipe/reinit flows).
      if echo "$containers" | grep -q '\bvault\b' && kubectl -n vault-system exec "$pod" -- sh -c 'true' >/dev/null 2>&1; then
        printf '%s' "$pod"
        return
      fi
    fi
    phase=$(kubectl get pod "$pod" -n vault-system -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "waiting for vault pod exec readiness (phase=${phase:-n/a})..."
    sleep 5
  done
}

while true; do
  pod=$(wait_for_vault_pod)
  break
done

keycloak_ready() {
  # Only wait for JWKS if at least one Keycloak pod is Ready; skip on clean bootstrap.
  ready_status=$(kubectl -n keycloak get pods -l app.kubernetes.io/name=keycloak \
    -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null || true)
  printf '%s\n' "$ready_status" | grep -q "True"
}

if ! kubectl -n vault-system get secret vault-init >/dev/null 2>&1; then
  echo "vault-init secret missing" >&2
  exit 1
fi

root_token=$(wait_for_valid_root_token)

# Guard: ensure the Vault server has actually consumed the transit auto‑unseal token
# and did not start with the placeholder left in its config (the previous failure mode).
if kubectl -n vault-system exec "$pod" -- sh -c 'grep -q "__VAULT_SEAL_TOKEN__" /home/vault/storageconfig.hcl'; then
  echo "vault config still contains __VAULT_SEAL_TOKEN__; autounseal token not rendered into config" >&2
  exit 1
fi

attempt=1
while true; do
  # wait until vault is initialized
  if ! kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 vault status >/dev/null 2>&1; then
    msg="vault status unavailable"
  elif kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 vault status | grep -q 'Initialized *false'; then
    msg="vault not initialized yet"
  elif is_placeholder_token "$root_token"; then
    msg="root token looks like placeholder"
  elif kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" vault token lookup >/dev/null 2>&1; then
    break
  else
    msg="root token from vault-init not valid yet"
  fi
  echo "${msg} (attempt $attempt/$ROOT_TOKEN_RETRIES); sleeping ${ROOT_TOKEN_BACKOFF}s"
  if [ "$attempt" -ge "$ROOT_TOKEN_RETRIES" ]; then
    echo "root token from vault-init is not valid after $ROOT_TOKEN_RETRIES attempts" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep "$ROOT_TOKEN_BACKOFF"
done

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" vault status >/dev/null 2>&1 || true

random_password() {
  openssl rand -base64 24 | tr -d '\n'
}

random_hex_secret() {
  # Default to 24 bytes (48 hex chars) unless a different byte length is requested.
  # Some consumers (e.g. Garage RPC secret) require a specific size.
  openssl rand -hex "${1:-24}"
}

k8s_secret_field() {
  local ns="$1" name="$2" field="$3"
  kubectl -n "${ns}" get secret "${name}" -o "jsonpath={.data.${field}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

seed_forgejo_admin_secret() {
  echo "ensuring Forgejo admin PAT credentials exist in Vault"
  local admin_user admin_password
  # Prefer the real in-cluster Forgejo admin Secret (Helm-managed) so Vault/ESO doesn't
  # drift and break Argo repo auth with invalid credentials.
  admin_user=$(k8s_secret_field forgejo forgejo-admin username)
  admin_password=$(k8s_secret_field forgejo forgejo-admin password)
  if [ -n "${admin_user}" ] && [ -n "${admin_password}" ]; then
    kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c "
      set -eu
      vault kv put secret/forgejo/admin username='${admin_user}' password='${admin_password}' >/dev/null
    "
    echo "synced Forgejo admin credentials from forgejo/forgejo-admin into Vault (secret/forgejo/admin)"
    return 0
  fi

  # Fallback: create a placeholder secret (can be corrected later by init-vault-secrets.sh).
  admin_user="${FORGEJO_ADMIN_USERNAME:-forgejo-admin}"
  admin_password=$(random_password)
  seed_secret_if_missing "secret/forgejo/admin" "Forgejo admin credential (bootstrap placeholder)" \
    "username=${admin_user}" \
    "password=${admin_password}"
}

seed_forgejo_argocd_repo_token() {
  echo "ensuring Forgejo read-only token for ArgoCD exists in Vault"
  local path="secret/forgejo/argocd-repo"
  # Keep this idempotent and aligned with the in-cluster Forgejo instance so Argo/RepoServer
  # doesn't end up with invalid Vault-provisioned credentials.
  local admin_user admin_pass token
  admin_user=$(k8s_secret_field forgejo forgejo-admin username)
  admin_pass=$(k8s_secret_field forgejo forgejo-admin password)
  token=$(k8s_secret_field forgejo forgejo-admin-token token)
  if [ -z "${admin_user}" ] || [ -z "${admin_pass}" ]; then
    echo "forgejo/forgejo-admin secret not available yet; skipping ArgoCD repo credential seed (${path})" >&2
    return
  fi
  if [ -z "${token}" ]; then
    token="${admin_pass}"
  fi
  kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c "
    set -eu
    vault kv put ${path} username='${admin_user}' password='${token}' >/dev/null
  "
  echo "ensured Forgejo ArgoCD repo credentials in ${path}"
}

seed_forgejo_secrets() {
  echo "ensuring baseline Forgejo secrets exist in Vault"
  local redis_password superuser_password app_password
  redis_password=$(random_password)
  superuser_password=$(random_password)
  app_password=$(random_password)

  seed_secret_if_missing "secret/forgejo/redis" "Forgejo Valkey password" \
    "password=${redis_password}"

  seed_secret_if_missing "secret/forgejo/database" "Forgejo Postgres credentials" \
    "superuserPassword=${superuser_password}" \
    "appPassword=${app_password}"
}

seed_forgejo_team_sync() {
  echo "ensuring Forgejo team-sync secret exists in Vault"
  local pat client_id client_secret
  pat=$(random_hex_secret)
  client_id="${FORGEJO_TEAM_SYNC_CLIENT_ID:-forgejo-team-sync}"
  client_secret=$(random_hex_secret)
  seed_secret_if_missing "secret/forgejo/team-sync" "Forgejo team-sync PAT and Keycloak client" \
    "token=${pat}" \
    "keycloakClientId=${client_id}" \
    "keycloakClientSecret=${client_secret}"
}

seed_secret_if_missing() {
  local path="$1"
  local description="$2"
  shift 2
  local joined_fields
  joined_fields=$(printf '%s ' "$@")
  joined_fields="${joined_fields% }"
  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    SECRET_PATH="$path" \
    SECRET_FIELDS="$joined_fields" \
    SECRET_DESC="$description" \
    sh -c '
set -eu
if vault kv get "${SECRET_PATH}" >/dev/null 2>&1; then
  echo "secret ${SECRET_DESC} already exists (${SECRET_PATH})"
else
  echo "seeding ${SECRET_DESC} (${SECRET_PATH})"
  # shellcheck disable=SC2086
  vault kv put "${SECRET_PATH}" ${SECRET_FIELDS} >/dev/null
fi
'
}

seed_keycloak_secrets() {
  echo "ensuring baseline Keycloak secrets exist in Vault"
  local admin_password dev_password argocd_automation_password vault_automation_password db_password argocd_secret forgejo_secret kiali_secret harbor_secret hubble_secret vault_secret
  admin_password=$(random_password)
  dev_password=$(random_password)
  argocd_automation_password=$(random_password)
  vault_automation_password=$(random_password)
  db_password=$(random_password)
  argocd_secret=$(random_hex_secret)
  forgejo_secret=$(random_hex_secret)
  kiali_secret=$(random_hex_secret)
  harbor_secret=$(random_hex_secret)
  hubble_secret=$(random_hex_secret)
  vault_secret=$(random_hex_secret)

  seed_secret_if_missing "secret/keycloak/admin" "Keycloak master admin credential" \
    "username=${KEYCLOAK_ADMIN_USERNAME}" \
    "password=${admin_password}"

  seed_secret_if_missing "secret/keycloak/dev-user" "Keycloak developer user credential" \
    "username=${KEYCLOAK_DEV_USERNAME}" \
    "password=${dev_password}"

  seed_secret_if_missing "secret/keycloak/argocd-automation-user" "Keycloak Argo automation user credential" \
    "username=${KEYCLOAK_ARGO_AUTOMATION_USERNAME}" \
    "password=${argocd_automation_password}"

  seed_secret_if_missing "secret/keycloak/vault-automation-user" "Keycloak Vault automation user credential" \
    "username=${KEYCLOAK_VAULT_AUTOMATION_USERNAME}" \
    "password=${vault_automation_password}"

  # Legacy compatibility for callers still reading secret/keycloak/automation-user.
  seed_secret_if_missing "secret/keycloak/automation-user" "Keycloak automation user credential (legacy path)" \
    "username=${KEYCLOAK_ARGO_AUTOMATION_USERNAME}" \
    "password=${argocd_automation_password}"

  seed_secret_if_missing "secret/keycloak/database" "Keycloak database bootstrap credential" \
    "database=${KEYCLOAK_DB_NAME}" \
    "username=${KEYCLOAK_DB_USERNAME}" \
    "password=${db_password}"

  seed_secret_if_missing "secret/keycloak/argocd-client" "Argo CD OIDC client secret" \
    "clientId=${KEYCLOAK_ARGO_CLIENT_ID}" \
    "clientSecret=${argocd_secret}"

  seed_secret_if_missing "secret/keycloak/forgejo-client" "Forgejo OIDC client secret" \
    "clientId=${KEYCLOAK_FORGEJO_CLIENT_ID}" \
    "clientSecret=${forgejo_secret}"

  seed_secret_if_missing "secret/keycloak/kiali-client" "Kiali OIDC client secret" \
    "clientId=${KEYCLOAK_KIALI_CLIENT_ID}" \
    "clientSecret=${kiali_secret}"

  seed_secret_if_missing "secret/keycloak/harbor-client" "Harbor OIDC client secret" \
    "clientId=${KEYCLOAK_HARBOR_CLIENT_ID}" \
    "clientSecret=${harbor_secret}"

  seed_secret_if_missing "secret/keycloak/hubble-client" "Hubble oauth2-proxy OIDC client secret" \
    "clientId=${KEYCLOAK_HUBBLE_CLIENT_ID}" \
    "clientSecret=${hubble_secret}"

  seed_secret_if_missing "secret/keycloak/vault-client" "Vault CLI OIDC client secret" \
    "clientId=${KEYCLOAK_VAULT_CLIENT_ID}" \
    "clientSecret=${vault_secret}"

  # Optional upstream IAM providers still render as ExternalSecrets. Seed placeholders
  # so ESO stays Ready on fresh clusters until operators provide real upstream creds.
  seed_secret_if_missing "secret/keycloak/upstream-oidc" "Keycloak upstream OIDC placeholder" \
    "clientId=REPLACE_ME" \
    "clientSecret=REPLACE_ME" \
    "ca.crt=REPLACE_ME"

  seed_secret_if_missing "secret/keycloak/upstream-saml" "Keycloak upstream SAML placeholder" \
    "signingCert=REPLACE_ME"

  seed_secret_if_missing "secret/keycloak/upstream-ldap" "Keycloak upstream LDAP placeholder" \
    "bindDn=REPLACE_ME" \
    "bindPassword=REPLACE_ME"

  seed_secret_if_missing "secret/keycloak/upstream-scim" "Keycloak upstream SCIM placeholder" \
    "token=REPLACE_ME"
}

seed_hubble_oauth2_proxy_secrets() {
  echo "ensuring Hubble oauth2-proxy secrets exist in Vault"
  local cookie_secret
  cookie_secret=$(random_password)
  seed_secret_if_missing "secret/networking/hubble/oauth2-proxy" "Hubble oauth2-proxy cookie secret" \
    "cookieSecret=${cookie_secret}"
}

seed_observability_s3() {
  echo "ensuring observability S3 creds exist in Vault (loki/mimir/tempo)"
  local access secret bucket region endpoint
  access=$(random_hex_secret)
  secret=$(random_password)
  bucket="${OBS_BUCKET_PLATFORM:-observability}"
  region="${OBS_REGION:-us-east-1}"
  endpoint="${OBS_ENDPOINT:-http://garage.garage.svc:3900}"
  for svc in loki mimir tempo; do
    seed_secret_if_missing "secret/observability/${svc}" "Observability ${svc} S3 creds" \
      "accessKey=${access}" \
      "secretKey=${secret}" \
      "bucket=${bucket}-${svc}" \
      "endpoint=${endpoint}" \
      "region=${region}"
  done
}

seed_grafana_secrets() {
  echo "ensuring Grafana admin/OIDC secrets exist in Vault"
  local admin_user admin_password client_id client_secret base_url
  admin_user="${GRAFANA_ADMIN_USERNAME:-admin}"
  admin_password=$(random_password)
  client_id="${GRAFANA_OIDC_CLIENT_ID:-grafana}"
  client_secret=$(random_hex_secret)
  base_url="${GRAFANA_OIDC_BASE_URL:-__GRAFANA_OIDC_BASE_URL__}"
  seed_secret_if_missing "secret/observability/grafana" "Grafana admin credential" \
    "username=${admin_user}" \
    "password=${admin_password}"
  seed_secret_if_missing "secret/observability/grafana/oidc" "Grafana OIDC client" \
    "clientId=${client_id}" \
    "clientSecret=${client_secret}" \
    "authUrl=${base_url}/auth" \
    "tokenUrl=${base_url}/token" \
    "apiUrl=${base_url}/userinfo"
}

seed_alertmanager_notification_secrets() {
  echo "ensuring Alertmanager notification endpoints exist in Vault"
  local platform_webhook backup_webhook
  platform_webhook="${ALERTMANAGER_PLATFORM_WEBHOOK_URL:-https://alerts-placeholder.invalid/platform}"
  backup_webhook="${ALERTMANAGER_BACKUP_WEBHOOK_URL:-https://alerts-placeholder.invalid/backup}"
  seed_secret_if_missing "secret/observability/alertmanager" "Alertmanager notification routing" \
    "platformWebhookUrl=${platform_webhook}" \
    "backupWebhookUrl=${backup_webhook}"
}

seed_garage_secrets() {
  echo "ensuring Garage tokens and S3 creds exist in Vault"
  local admin metrics rpc access secret region endpoint bucket_logs bucket_traces bucket_metrics bucket_backups
  admin=$(random_hex_secret)
  metrics=$(random_hex_secret)
  # Garage expects a 32-byte RPC secret (64 hex chars).
  rpc=$(random_hex_secret 32)
  # Garage expects access key `GK` + 24 hex chars and a 64-hex secret key.
  access="GK$(random_hex_secret 12)"
  secret=$(random_hex_secret 32)
  region="${GARAGE_REGION:-us-east-1}"
  endpoint="${GARAGE_ENDPOINT:-http://garage.garage.svc:3900}"
  bucket_logs="${GARAGE_BUCKET_LOGS:-garage-logs}"
  bucket_traces="${GARAGE_BUCKET_TRACES:-garage-traces}"
  bucket_metrics="${GARAGE_BUCKET_METRICS:-garage-metrics}"
  bucket_backups="${GARAGE_BUCKET_BACKUPS:-garage-backups}"

  # Do repair/write operations inside the Vault pod: it has `sha256sum` available, but not `jq`.
  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    GARAGE_ADMIN_TOKEN_NEW="$admin" \
    GARAGE_METRICS_TOKEN_NEW="$metrics" \
    GARAGE_RPC_SECRET_NEW="$rpc" \
    S3_ACCESS_KEY_NEW="$access" \
    S3_SECRET_KEY_NEW="$secret" \
    S3_REGION_NEW="$region" \
    S3_ENDPOINT_NEW="$endpoint" \
    BUCKET_LOGS_NEW="$bucket_logs" \
    BUCKET_TRACES_NEW="$bucket_traces" \
    BUCKET_METRICS_NEW="$bucket_metrics" \
    BUCKET_BACKUPS_NEW="$bucket_backups" \
    sh -c '
set -eu

valid_rpc() { printf "%s" "$1" | grep -Eq "^[0-9a-fA-F]{64}$"; }
valid_access() { printf "%s" "$1" | grep -Eq "^GK[0-9a-fA-F]{24}$"; }
valid_secret() { printf "%s" "$1" | grep -Eq "^[0-9a-fA-F]{64}$"; }

sha256_hex() { printf "%s" "$1" | sha256sum | awk "{print \\$1}"; }
derive_access() { printf "GK%s" "$(sha256_hex "$1" | cut -c1-24)"; }
derive_secret() { sha256_hex "$1"; }

cred_path="secret/garage/credentials"
if vault kv get "${cred_path}" >/dev/null 2>&1; then
  current_rpc=$(vault kv get -field=GARAGE_RPC_SECRET "${cred_path}" 2>/dev/null || true)
  current_admin=$(vault kv get -field=GARAGE_ADMIN_TOKEN "${cred_path}" 2>/dev/null || true)
  current_metrics=$(vault kv get -field=GARAGE_METRICS_TOKEN "${cred_path}" 2>/dev/null || true)

  if valid_rpc "${current_rpc}"; then
    echo "secret Garage RPC/admin/metrics tokens already exists and looks valid (${cred_path})"
  else
    echo "repairing Garage RPC secret (${cred_path})"
    vault kv put "${cred_path}" \
      "GARAGE_ADMIN_TOKEN=${current_admin:-$GARAGE_ADMIN_TOKEN_NEW}" \
      "GARAGE_METRICS_TOKEN=${current_metrics:-$GARAGE_METRICS_TOKEN_NEW}" \
      "GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET_NEW}" >/dev/null
  fi
else
  echo "seeding Garage RPC/admin/metrics tokens (${cred_path})"
  vault kv put "${cred_path}" \
    "GARAGE_ADMIN_TOKEN=${GARAGE_ADMIN_TOKEN_NEW}" \
    "GARAGE_METRICS_TOKEN=${GARAGE_METRICS_TOKEN_NEW}" \
    "GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET_NEW}" >/dev/null
fi

s3_path="secret/garage/s3"
if vault kv get "${s3_path}" >/dev/null 2>&1; then
  current_access=$(vault kv get -field=S3_ACCESS_KEY "${s3_path}" 2>/dev/null || true)
  current_secret=$(vault kv get -field=S3_SECRET_KEY "${s3_path}" 2>/dev/null || true)
  current_region=$(vault kv get -field=S3_REGION "${s3_path}" 2>/dev/null || true)
  current_endpoint=$(vault kv get -field=S3_ENDPOINT "${s3_path}" 2>/dev/null || true)
  current_bucket_logs=$(vault kv get -field=BUCKET_LOGS "${s3_path}" 2>/dev/null || true)
  current_bucket_traces=$(vault kv get -field=BUCKET_TRACES "${s3_path}" 2>/dev/null || true)
  current_bucket_metrics=$(vault kv get -field=BUCKET_METRICS "${s3_path}" 2>/dev/null || true)
  current_bucket_backups=$(vault kv get -field=BUCKET_BACKUPS "${s3_path}" 2>/dev/null || true)

  repaired_access="${current_access}"
  if [ -z "${repaired_access}" ]; then
    repaired_access="${S3_ACCESS_KEY_NEW}"
  elif ! valid_access "${repaired_access}"; then
    repaired_access=$(derive_access "${current_access}")
  fi

  repaired_secret="${current_secret}"
  if [ -z "${repaired_secret}" ]; then
    repaired_secret="${S3_SECRET_KEY_NEW}"
  elif ! valid_secret "${repaired_secret}"; then
    repaired_secret=$(derive_secret "${current_secret}")
  fi

  if valid_access "${current_access}" && valid_secret "${current_secret}"; then
    echo "secret Garage S3 creds already exists and looks valid (${s3_path})"
  else
    echo "repairing Garage S3 creds (${s3_path})"
    vault kv put "${s3_path}" \
      "S3_ACCESS_KEY=${repaired_access}" \
      "S3_SECRET_KEY=${repaired_secret}" \
      "S3_REGION=${current_region:-$S3_REGION_NEW}" \
      "S3_ENDPOINT=${current_endpoint:-$S3_ENDPOINT_NEW}" \
      "BUCKET_LOGS=${current_bucket_logs:-$BUCKET_LOGS_NEW}" \
      "BUCKET_TRACES=${current_bucket_traces:-$BUCKET_TRACES_NEW}" \
      "BUCKET_METRICS=${current_bucket_metrics:-$BUCKET_METRICS_NEW}" \
      "BUCKET_BACKUPS=${current_bucket_backups:-$BUCKET_BACKUPS_NEW}" >/dev/null
  fi
else
  echo "seeding Garage S3 creds (${s3_path})"
  vault kv put "${s3_path}" \
    "S3_ACCESS_KEY=${S3_ACCESS_KEY_NEW}" \
    "S3_SECRET_KEY=${S3_SECRET_KEY_NEW}" \
    "S3_REGION=${S3_REGION_NEW}" \
    "S3_ENDPOINT=${S3_ENDPOINT_NEW}" \
    "BUCKET_LOGS=${BUCKET_LOGS_NEW}" \
    "BUCKET_TRACES=${BUCKET_TRACES_NEW}" \
    "BUCKET_METRICS=${BUCKET_METRICS_NEW}" \
    "BUCKET_BACKUPS=${BUCKET_BACKUPS_NEW}" >/dev/null
fi
'
}

seed_backup_system_pvc_restic_secret() {
  echo "ensuring backup-system PVC restic secret exists in Vault"
  local restic_password now
  restic_password=$(random_password)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    RESTIC_PASSWORD_NEW="$restic_password" \
    NOW="$now" \
    sh -c '
set -eu

path="secret/backup/pvc-restic"
if vault kv get "${path}" >/dev/null 2>&1; then
  current_password=$(vault kv get -field=RESTIC_PASSWORD "${path}" 2>/dev/null || true)
  current_candidate=$(vault kv get -field=RESTIC_PASSWORD_CANDIDATE "${path}" 2>/dev/null || true)
  current_version=$(vault kv get -field=PASSWORD_VERSION "${path}" 2>/dev/null || true)
  current_rotated_at=$(vault kv get -field=PASSWORD_ROTATED_AT "${path}" 2>/dev/null || true)

  next_password="${current_password:-$RESTIC_PASSWORD_NEW}"
  next_candidate="${current_candidate:-}"
  next_version="${current_version:-1}"
  next_rotated_at="${current_rotated_at:-$NOW}"

  echo "ensuring backup-system PVC restic metadata exists (${path})"
  vault kv patch "${path}" \
    "RESTIC_PASSWORD=${next_password}" \
    "RESTIC_PASSWORD_CANDIDATE=${next_candidate}" \
    "PASSWORD_VERSION=${next_version}" \
    "PASSWORD_ROTATED_AT=${next_rotated_at}" >/dev/null
else
  echo "seeding backup-system PVC restic secret (${path})"
  vault kv put "${path}" \
    "RESTIC_PASSWORD=${RESTIC_PASSWORD_NEW}" \
    "RESTIC_PASSWORD_CANDIDATE=" \
    "PASSWORD_VERSION=1" \
    "PASSWORD_ROTATED_AT=${NOW}" >/dev/null
fi
'
}

seed_backup_system_s3_mirror_crypt_secret() {
  echo "ensuring backup-system S3 mirror crypt secret exists in Vault"
  local crypt_password crypt_password2
  crypt_password=$(random_hex_secret 24)
  crypt_password2=$(random_hex_secret 24)

  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    RCLONE_CRYPT_PASSWORD_NEW="$crypt_password" \
    RCLONE_CRYPT_PASSWORD2_NEW="$crypt_password2" \
    sh -c '
set -eu

path="secret/backup/s3-mirror-crypt"
if vault kv get "${path}" >/dev/null 2>&1; then
  current_password=$(vault kv get -field=RCLONE_CRYPT_PASSWORD "${path}" 2>/dev/null || true)
  current_password2=$(vault kv get -field=RCLONE_CRYPT_PASSWORD2 "${path}" 2>/dev/null || true)

  next_password="${current_password:-$RCLONE_CRYPT_PASSWORD_NEW}"
  next_password2="${current_password2:-$RCLONE_CRYPT_PASSWORD2_NEW}"

  echo "ensuring backup-system S3 mirror crypt metadata exists (${path})"
  vault kv patch "${path}" \
    "RCLONE_CRYPT_PASSWORD=${next_password}" \
    "RCLONE_CRYPT_PASSWORD2=${next_password2}" >/dev/null
else
  echo "seeding backup-system S3 mirror crypt secret (${path})"
  vault kv put "${path}" \
    "RCLONE_CRYPT_PASSWORD=${RCLONE_CRYPT_PASSWORD_NEW}" \
    "RCLONE_CRYPT_PASSWORD2=${RCLONE_CRYPT_PASSWORD2_NEW}" >/dev/null
fi
'
}

seed_backup_system_s3_replication_target_secret() {
  echo "ensuring backup-system S3 replication target secret exists in Vault"

  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    sh -c '
set -eu

path="secret/backup/s3-replication-target"
if vault kv get "${path}" >/dev/null 2>&1; then
  echo "backup-system S3 replication target secret already exists (${path})"
  exit 0
fi

echo "seeding placeholder backup-system S3 replication target secret (${path})"
vault kv put "${path}" \
  "S3_ACCESS_KEY=REPLACE_ME" \
  "S3_SECRET_KEY=REPLACE_ME" >/dev/null
'
}

seed_harbor_secrets() {
  echo "ensuring Harbor secrets exist in Vault"
  local admin_password
  local core_secret global_secret_key csrf_key
  local jobservice_secret
  local registry_http_secret registry_credentials_password registry_credentials_htpasswd registry_credentials_hash
  local db_app_password db_superuser_password

  admin_password=$(random_password)

  # Harbor chart constraints:
  # - `secretKey`, `core.secret`, `jobservice.secret`, `registry.secret` must be 16 chars
  # - `core.xsrfKey` must be 32 chars
  core_secret=$(random_hex_secret 8)
  global_secret_key=$(random_hex_secret 8)
  csrf_key=$(random_hex_secret 16)
  jobservice_secret=$(random_hex_secret 8)
  registry_http_secret=$(random_hex_secret 8)

  registry_credentials_password=$(random_password)
  registry_credentials_hash=$(
    printf '%s' "${registry_credentials_password}" | openssl passwd -apr1 -stdin | tr -d '\n'
  )
  registry_credentials_htpasswd="harbor_registry_user:${registry_credentials_hash}"

  db_app_password=$(random_password)
  db_superuser_password=$(random_password)

  seed_secret_if_missing "secret/harbor/admin" "Harbor admin password" \
    "password=${admin_password}"

  seed_secret_if_missing "secret/harbor/core" "Harbor core secrets (core secret, secretKey, xsrf/csrf key)" \
    "secret=${core_secret}" \
    "secretKey=${global_secret_key}" \
    "csrfKey=${csrf_key}"

  seed_secret_if_missing "secret/harbor/jobservice" "Harbor jobservice secret" \
    "secret=${jobservice_secret}"

  seed_secret_if_missing "secret/harbor/registry" "Harbor registry secrets (http secret + registry credentials)" \
    "httpSecret=${registry_http_secret}" \
    "credentialsPassword=${registry_credentials_password}" \
    "credentialsHtpasswd=${registry_credentials_htpasswd}"

  seed_secret_if_missing "secret/harbor/database" "Harbor Postgres app/superuser passwords" \
    "appPassword=${db_app_password}" \
    "superuserPassword=${db_superuser_password}"
}

seed_powerdns_secrets() {
  echo "ensuring PowerDNS API/DB creds exist in Vault"
  local api_key db_password
  api_key=$(random_hex_secret)
  db_password=$(random_password)
  seed_secret_if_missing "secret/dns/powerdns/api" "PowerDNS API key" \
    "apiKey=${api_key}"
  seed_secret_if_missing "secret/dns/powerdns/postgres" "PowerDNS Postgres credentials" \
    "database=powerdns" \
    "username=powerdns" \
    "password=${db_password}"
}

seed_minecraft_monifactory_secrets() {
  echo "ensuring Minecraft (Monifactory) secrets exist in Vault"

  local seed_key rcon_password backup_prefix restic_password
  seed_key=$(k8s_secret_field vault-system minecraft-monifactory-seed curseforgeApiKey)
  if is_placeholder_value "${seed_key}"; then
    echo "minecraft-monifactory seed secret missing or placeholder (vault-system/minecraft-monifactory-seed:curseforgeApiKey); keeping placeholder in Vault"
    seed_key="REPLACE_ME"
  fi

  rcon_password=$(random_password)
  backup_prefix="${MINECRAFT_MONIFACTORY_BACKUP_PREFIX:-minecraft-monifactory}"
  restic_password=$(random_password)

  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    CURSEFORGE_API_KEY_NEW="$seed_key" \
    RCON_PASSWORD_NEW="$rcon_password" \
    BACKUP_PREFIX_NEW="$backup_prefix" \
    RESTIC_PASSWORD_NEW="$restic_password" \
    sh -c '
set -eu

is_placeholder() {
  case "$1" in
    ""|REPLACE_*|PLACEHOLDER*|CHANGEME*|changeme*|__* ) return 0 ;;
    * ) return 1 ;;
  esac
}

path="secret/apps/minecraft-monifactory"
	if vault kv get "${path}" >/dev/null 2>&1; then
	  current_key=$(vault kv get -field=curseforgeApiKey "${path}" 2>/dev/null || true)
	  current_rcon=$(vault kv get -field=rconPassword "${path}" 2>/dev/null || true)

	  next_key="${current_key}"
	  # Do not overwrite an existing non-placeholder CurseForge API key in Vault. The Kubernetes seed secret
	  # is intended for initial bootstrap only; treating it as an always-reconciling source makes manual
	  # rotation via `vault kv patch` non-durable.
	  if is_placeholder "${next_key}"; then
	    next_key="${CURSEFORGE_API_KEY_NEW}"
	  fi

	  next_rcon="${current_rcon}"
	  if [ -z "${next_rcon}" ]; then
	    next_rcon="${RCON_PASSWORD_NEW}"
	  fi

  if [ "${next_key}" != "${current_key}" ] || [ "${next_rcon}" != "${current_rcon}" ]; then
    echo "updating Minecraft secrets (${path})"
    vault kv put "${path}" \
      "curseforgeApiKey=${next_key}" \
      "rconPassword=${next_rcon}" >/dev/null
  else
    echo "Minecraft secrets already present (${path})"
  fi
else
  echo "seeding Minecraft secrets (${path})"
  vault kv put "${path}" \
    "curseforgeApiKey=${CURSEFORGE_API_KEY_NEW}" \
    "rconPassword=${RCON_PASSWORD_NEW}" >/dev/null
fi

access_path="secret/apps/minecraft-monifactory/access"
if vault kv get "${access_path}" >/dev/null 2>&1; then
  echo "Minecraft access lists already present (${access_path})"
else
  echo "seeding Minecraft access lists (${access_path})"
  vault kv put "${access_path}" \
    "whitelist=" \
    "ops=" >/dev/null
fi

backup_path="secret/apps/minecraft-monifactory/backup"
if vault kv get "secret/garage/s3" >/dev/null 2>&1; then
  s3_access=$(vault kv get -field=S3_ACCESS_KEY "secret/garage/s3" 2>/dev/null || true)
  s3_secret=$(vault kv get -field=S3_SECRET_KEY "secret/garage/s3" 2>/dev/null || true)
  s3_region=$(vault kv get -field=S3_REGION "secret/garage/s3" 2>/dev/null || true)
  s3_endpoint=$(vault kv get -field=S3_ENDPOINT "secret/garage/s3" 2>/dev/null || true)
  s3_bucket_backups=$(vault kv get -field=BUCKET_BACKUPS "secret/garage/s3" 2>/dev/null || true)
else
  s3_access=""
  s3_secret=""
  s3_region=""
  s3_endpoint=""
  s3_bucket_backups=""
fi

backup_bucket="${s3_bucket_backups:-garage-backups}"
backup_repo="s3:${s3_endpoint}/${backup_bucket}/${BACKUP_PREFIX_NEW}"

if vault kv get "${backup_path}" >/dev/null 2>&1; then
  current_bucket=$(vault kv get -field=S3_BUCKET "${backup_path}" 2>/dev/null || true)
  current_repo=$(vault kv get -field=RESTIC_REPOSITORY "${backup_path}" 2>/dev/null || true)
  current_password=$(vault kv get -field=RESTIC_PASSWORD "${backup_path}" 2>/dev/null || true)

  next_bucket="${current_bucket:-$backup_bucket}"
  next_repo="${current_repo:-$backup_repo}"
  next_password="${current_password:-$RESTIC_PASSWORD_NEW}"

  echo "ensuring Minecraft backup config exists (${backup_path})"
  vault kv put "${backup_path}" \
    "S3_ACCESS_KEY=${s3_access}" \
    "S3_SECRET_KEY=${s3_secret}" \
    "S3_REGION=${s3_region}" \
    "S3_ENDPOINT=${s3_endpoint}" \
    "S3_BUCKET=${next_bucket}" \
    "RESTIC_REPOSITORY=${next_repo}" \
    "RESTIC_PASSWORD=${next_password}" >/dev/null
else
  echo "seeding Minecraft backup config (${backup_path})"
  vault kv put "${backup_path}" \
    "S3_ACCESS_KEY=${s3_access}" \
    "S3_SECRET_KEY=${s3_secret}" \
    "S3_REGION=${s3_region}" \
    "S3_ENDPOINT=${s3_endpoint}" \
    "S3_BUCKET=${backup_bucket}" \
    "RESTIC_REPOSITORY=${backup_repo}" \
    "RESTIC_PASSWORD=${RESTIC_PASSWORD_NEW}" >/dev/null
fi
'
}

seed_factorio_secrets() {
  echo "ensuring Factorio secrets exist in Vault"

  local backup_prefix restic_password
  backup_prefix="${FACTORIO_BACKUP_PREFIX:-factorio}"
  restic_password=$(random_password)

  kubectl -n vault-system exec "$pod" -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    VAULT_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    VAULT_TOKEN="$root_token" \
    BACKUP_PREFIX_NEW="$backup_prefix" \
    RESTIC_PASSWORD_NEW="$restic_password" \
    sh -c '
set -eu

path="secret/apps/factorio"
if vault kv get "${path}" >/dev/null 2>&1; then
  current_username=$(vault kv get -field=username "${path}" 2>/dev/null || true)
  current_token=$(vault kv get -field=token "${path}" 2>/dev/null || true)

  next_username="${current_username:-}"
  next_token="${current_token:-}"

  echo "ensuring Factorio secrets exist (${path})"
  vault kv put "${path}" \
    "username=${next_username}" \
    "token=${next_token}" >/dev/null
else
  echo "seeding Factorio secrets (${path})"
  vault kv put "${path}" \
    "username=" \
    "token=" >/dev/null
fi

backup_path="secret/apps/factorio/backup"
if vault kv get "secret/garage/s3" >/dev/null 2>&1; then
  s3_access=$(vault kv get -field=S3_ACCESS_KEY "secret/garage/s3" 2>/dev/null || true)
  s3_secret=$(vault kv get -field=S3_SECRET_KEY "secret/garage/s3" 2>/dev/null || true)
  s3_region=$(vault kv get -field=S3_REGION "secret/garage/s3" 2>/dev/null || true)
  s3_endpoint=$(vault kv get -field=S3_ENDPOINT "secret/garage/s3" 2>/dev/null || true)
  s3_bucket_backups=$(vault kv get -field=BUCKET_BACKUPS "secret/garage/s3" 2>/dev/null || true)
else
  s3_access=""
  s3_secret=""
  s3_region=""
  s3_endpoint=""
  s3_bucket_backups=""
fi

backup_bucket="${s3_bucket_backups:-garage-backups}"
backup_repo="s3:${s3_endpoint}/${backup_bucket}/${BACKUP_PREFIX_NEW}"

if vault kv get "${backup_path}" >/dev/null 2>&1; then
  current_bucket=$(vault kv get -field=S3_BUCKET "${backup_path}" 2>/dev/null || true)
  current_repo=$(vault kv get -field=RESTIC_REPOSITORY "${backup_path}" 2>/dev/null || true)
  current_password=$(vault kv get -field=RESTIC_PASSWORD "${backup_path}" 2>/dev/null || true)

  next_bucket="${current_bucket:-$backup_bucket}"
  next_repo="${current_repo:-$backup_repo}"
  next_password="${current_password:-$RESTIC_PASSWORD_NEW}"

  echo "ensuring Factorio backup config exists (${backup_path})"
  vault kv put "${backup_path}" \
    "S3_ACCESS_KEY=${s3_access}" \
    "S3_SECRET_KEY=${s3_secret}" \
    "S3_REGION=${s3_region}" \
    "S3_ENDPOINT=${s3_endpoint}" \
    "S3_BUCKET=${next_bucket}" \
    "RESTIC_REPOSITORY=${next_repo}" \
    "RESTIC_PASSWORD=${next_password}" >/dev/null
else
  echo "seeding Factorio backup config (${backup_path})"
  vault kv put "${backup_path}" \
    "S3_ACCESS_KEY=${s3_access}" \
    "S3_SECRET_KEY=${s3_secret}" \
    "S3_REGION=${s3_region}" \
    "S3_ENDPOINT=${s3_endpoint}" \
    "S3_BUCKET=${backup_bucket}" \
    "RESTIC_REPOSITORY=${backup_repo}" \
    "RESTIC_PASSWORD=${RESTIC_PASSWORD_NEW}" >/dev/null
fi
'
}

seed_step_ca_material() {
  echo "ensuring Step CA material exists in Vault"
  # Skip if already present to avoid overwriting real CA material on future bootstraps
  if kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" vault kv get secret/step-ca/certs >/dev/null 2>&1; then
    echo "Step CA material already present; skipping generation"
    return
  fi
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  # generate locally
  openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=Step-Root" -keyout "$tmpdir/root_ca.key" -out "$tmpdir/root_ca.crt" -days 3650 >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj "/CN=Step-Intermediate" -keyout "$tmpdir/intermediate.key" -out "$tmpdir/intermediate.csr" >/dev/null 2>&1
  openssl x509 -req -in "$tmpdir/intermediate.csr" -CA "$tmpdir/root_ca.crt" -CAkey "$tmpdir/root_ca.key" -CAcreateserial -out "$tmpdir/intermediate.crt" -days 1825 >/dev/null 2>&1
  cat > "$tmpdir/ca.json" <<'EOF'
{
  "address": ":9000",
  "authority": {
    "provisioners": [],
    "claims": {
      "minTLSCertDuration": "5m",
      "maxTLSCertDuration": "24h",
      "defaultTLSCertDuration": "24h"
    }
  }
}
EOF
  cat > "$tmpdir/defaults.json" <<'EOF'
{
  "dnsNames": ["localhost"],
  "ca-url": "https://step-ca.step-system.svc.cluster.local",
  "fingerprint": "",
  "root": "root_ca.crt"
}
EOF
  cat > "$tmpdir/x509_leaf.tpl" <<'EOF'
{
  "subject": {
    "commonName": "{{ .CommonName }}"
  },
  "dnsNames": {{ toJson .SANs.DNS }}
}
EOF

  ca_password=$(random_password)
  provisioner_password=$(random_password)

  root_ca_crt_b64=$(base64 < "$tmpdir/root_ca.crt")
  intermediate_crt_b64=$(base64 < "$tmpdir/intermediate.crt")
  root_ca_key_b64=$(base64 < "$tmpdir/root_ca.key")
  intermediate_key_b64=$(base64 < "$tmpdir/intermediate.key")
  ca_json_b64=$(base64 < "$tmpdir/ca.json")
  defaults_json_b64=$(base64 < "$tmpdir/defaults.json")
  leaf_tpl_b64=$(base64 < "$tmpdir/x509_leaf.tpl")

  kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" ROOT_CA_CRT_B64="$root_ca_crt_b64" INT_CA_CRT_B64="$intermediate_crt_b64" ROOT_CA_KEY_B64="$root_ca_key_b64" INT_CA_KEY_B64="$intermediate_key_b64" CA_JSON_B64="$ca_json_b64" DEFAULTS_JSON_B64="$defaults_json_b64" LEAF_TPL_B64="$leaf_tpl_b64" CA_PASSWORD="$ca_password" PROVISIONER_PASSWORD="$provisioner_password" sh -c '
set -eu
mkdir -p /home/vault/tmp/step
printf "%s" "$ROOT_CA_CRT_B64" | base64 -d > /home/vault/tmp/step/root_ca.crt
printf "%s" "$INT_CA_CRT_B64" | base64 -d > /home/vault/tmp/step/intermediate.crt
printf "%s" "$ROOT_CA_KEY_B64" | base64 -d > /home/vault/tmp/step/root_ca.key
printf "%s" "$INT_CA_KEY_B64" | base64 -d > /home/vault/tmp/step/intermediate.key
printf "%s" "$CA_JSON_B64" | base64 -d > /home/vault/tmp/step/ca.json
printf "%s" "$DEFAULTS_JSON_B64" | base64 -d > /home/vault/tmp/step/defaults.json
printf "%s" "$LEAF_TPL_B64" | base64 -d > /home/vault/tmp/step/x509_leaf.tpl
vault kv put secret/step-ca/certs root_ca_crt=@/home/vault/tmp/step/root_ca.crt intermediate_ca_crt=@/home/vault/tmp/step/intermediate.crt >/dev/null
vault kv put secret/step-ca/keys root_ca_key=@/home/vault/tmp/step/root_ca.key intermediate_ca_key=@/home/vault/tmp/step/intermediate.key >/dev/null
vault kv put secret/step-ca/config ca_json=@/home/vault/tmp/step/ca.json defaults_json=@/home/vault/tmp/step/defaults.json x509_leaf_tpl=@/home/vault/tmp/step/x509_leaf.tpl >/dev/null
vault kv put secret/step-ca/passwords ca_password="$CA_PASSWORD" provisioner_password="$PROVISIONER_PASSWORD" >/dev/null
rm -rf /home/vault/tmp/step
'
}

token_reviewer_jwt_b64="$(kubectl -n vault-system get secret vault-kubernetes-tokenreviewer -o jsonpath='{.data.token}' 2>/dev/null || true)"

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" TOKEN_REVIEWER_JWT_B64="$token_reviewer_jwt_b64" sh -c '
set -eu
vault auth enable kubernetes >/dev/null 2>&1 || true
issuer=""
token_reviewer_jwt=""
if [ -n "${TOKEN_REVIEWER_JWT_B64:-}" ]; then
  token_reviewer_jwt="$(printf "%s" "${TOKEN_REVIEWER_JWT_B64}" | base64 -d 2>/dev/null || true)"
fi
tok="/var/run/secrets/kubernetes.io/serviceaccount/token"
if [ -f "${tok}" ]; then
  payload="$(cut -d. -f2 < "${tok}" | tr "_-" "/+")"
  case $((${#payload} % 4)) in
    2) payload="${payload}==";;
    3) payload="${payload}=";;
  esac
  issuer="$(printf "%s" "${payload}" | base64 -d 2>/dev/null | sed -n "s/.*\\\"iss\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p" | head -n1)"
  if [ -z "${token_reviewer_jwt}" ]; then
    token_reviewer_jwt="$(cat "${tok}" 2>/dev/null || true)"
  fi
fi

if [ -n "${issuer}" ]; then
  echo "[vault-configure] detected service account issuer: ${issuer}" >&2
  vault write auth/kubernetes/config \
    token_reviewer_jwt="${token_reviewer_jwt}" \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    issuer="${issuer}" >/dev/null
else
  echo "[vault-configure] warning: could not detect service account issuer; configuring without explicit issuer validation" >&2
  vault write auth/kubernetes/config \
    token_reviewer_jwt="${token_reviewer_jwt}" \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt >/dev/null
fi
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
vault secrets enable -path=secret kv-v2 >/dev/null 2>&1 || true
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
mkdir -p /home/vault/tmp
cat <<'EOF' >/home/vault/tmp/external-secrets.hcl
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF
vault policy write external-secrets /home/vault/tmp/external-secrets.hcl >/dev/null
rm -f /home/vault/tmp/external-secrets.hcl
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="external-secrets" \
  token_ttl="24h" >/dev/null
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
mkdir -p /home/vault/tmp
cat <<'"'"'EOF'"'"' >/home/vault/tmp/tenant-smoke-project-demo-backup-provisioner.hcl
path "secret/data/tenants/smoke/projects/demo/sys/backup" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/tenants/smoke/projects/demo/sys/backup" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
vault policy write tenant-smoke-project-demo-backup-provisioner /home/vault/tmp/tenant-smoke-project-demo-backup-provisioner.hcl >/dev/null
rm -f /home/vault/tmp/tenant-smoke-project-demo-backup-provisioner.hcl
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
vault write auth/kubernetes/role/k8s-tenant-smoke-project-demo-garage-backup-provisioner \
  bound_service_account_names="garage-tenant-backup-provisioner" \
  bound_service_account_namespaces="garage" \
  policies="tenant-smoke-project-demo-backup-provisioner" \
  token_ttl="1h" \
  token_max_ttl="4h" >/dev/null
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
mkdir -p /home/vault/tmp
cat <<'EOF' >/home/vault/tmp/keycloak-bootstrap.hcl
path "secret/data/keycloak/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/keycloak/*" {
  capabilities = ["read", "list"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
vault policy write keycloak-bootstrap /home/vault/tmp/keycloak-bootstrap.hcl >/dev/null
rm -f /home/vault/tmp/keycloak-bootstrap.hcl
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
vault write auth/kubernetes/role/keycloak-bootstrap \
  bound_service_account_names="keycloak-bootstrap" \
  bound_service_account_namespaces="keycloak" \
  policies="keycloak-bootstrap" \
  token_ttl="1h" \
  token_max_ttl="4h" >/dev/null
'

kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
vault kv put secret/bootstrap message="Vault is wired to External Secrets Operator" >/dev/null
'

seed_keycloak_secrets
seed_hubble_oauth2_proxy_secrets

seed_forgejo_admin_secret
seed_forgejo_argocd_repo_token
seed_forgejo_secrets
seed_forgejo_team_sync
seed_observability_s3
seed_grafana_secrets
seed_alertmanager_notification_secrets
seed_garage_secrets
seed_backup_system_pvc_restic_secret
seed_backup_system_s3_mirror_crypt_secret
seed_backup_system_s3_replication_target_secret
seed_harbor_secrets
seed_minecraft_monifactory_secrets
seed_factorio_secrets
seed_powerdns_secrets
seed_step_ca_material

log "seeding forgejo team-sync policy and role"
kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
mkdir -p /home/vault/tmp
cat <<'"'"'EOF'"'"' >/home/vault/tmp/forgejo-team-sync.hcl
path "secret/data/forgejo/team-sync" {
  capabilities = ["create", "update", "read", "list"]
}
path "secret/metadata/forgejo/team-sync" {
  capabilities = ["read", "list"]
}
EOF
vault policy write forgejo-team-sync /home/vault/tmp/forgejo-team-sync.hcl >/dev/null
rm -f /home/vault/tmp/forgejo-team-sync.hcl
vault write auth/kubernetes/role/forgejo-team-sync \
  bound_service_account_names="forgejo-team-sync" \
  bound_service_account_namespaces="rbac-system,forgejo" \
  policies="forgejo-team-sync" \
  token_ttl="1h" \
  token_max_ttl="4h" >/dev/null
'

log "seeding forgejo admin sync policy and role"
kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
mkdir -p /home/vault/tmp
cat <<'"'"'EOF'"'"' >/home/vault/tmp/forgejo-admin-sync.hcl
path "secret/data/forgejo/admin" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/forgejo/admin" {
  capabilities = ["read", "list"]
}
EOF
vault policy write forgejo-admin-sync /home/vault/tmp/forgejo-admin-sync.hcl >/dev/null
rm -f /home/vault/tmp/forgejo-admin-sync.hcl
vault write auth/kubernetes/role/forgejo-admin-sync \
  bound_service_account_names="forgejo-admin-sync" \
  bound_service_account_namespaces="forgejo" \
  policies="forgejo-admin-sync" \
  token_ttl="1h" \
  token_max_ttl="4h" >/dev/null
'

log "seeding keycloak OIDC CA sync policy and role"
kubectl -n vault-system exec "$pod" -- env BAO_ADDR=http://127.0.0.1:8200 VAULT_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" VAULT_TOKEN="$root_token" sh -c '
set -eu
mkdir -p /home/vault/tmp
cat <<'"'"'EOF'"'"' >/home/vault/tmp/keycloak-oidc-ca-sync.hcl
path "secret/data/keycloak/oidc-ca" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/keycloak/oidc-ca" {
  capabilities = ["read", "list"]
}
EOF
vault policy write keycloak-oidc-ca-sync /home/vault/tmp/keycloak-oidc-ca-sync.hcl >/dev/null
rm -f /home/vault/tmp/keycloak-oidc-ca-sync.hcl
vault write auth/kubernetes/role/keycloak-oidc-ca-sync \
  bound_service_account_names="keycloak-oidc-ca-sync" \
  bound_service_account_namespaces="step-system" \
  policies="keycloak-oidc-ca-sync" \
  token_ttl="15m" \
  token_max_ttl="1h" >/dev/null
'

SKIP_KEYCLOAK_JWKS_WAIT="false"
case "$KEYCLOAK_JWKS_WAIT_MODE" in
  never)
    SKIP_KEYCLOAK_JWKS_WAIT="true"
    log "KEYCLOAK_JWKS_WAIT_MODE=never; skipping Keycloak JWKS wait"
    ;;
  always)
    ;;
  auto)
    if ! keycloak_ready; then
      SKIP_KEYCLOAK_JWKS_WAIT="true"
      log "Keycloak not Ready yet; skipping JWKS wait to avoid bootstrap deadlock"
    fi
    ;;
  *)
    log "unknown KEYCLOAK_JWKS_WAIT_MODE=${KEYCLOAK_JWKS_WAIT_MODE}; defaulting to auto"
    if ! keycloak_ready; then
      SKIP_KEYCLOAK_JWKS_WAIT="true"
      log "Keycloak not Ready yet; skipping JWKS wait to avoid bootstrap deadlock"
    fi
    ;;
esac

log "configuring JWT auth for automation (Keycloak -> Vault)"
kubectl -n vault-system exec "$pod" -- env \
  BAO_ADDR=http://127.0.0.1:8200 \
  VAULT_ADDR=http://127.0.0.1:8200 \
  BAO_TOKEN="$root_token" \
  VAULT_TOKEN="$root_token" \
  VAULT_JWT_MOUNT="$VAULT_JWT_MOUNT" \
  KEYCLOAK_OIDC_ISSUER="$KEYCLOAK_OIDC_ISSUER" \
  KEYCLOAK_OIDC_JWKS_URL_INTERNAL="$KEYCLOAK_OIDC_JWKS_URL_INTERNAL" \
  KEYCLOAK_TOKEN_URL_INTERNAL="$KEYCLOAK_TOKEN_URL_INTERNAL" \
  KEYCLOAK_VAULT_CLIENT_ID="$KEYCLOAK_VAULT_CLIENT_ID" \
  KEYCLOAK_VAULT_AUTOMATION_PATH="$KEYCLOAK_VAULT_AUTOMATION_PATH" \
  KEYCLOAK_VAULT_CLIENT_PATH="$KEYCLOAK_VAULT_CLIENT_PATH" \
  VAULT_AUTOMATION_ROLE="$VAULT_AUTOMATION_ROLE" \
  VAULT_AUTOMATION_AUDIENCE="$VAULT_AUTOMATION_AUDIENCE" \
  VAULT_AUTOMATION_BOUND_AUDIENCE="$VAULT_AUTOMATION_BOUND_AUDIENCE" \
  VAULT_AUTOMATION_GROUP="$VAULT_AUTOMATION_GROUP" \
  VAULT_AUTOMATION_SUBJECT="$VAULT_AUTOMATION_SUBJECT" \
  SKIP_KEYCLOAK_JWKS_WAIT="$SKIP_KEYCLOAK_JWKS_WAIT" \
  sh -c '
set -eu
mkdir -p /home/vault/tmp

JWKS_WAIT_SECONDS="${JWKS_WAIT_SECONDS:-60}"
JWKS_POLL_SECONDS="${JWKS_POLL_SECONDS:-5}"

if [ "${SKIP_KEYCLOAK_JWKS_WAIT:-false}" = "true" ]; then
  JWKS_WAIT_SECONDS=0
fi

wait_for_keycloak_jwks() {
  if [ "$JWKS_WAIT_SECONDS" -le 0 ]; then
    return 1
  fi
  elapsed=0
  while [ "$elapsed" -lt "$JWKS_WAIT_SECONDS" ]; do
    if command -v wget >/dev/null 2>&1; then
      if wget -q -T 5 -O- "$KEYCLOAK_OIDC_JWKS_URL_INTERNAL" 2>/dev/null | grep -q "\"keys\""; then
        return 0
      fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -fsS --max-time 5 "$KEYCLOAK_OIDC_JWKS_URL_INTERNAL" 2>/dev/null | grep -q "\"keys\""; then
        return 0
      fi
    else
      echo "neither wget nor curl is available to probe Keycloak JWKS URL" >&2
      return 1
    fi

    echo "waiting for Keycloak JWKS to be reachable: ${KEYCLOAK_OIDC_JWKS_URL_INTERNAL} (${elapsed}s/${JWKS_WAIT_SECONDS}s)" >&2
    sleep "$JWKS_POLL_SECONDS"
    elapsed=$((elapsed + JWKS_POLL_SECONDS))
  done

  echo "timed out waiting for Keycloak JWKS URL to become reachable: ${KEYCLOAK_OIDC_JWKS_URL_INTERNAL}" >&2
  return 1
}

# Enable JWT auth (idempotent)
vault auth enable -path="$VAULT_JWT_MOUNT" jwt >/dev/null 2>&1 || true

# Verify tokens against Keycloak issuer, but fetch JWKS via the in-cluster Keycloak service
# to avoid Step-CA trust churn on the Vault side. Do not fail bootstrap if Keycloak
# is still starting; Vault does not require a live JWKS endpoint at config time.
SKIP_JWT_CONFIG="false"
if [ "$JWKS_WAIT_SECONDS" -le 0 ]; then
  echo "skipping Keycloak JWKS wait; Keycloak not Ready yet" >&2
  SKIP_JWT_CONFIG="true"
else
  if ! wait_for_keycloak_jwks; then
    echo "Keycloak JWKS not reachable yet; deferring JWT auth config" >&2
    SKIP_JWT_CONFIG="true"
  fi
fi

if [ "$SKIP_JWT_CONFIG" != "true" ]; then
  vault write "auth/${VAULT_JWT_MOUNT}/config" \
    bound_issuer="$KEYCLOAK_OIDC_ISSUER" \
    jwks_url="$KEYCLOAK_OIDC_JWKS_URL_INTERNAL" \
    jwt_supported_algs="RS256" >/dev/null
fi

cat <<'"'"'EOF'"'"' >/home/vault/tmp/automation-write.hcl
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "sys/capabilities-self" {
  capabilities = ["update"]
}
EOF
vault policy write automation-write /home/vault/tmp/automation-write.hcl >/dev/null
rm -f /home/vault/tmp/automation-write.hcl

if [ "$SKIP_JWT_CONFIG" = "true" ]; then
  echo "JWT backend config deferred; still enforcing JWT role claims/policies" >&2
fi

if [ -z "${VAULT_AUTOMATION_SUBJECT:-}" ]; then
  automation_json="$(vault kv get -format=json "${KEYCLOAK_VAULT_AUTOMATION_PATH}" 2>/dev/null || true)"
  automation_username="$(printf "%s" "${automation_json}" | jq -r ".data.data.username // empty" 2>/dev/null || true)"
  automation_password="$(printf "%s" "${automation_json}" | jq -r ".data.data.password // empty" 2>/dev/null || true)"
  vault_client_json="$(vault kv get -format=json "${KEYCLOAK_VAULT_CLIENT_PATH}" 2>/dev/null || true)"
  vault_client_secret="$(printf "%s" "${vault_client_json}" | jq -r ".data.data.clientSecret // empty" 2>/dev/null || true)"
  if [ -n "${automation_username}" ] && [ -n "${automation_password}" ] && [ -n "${vault_client_secret}" ]; then
    token_json="$(curl -fsS --max-time 8 -X POST "${KEYCLOAK_TOKEN_URL_INTERNAL}" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=${KEYCLOAK_VAULT_CLIENT_ID}" \
      --data-urlencode "client_secret=${vault_client_secret}" \
      --data-urlencode "username=${automation_username}" \
      --data-urlencode "password=${automation_password}" \
      --data-urlencode "scope=openid profile email roles" 2>/dev/null || true)"
    access_token="$(printf "%s" "${token_json}" | jq -r ".access_token // empty" 2>/dev/null || true)"
    if [ -n "${access_token}" ]; then
      token_claims="$(jq -rRn --arg t "${access_token}" "(\$t | split(\".\")[1]) as \$p | (\$p | gsub(\"-\"; \"+\") | gsub(\"_\"; \"/\") | . + (\"=\" * ((4 - (length % 4)) % 4)) | @base64d | fromjson)" 2>/dev/null || true)"
      if [ -n "${token_claims}" ] && [ "${token_claims}" != "null" ]; then
        VAULT_AUTOMATION_SUBJECT="$(printf "%s" "${token_claims}" | jq -r ".sub // empty" 2>/dev/null || true)"
        resolved_audience="$(printf "%s" "${token_claims}" | jq -r --arg client "${KEYCLOAK_VAULT_CLIENT_ID}" \
          "(.aud // empty) as \$aud \
          | if (\$aud | type) == \"string\" then \$aud \
            elif (\$aud | type) == \"array\" then \
              (if (\$aud | index(\$client)) != null then \$client \
               elif (\$aud | index(\"account\")) != null then \"account\" \
               else (\$aud[0] // empty) end) \
            else empty end" 2>/dev/null || true)"
        if [ -n "${resolved_audience:-}" ]; then
          VAULT_AUTOMATION_BOUND_AUDIENCE="${resolved_audience}"
        fi
      fi
    fi
  fi
fi

if [ -n "${VAULT_AUTOMATION_SUBJECT:-}" ]; then
  echo "resolved automation subject for Vault JWT role: ${VAULT_AUTOMATION_SUBJECT}" >&2
else
  echo "unable to resolve automation subject; writing Vault JWT role without bound_subject" >&2
fi
echo "resolved automation audience for Vault JWT role: ${VAULT_AUTOMATION_BOUND_AUDIENCE}" >&2

tmp_role="/home/vault/tmp/jwt-role.json"
if [ -n "${VAULT_AUTOMATION_SUBJECT:-}" ]; then
  cat > "${tmp_role}" <<EOF
{
  "role_type": "jwt",
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "bound_subject": "${VAULT_AUTOMATION_SUBJECT}",
  "bound_audiences": ["${VAULT_AUTOMATION_BOUND_AUDIENCE}", "${KEYCLOAK_VAULT_CLIENT_ID}", "account"],
  "bound_claims": {"groups": "${VAULT_AUTOMATION_GROUP}", "azp": "${KEYCLOAK_VAULT_CLIENT_ID}"},
  "token_policies": ["automation-write"],
  "token_ttl": "15m",
  "token_max_ttl": "1h"
}
EOF
else
  cat > "${tmp_role}" <<EOF
{
  "role_type": "jwt",
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "bound_audiences": ["${VAULT_AUTOMATION_BOUND_AUDIENCE}", "${KEYCLOAK_VAULT_CLIENT_ID}", "account"],
  "bound_claims": {"groups": "${VAULT_AUTOMATION_GROUP}", "azp": "${KEYCLOAK_VAULT_CLIENT_ID}"},
  "token_policies": ["automation-write"],
  "token_ttl": "15m",
  "token_max_ttl": "1h"
}
EOF
fi
role_path="auth/${VAULT_JWT_MOUNT}/role/${VAULT_AUTOMATION_ROLE}"
vault delete "${role_path}" >/dev/null 2>&1 || true
vault write "${role_path}" @"${tmp_role}" >/dev/null
rm -f "${tmp_role}" >/dev/null 2>&1 || true
'

kubectl -n vault-system create configmap "${CONFIGMAP_NAME}" \
  --from-literal=job=vault-configure \
  --from-literal=completedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --dry-run=client -o yaml | kubectl apply -f -
