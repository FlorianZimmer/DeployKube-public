#!/usr/bin/env bash
# =============================================================================
# DeployKube Proxmox Talos - Stage 1: GitOps Bootstrap
# =============================================================================
#
# This script bootstraps the GitOps infrastructure:
#   1. Install Forgejo in bootstrap mode (SQLite, HTTP)
#   2. Seed GitOps repository
#   3. Install Argo CD
#   4. Apply root Application (platform-apps)
#   5. Wait for initial sync
#
# This is adapted from bootstrap-mac-orbstack-stage1.sh for Proxmox/Talos.
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap/proxmox-talos"

# Config
CONFIG_FILE="${CONFIG_FILE:-${BOOTSTRAP_DIR}/config.yaml}"
KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/tmp/kubeconfig-prod}"
export KUBECONFIG

# Offline bundle (Phase 0): when set, Stage 1 must not fetch charts from the internet.
OFFLINE_BUNDLE_DIR="${OFFLINE_BUNDLE_DIR:-}"

# GitOps settings
GITOPS_SOURCE="${GITOPS_SOURCE:-${REPO_ROOT}/platform/gitops}"
GITOPS_OVERLAY="${GITOPS_OVERLAY:-proxmox-talos}"
GITOPS_REVISION="${GITOPS_REVISION:-main}"
AUTO_RESEED_ON_COMPARISON_ERROR="${AUTO_RESEED_ON_COMPARISON_ERROR:-true}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ROOT_APPLICATION="${ROOT_APPLICATION:-platform-apps}"
WAIT_FOR_PLATFORM_APPS="${WAIT_FOR_PLATFORM_APPS:-true}"
PLATFORM_APPS_AUTOSYNC="${PLATFORM_APPS_AUTOSYNC:-true}"

# Argo CD bootstrap install (must match GitOps assumptions for object names)
ARGO_RELEASE="${ARGO_RELEASE:-argo-cd}"
ARGO_CHART="${ARGO_CHART:-argo/argo-cd}"
ARGO_CHART_VERSION="${ARGO_CHART_VERSION:-9.1.0}"
ARGO_APP_VERSION="${ARGO_APP_VERSION:-v3.2.0}"
ARGO_MIGRATE_LEGACY_RELEASE="${ARGO_MIGRATE_LEGACY_RELEASE:-true}"
ARGO_VALUES_RESOURCES="${ARGO_VALUES_RESOURCES:-${REPO_ROOT}/bootstrap/shared/argocd/values-resources.yaml}"
ARGO_VALUES_PROBES="${ARGO_VALUES_PROBES:-${REPO_ROOT}/bootstrap/shared/argocd/values-probes.yaml}"

# SOPS/age key (for decrypting SOPS secrets via Argo CD + bootstrap Jobs)
DEFAULT_AGE_KEY_PATH="${HOME}/.config/sops/age/keys.txt"
DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-proxmox-talos}"
DEFAULT_DEPLOYMENT_AGE_KEY_PATH="${HOME}/.config/deploykube/deployments/${DEPLOYKUBE_DEPLOYMENT_ID}/sops/age.key"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-}"

# Helm environment (avoid broken user plugins like helm-secrets)
HELM_NO_USER_PLUGINS="${HELM_NO_USER_PLUGINS:-true}"
HELM_PLUGINS_EMPTY_DIR=""
HELM_SERVER_SIDE="${HELM_SERVER_SIDE:-auto}"
HELM_FORCE_CONFLICTS="${HELM_FORCE_CONFLICTS:-true}"
HELM_UPGRADE_HELP=""

# Forgejo chart (OCI)
FORGEJO_CHART="${FORGEJO_CHART:-oci://code.forgejo.org/forgejo-helm/forgejo}"
FORGEJO_CHART_VERSION="${FORGEJO_CHART_VERSION:-15.0.2}"
FORGEJO_ADMIN_TOKEN=""
FORGEJO_REPO_TLS_SECRET="${FORGEJO_REPO_TLS_SECRET:-forgejo-repo-tls}"
FORGEJO_REPO_TLS_HOST="${FORGEJO_REPO_TLS_HOST:-forgejo-https.${FORGEJO_NAMESPACE}.svc.cluster.local}"

# Forgejo seeding
FORGEJO_SEED_SCRIPT="${SCRIPT_DIR}/forgejo-seed-repo.sh"
FORGEJO_SEED_SENTINEL="${REPO_ROOT}/tmp/bootstrap/forgejo-repo-seeded-proxmox"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}[stage1]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[stage1]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[stage1]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[stage1]${NC} %s\n" "$1"; }

maybe_wire_offline_bundle() {
  if [[ -z "${OFFLINE_BUNDLE_DIR}" ]]; then
    return 0
  fi
  local charts_dir="${OFFLINE_BUNDLE_DIR}/charts"
  if [[ ! -d "${charts_dir}" ]]; then
    log_error "OFFLINE_BUNDLE_DIR set but charts/ missing: ${charts_dir}"
    exit 1
  fi

  # Prefer seeding GitOps from the bundle snapshot when present.
  local bundle_gitops="${OFFLINE_BUNDLE_DIR}/gitops"
  if [[ -d "${bundle_gitops}" ]]; then
    GITOPS_SOURCE="${bundle_gitops}"
  fi

  local forgejo_chart="${charts_dir}/forgejo-${FORGEJO_CHART_VERSION}.tgz"
  if [[ ! -f "${forgejo_chart}" ]]; then
    log_error "Offline mode: Forgejo chart missing from bundle: ${forgejo_chart}"
    exit 1
  fi
  FORGEJO_CHART="${forgejo_chart}"

  local argocd_chart="${charts_dir}/argo-cd-${ARGO_CHART_VERSION}.tgz"
  if [[ ! -f "${argocd_chart}" ]]; then
    log_error "Offline mode: Argo CD chart missing from bundle: ${argocd_chart}"
    exit 1
  fi
  ARGO_CHART="${argocd_chart}"

  log "Offline mode enabled (OFFLINE_BUNDLE_DIR=${OFFLINE_BUNDLE_DIR})"
  log "  - GITOPS_SOURCE=${GITOPS_SOURCE}"
  log "  - FORGEJO_CHART=${FORGEJO_CHART}"
  log "  - ARGO_CHART=${ARGO_CHART}"
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  log_error "need shasum or sha256sum to compute SHA256"
  exit 1
}

deployment_environment_id() {
  # Best-effort; Stage 1 should not require yq.
  if [[ "${DEPLOYKUBE_DEPLOYMENT_ID:-}" == "proxmox-talos" ]]; then
    printf 'prod'
    return
  fi
  if [[ "${DEPLOYKUBE_DEPLOYMENT_ID:-}" == mac-orbstack* ]]; then
    printf 'dev'
    return
  fi
  local cfg="${REPO_ROOT}/platform/gitops/deployments/${DEPLOYKUBE_DEPLOYMENT_ID:-}/config.yaml"
  if command -v yq >/dev/null 2>&1 && [[ -f "${cfg}" ]]; then
    yq -r '.spec.environmentId // ""' "${cfg}" 2>/dev/null || true
    return
  fi
  printf ''
}

check_sops_age_key_custody_gate() {
  local dep_id="${DEPLOYKUBE_DEPLOYMENT_ID:-proxmox-talos}"
  local env_id
  DEPLOYKUBE_DEPLOYMENT_ID="${dep_id}"
  env_id="$(deployment_environment_id)"
  if [[ -z "${env_id}" ]]; then
    log_warn "could not determine deployment environmentId for ${dep_id}; skipping SOPS Age custody gate"
    return 0
  fi
  local sentinel="${REPO_ROOT}/tmp/bootstrap/sops-age-key-acked-${dep_id}"
  local sha
  sha="$(sha256_file "${SOPS_AGE_KEY_FILE}")"

  if [[ ! -f "${sentinel}" ]]; then
    if [[ "${env_id}" == "prod" ]]; then
      log_error "missing SOPS Age custody acknowledgement sentinel: ${sentinel#${REPO_ROOT}/}"
      echo ""
      echo "Run:"
      echo "  ./shared/scripts/sops-age-key-custody-ack.sh \\"
      echo "    --deployment-id '${dep_id}' \\"
      echo "    --age-key-file '${SOPS_AGE_KEY_FILE}' \\"
      echo "    --storage-location '<where you stored it out-of-band>'"
      echo ""
      echo "Then continue by re-running the bootstrap (skip Stage 0; include any env vars you used, e.g. FORGEJO_FORCE_SEED=true):"
      echo "  ./scripts/bootstrap-proxmox-talos.sh --skip-stage0"
      exit 1
    fi
    log_warn "SOPS Age custody acknowledgement sentinel missing for ${dep_id} (env=${env_id}); recommended for prod"
    return 0
  fi

  local sha_expected
  sha_expected="$(grep -E '^age_key_sha256=' "${sentinel}" 2>/dev/null | head -n 1 | sed 's/^age_key_sha256=//')"
  if [[ -z "${sha_expected}" || "${sha_expected}" != "${sha}" ]]; then
    if [[ "${env_id}" == "prod" ]]; then
      log_error "SOPS Age custody acknowledgement SHA mismatch for ${dep_id}"
      log_error "  key file: ${SOPS_AGE_KEY_FILE}"
      log_error "  sha256:   ${sha}"
      log_error "  sentinel: ${sentinel#${REPO_ROOT}/}"
      log_error "Re-run the custody acknowledgement after storing the current key out-of-band:"
      log_error "  ./shared/scripts/sops-age-key-custody-ack.sh --deployment-id ${dep_id} --age-key-file \"${SOPS_AGE_KEY_FILE}\" --storage-location '<...>'"
      log_error "Then continue by re-running the bootstrap:"
      log_error "  ./scripts/bootstrap-proxmox-talos.sh --skip-stage0"
      exit 1
    fi
    log_warn "SOPS Age custody acknowledgement SHA mismatch for ${dep_id} (env=${env_id}); recommended to re-ack"
  fi
}

cleanup_stage1() {
  if [[ -n "${HELM_PLUGINS_EMPTY_DIR}" && -d "${HELM_PLUGINS_EMPTY_DIR}" ]]; then
    rm -rf "${HELM_PLUGINS_EMPTY_DIR}" || true
  fi
}

ensure_sops_age_key_file() {
  local target=""
  if [[ -n "${SOPS_AGE_KEY_FILE}" ]]; then
    target="${SOPS_AGE_KEY_FILE}"
  elif [[ -f "${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}" ]]; then
    target="${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}"
  else
    target="${DEFAULT_AGE_KEY_PATH}"
  fi
  if [[ -f "${target}" ]]; then
    SOPS_AGE_KEY_FILE="${target}"
    export SOPS_AGE_KEY_FILE
    return 0
  fi
  log_error "SOPS Age key missing at ${target}"
  log_error "DSB contract: restore the deployment Age key from out-of-band storage before running Stage 1."
  log_error "Defaults:"
  log_error "  - deployment-scoped: ${DEFAULT_DEPLOYMENT_AGE_KEY_PATH}"
  log_error "  - legacy fallback:   ${DEFAULT_AGE_KEY_PATH}"
  exit 1
}

ensure_argocd_sops_secret() {
  log "Ensuring Argo CD SOPS age key secret exists..."
  ensure_sops_age_key_file
  check_sops_age_key_custody_gate
  kubectl -n "${ARGOCD_NAMESPACE}" create secret generic argocd-sops-age \
    --from-file=age.key="${SOPS_AGE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log_success "SOPS age key secret ready (argocd/argocd-sops-age)"
}

ensure_psa_privileged_for_istio_injection() {
  local ns="$1"

  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    return 0
  fi

  local injection
  injection=$(kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)
  if [[ "${injection}" != "enabled" ]]; then
    return 0
  fi

  local enforce
  enforce=$(kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)
  if [[ "${enforce}" == "privileged" ]]; then
    return 0
  fi

  log_warn "Namespace ${ns} has istio-injection=enabled but is not PSA privileged; labeling to avoid PodSecurity rejections (istio-init requires NET_ADMIN/NET_RAW)"
  kubectl label namespace "${ns}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=privileged \
    pod-security.kubernetes.io/warn-version=latest \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/audit-version=latest \
    --overwrite >/dev/null
}

verify_gitops_overlay_seedable() {
  # The Forgejo seeding helper snapshots the GitOps tree from `git archive` at the current HEAD.
  # If the overlay only exists as untracked/uncommitted files, Argo will later fail with:
  #   "app path does not exist"
  # Make this failure explicit and actionable up-front.
  if ! command -v git >/dev/null 2>&1; then
    log_warn "git not found; skipping GitOps overlay verification"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "python3 not found; skipping GitOps overlay verification"
    return 0
  fi

  local gitops_abs repo_root relpath overlay_rel overlay_worktree
  gitops_abs="$(cd "${GITOPS_SOURCE}" && pwd -P)"
  repo_root="$(git -C "${gitops_abs}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${repo_root}" ]]; then
    log_warn "GitOps source ${GITOPS_SOURCE} is not inside a git repo; skipping overlay verification"
    return 0
  fi
  repo_root="$(cd "${repo_root}" && pwd -P)"
  relpath="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "${repo_root}" "${gitops_abs}")"

  overlay_rel="${relpath%/}/apps/environments/${GITOPS_OVERLAY}"
  overlay_worktree="${gitops_abs}/apps/environments/${GITOPS_OVERLAY}"

  if ! git -C "${repo_root}" ls-tree -d --name-only "HEAD:${overlay_rel}" >/dev/null 2>&1; then
    if [[ -d "${overlay_worktree}" ]]; then
      log_error "GitOps overlay exists in the working tree but is not present at git HEAD: ${overlay_worktree}"
      log_error "Commit it before running Stage 1 so Forgejo seeding includes it (the seed uses git HEAD snapshots)."
    else
      log_error "GitOps overlay directory not found: ${overlay_worktree}"
      log_error "Set GITOPS_OVERLAY to an existing overlay under ${GITOPS_SOURCE}/apps/environments/"
    fi
    exit 1
  fi
}

setup_helm_env() {
  if [[ "${HELM_NO_USER_PLUGINS}" != "true" ]]; then
    return 0
  fi
  HELM_PLUGINS_EMPTY_DIR="$(mktemp -d "/tmp/deploykube-helm-plugins.XXXXXX")"
  chmod 700 "${HELM_PLUGINS_EMPTY_DIR}"
  trap cleanup_stage1 EXIT INT TERM
}

helm_cmd() {
  if [[ "${HELM_NO_USER_PLUGINS}" == "true" ]]; then
    HELM_PLUGINS="${HELM_PLUGINS_EMPTY_DIR}" helm "$@"
  else
    helm "$@"
  fi
}

helm_upgrade_help() {
  if [[ -n "${HELM_UPGRADE_HELP}" ]]; then
    printf '%s' "${HELM_UPGRADE_HELP}"
    return 0
  fi
  HELM_UPGRADE_HELP="$(helm_cmd upgrade --help 2>&1 || true)"
  printf '%s' "${HELM_UPGRADE_HELP}"
}

helm_upgrade_extra_args() {
  local -a args=()
  local help_out
  help_out="$(helm_upgrade_help)"
  if printf '%s' "${help_out}" | grep -q -- '--server-side'; then
    args+=(--server-side "${HELM_SERVER_SIDE}")
  fi
  if [[ "${HELM_FORCE_CONFLICTS}" == "true" ]] && printf '%s' "${help_out}" | grep -q -- '--force-conflicts'; then
    args+=(--force-conflicts)
  fi
  printf '%s\n' "${args[@]}"
}

# =============================================================================
# Parse Configuration
# =============================================================================

parse_config() {
  log "Parsing configuration..."
  
  CLUSTER_NAME=$(yq -r '.cluster.name' "${CONFIG_FILE}")
  CLUSTER_DOMAIN=$(yq -r '.cluster.domain' "${CONFIG_FILE}")
  
  log "Cluster: ${CLUSTER_NAME}, Domain: ${CLUSTER_DOMAIN}"
}

# =============================================================================
# Install Forgejo
# =============================================================================

ensure_forgejo_admin_secret() {
  # Forgejo chart manages the `${FORGEJO_RELEASE}-admin` secret (default: forgejo-admin).
  # We must not create it ourselves. Instead, reuse it if it exists, and otherwise
  # generate credentials that Helm will materialize into that secret.
  local default_username="forgejo-admin"

  local existing_username=""
  local existing_password=""
  existing_username=$(kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)
  existing_password=$(kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

  if [[ -n "${existing_username}" && -n "${existing_password}" ]]; then
    FORGEJO_ADMIN_USERNAME="${existing_username}"
    FORGEJO_ADMIN_PASSWORD="${existing_password}"
  else
    FORGEJO_ADMIN_USERNAME="${FORGEJO_ADMIN_USERNAME:-${default_username}}"
    FORGEJO_ADMIN_PASSWORD="$(openssl rand -base64 24)"
  fi
}

ensure_forgejo_admin_token() {
  # Forgejo may disable password auth for git over HTTP. Use a personal access token for seeding + Argo.
  local token=""
  token=$(kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  if [[ -n "${token}" ]]; then
    FORGEJO_ADMIN_TOKEN="${token}"
    return 0
  fi

  log "Generating Forgejo admin access token for seeding/Argo (best effort)..."
  token=$(kubectl -n "${FORGEJO_NAMESPACE}" exec deploy/forgejo -- forgejo admin user generate-access-token \
    --username "${FORGEJO_ADMIN_USERNAME}" \
    --token-name deploykube-bootstrap \
    --scopes all \
    --raw 2>/dev/null || true)

  if [[ -z "${token}" ]]; then
    log_warn "Could not generate Forgejo access token; will fall back to password auth (may fail on newer Forgejo)"
    return 0
  fi

  kubectl -n "${FORGEJO_NAMESPACE}" create secret generic forgejo-admin-token \
    --from-literal=username="${FORGEJO_ADMIN_USERNAME}" \
    --from-literal=token="${token}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  FORGEJO_ADMIN_TOKEN="${token}"
}

install_forgejo() {
  log "Installing Forgejo in bootstrap mode..."
  
  kubectl create namespace "${FORGEJO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  ensure_psa_privileged_for_istio_injection "${FORGEJO_NAMESPACE}"

  ensure_forgejo_admin_secret
  ensure_forgejo_repo_tls_secret

  # If a pre-existing forgejo-admin secret exists (e.g. from a previous script run),
  # patch Helm ownership metadata so Helm can adopt it rather than failing the install.
  if kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin >/dev/null 2>&1; then
    kubectl -n "${FORGEJO_NAMESPACE}" label secret forgejo-admin \
      app.kubernetes.io/managed-by=Helm \
      --overwrite >/dev/null 2>&1 || true
    kubectl -n "${FORGEJO_NAMESPACE}" annotate secret forgejo-admin \
      meta.helm.sh/release-name=forgejo \
      meta.helm.sh/release-namespace="${FORGEJO_NAMESPACE}" \
      --overwrite >/dev/null 2>&1 || true
  fi
  
  local -a upgrade_args=()
  mapfile -t upgrade_args < <(helm_upgrade_extra_args)

  # Bootstrap mode: SQLite, HTTP, minimal config
  local -a forgejo_version_args=(--version "${FORGEJO_CHART_VERSION}")
  if [[ -f "${FORGEJO_CHART}" ]]; then
    forgejo_version_args=()
  fi
  helm_cmd upgrade --install forgejo "${FORGEJO_CHART}" \
    "${forgejo_version_args[@]}" \
    --namespace "${FORGEJO_NAMESPACE}" \
    --set replicaCount=1 \
    --set "podSecurityContext.seccompProfile.type=RuntimeDefault" \
    --set "containerSecurityContext.allowPrivilegeEscalation=false" \
    --set "containerSecurityContext.capabilities.drop[0]=ALL" \
    --set "containerSecurityContext.runAsNonRoot=true" \
    --set "containerSecurityContext.runAsUser=1000" \
    --set "containerSecurityContext.runAsGroup=1000" \
    --set "resources.requests.cpu=15m" \
    --set "resources.requests.memory=208Mi" \
    --set "resources.limits.memory=312Mi" \
    --set gitea.admin.username="${FORGEJO_ADMIN_USERNAME}" \
    --set gitea.admin.password="${FORGEJO_ADMIN_PASSWORD}" \
    --set gitea.admin.email=admin@example.com \
    --set gitea.config.database.DB_TYPE=sqlite3 \
    --set gitea.config.server.PROTOCOL=http \
    --set gitea.config.server.DOMAIN="forgejo.${CLUSTER_DOMAIN}" \
    --set gitea.config.server.ROOT_URL="http://forgejo.${CLUSTER_DOMAIN}" \
    --set gitea.config.service.DISABLE_REGISTRATION=true \
    --set gitea.config.queue.TYPE=level \
    --set gitea.config.cache.ADAPTER=memory \
    --set gitea.config.session.PROVIDER=memory \
    --set persistence.enabled=true \
    --set persistence.storageClass=shared-rwo \
    --set persistence.size=10Gi \
    --set strategy.type=Recreate \
    "${upgrade_args[@]}" \
    --wait --timeout=600s
  
  log_success "Forgejo installed"

  # Ensure we have the final secret values (Helm-managed).
  FORGEJO_ADMIN_USERNAME=$(kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "${FORGEJO_ADMIN_USERNAME}")
  FORGEJO_ADMIN_PASSWORD=$(kubectl -n "${FORGEJO_NAMESPACE}" get secret forgejo-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "${FORGEJO_ADMIN_PASSWORD}")

  # Forgejo stores credentials in the DB on the PVC. On reruns, the Secret and DB can drift.
  # Force the on-disk admin password to match the Secret so API/git auth works deterministically.
  log "Syncing Forgejo admin password in the database to match Secret (best effort)..."
  kubectl -n "${FORGEJO_NAMESPACE}" rollout status deploy/forgejo --timeout=600s >/dev/null 2>&1 || true
  kubectl -n "${FORGEJO_NAMESPACE}" exec deploy/forgejo -- forgejo admin user change-password \
    --username "${FORGEJO_ADMIN_USERNAME}" \
    --password "${FORGEJO_ADMIN_PASSWORD}" \
    --must-change-password=false >/dev/null 2>&1 || true

  ensure_forgejo_admin_token
}

ensure_forgejo_repo_tls_secret() {
  if kubectl -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_REPO_TLS_SECRET}" >/dev/null 2>&1; then
    return 0
  fi

  log "Creating Forgejo internal TLS secret ${FORGEJO_REPO_TLS_SECRET}..."
  local tmp_dir key_file crt_file openssl_cnf
  tmp_dir="$(mktemp -d)"
  key_file="${tmp_dir}/tls.key"
  crt_file="${tmp_dir}/tls.crt"
  openssl_cnf="${tmp_dir}/openssl.cnf"
  cat >"${openssl_cnf}" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req
[req_distinguished_name]
CN = ${FORGEJO_REPO_TLS_HOST}
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = forgejo-https
DNS.2 = forgejo-https.${FORGEJO_NAMESPACE}
DNS.3 = forgejo-https.${FORGEJO_NAMESPACE}.svc
DNS.4 = forgejo-https.${FORGEJO_NAMESPACE}.svc.cluster.local
DNS.5 = ${FORGEJO_REPO_TLS_HOST}
EOF
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${key_file}" \
    -out "${crt_file}" \
    -config "${openssl_cnf}" >/dev/null 2>&1

  kubectl -n "${FORGEJO_NAMESPACE}" create secret tls "${FORGEJO_REPO_TLS_SECRET}" \
    --cert="${crt_file}" \
    --key="${key_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -rf "${tmp_dir}"
}

ensure_forgejo_repo_tls_proxy() {
  log "Ensuring Forgejo internal TLS proxy endpoint..."
  cat <<EOF | kubectl -n "${FORGEJO_NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: forgejo-tls-proxy-nginx
data:
  nginx.conf: |
    pid /tmp/nginx.pid;
    error_log /dev/stderr info;
    events {}
    http {
      access_log /dev/stdout;
      client_body_temp_path /tmp/nginx-client-body;
      proxy_temp_path /tmp/nginx-proxy-temp;
      fastcgi_temp_path /tmp/nginx-fastcgi-temp;
      uwsgi_temp_path /tmp/nginx-uwsgi-temp;
      scgi_temp_path /tmp/nginx-scgi-temp;
      server {
        listen 8443 ssl;
        ssl_certificate /tls/tls.crt;
        ssl_certificate_key /tls/tls.key;
        client_max_body_size 0;
        location / {
          proxy_pass http://forgejo-http.${FORGEJO_NAMESPACE}.svc.cluster.local:3000;
          proxy_http_version 1.1;
          proxy_set_header Host \$host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: forgejo-tls-proxy
  labels:
    app.kubernetes.io/name: forgejo-tls-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: forgejo-tls-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: forgejo-tls-proxy
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - containerPort: 8443
              name: https
          readinessProbe:
            tcpSocket:
              port: 8443
          livenessProbe:
            tcpSocket:
              port: 8443
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: tls
              mountPath: /tls
              readOnly: true
            - name: tmp
              mountPath: /tmp
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
      volumes:
        - name: nginx-conf
          configMap:
            name: forgejo-tls-proxy-nginx
        - name: tls
          secret:
            secretName: ${FORGEJO_REPO_TLS_SECRET}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: forgejo-https
  labels:
    app.kubernetes.io/name: forgejo-tls-proxy
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: forgejo-tls-proxy
  ports:
    - name: https
      port: 443
      targetPort: https
EOF
  kubectl -n "${FORGEJO_NAMESPACE}" rollout status deployment/forgejo-tls-proxy --timeout=300s
}

ensure_forgejo_repo_tls_endpoint() {
  ensure_forgejo_repo_tls_secret
  ensure_forgejo_repo_tls_proxy
}

# =============================================================================
# Seed GitOps Repository
# =============================================================================

seed_gitops_repo() {
  if [[ -f "${FORGEJO_SEED_SENTINEL}" ]] && [[ "${FORGEJO_FORCE_SEED:-false}" != "true" ]]; then
    log "GitOps repo already seeded (sentinel exists), skipping..."
    return
  fi
  
  log "Seeding GitOps repository to Forgejo..."
  
  if [[ -x "${FORGEJO_SEED_SCRIPT}" ]]; then
    local port
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

    local args=(--gitops-path "${GITOPS_SOURCE}" --sentinel "${FORGEJO_SEED_SENTINEL}" --port "${port}")
    local ctx=""
    ctx=$(kubectl config current-context 2>/dev/null || true)
    if [[ -n "${ctx}" ]]; then
      args+=(--context "${ctx}")
    fi
    if [[ "${FORGEJO_FORCE_SEED:-false}" == "true" ]]; then
      args+=(--force)
    fi

    FORGEJO_RELEASE=forgejo \
    FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE}" \
    FORGEJO_ADMIN_USERNAME="${FORGEJO_ADMIN_USERNAME}" \
    FORGEJO_ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN}" \
    FORGEJO_SEED_SENTINEL="${FORGEJO_SEED_SENTINEL}" \
      "${FORGEJO_SEED_SCRIPT}" "${args[@]}"
    
    mkdir -p "$(dirname "${FORGEJO_SEED_SENTINEL}")"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${FORGEJO_SEED_SENTINEL}"
    log_success "GitOps repository seeded"
  else
    log_warn "Forgejo seed script not found, skipping automatic seeding"
    log_warn "Manually push ${GITOPS_SOURCE} to Forgejo"
  fi
}

# =============================================================================
# Install Argo CD
# =============================================================================

install_argocd() {
  log "Installing Argo CD..."
  
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  ensure_psa_privileged_for_istio_injection "${ARGOCD_NAMESPACE}"

  # Backwards-compat: older iterations installed the chart with release name "argocd",
  # which breaks GitOps patches expecting "argo-cd-argocd-*". Prefer "argo-cd" but
  # optionally migrate the legacy release on reruns.
  local legacy_release="argocd"
  local desired_release="${ARGO_RELEASE}"
  if helm_cmd status "${legacy_release}" -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 \
    && ! helm_cmd status "${desired_release}" -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    if [[ "${ARGO_MIGRATE_LEGACY_RELEASE}" == "true" ]]; then
      log_warn "Detected legacy Argo CD Helm release '${legacy_release}' in ${ARGOCD_NAMESPACE}; uninstalling it so we can install '${desired_release}' (set ARGO_MIGRATE_LEGACY_RELEASE=false to skip)."
      helm_cmd uninstall "${legacy_release}" -n "${ARGOCD_NAMESPACE}" --wait --timeout=600s || true
    else
      log_warn "Detected legacy Argo CD Helm release '${legacy_release}' in ${ARGOCD_NAMESPACE}; reusing it (ARGO_MIGRATE_LEGACY_RELEASE=false)."
      ARGO_RELEASE="${legacy_release}"
      desired_release="${legacy_release}"
    fi
  fi

  # On reruns, Helm can get stuck waiting on a previous hook Job that never completed.
  # Remove it best-effort before attempting the upgrade (release-name dependent).
  kubectl -n "${ARGOCD_NAMESPACE}" delete job "${desired_release}-argocd-redis-secret-init" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete job "${desired_release}-redis-secret-init" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete job argocd-redis-secret-init argo-cd-redis-secret-init --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete pod -l job-name="${desired_release}-argocd-redis-secret-init" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete pod -l job-name="${desired_release}-redis-secret-init" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete pod -l job-name=argocd-redis-secret-init --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete pod -l job-name=argo-cd-redis-secret-init --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete serviceaccount argocd-redis-secret-init argo-cd-redis-secret-init --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete role argocd-redis-secret-init argo-cd-redis-secret-init --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" delete rolebinding argocd-redis-secret-init argo-cd-redis-secret-init --ignore-not-found >/dev/null 2>&1 || true
  
  if [[ -z "${OFFLINE_BUNDLE_DIR}" ]]; then
    helm_cmd repo add argo https://argoproj.github.io/argo-helm || true
    helm_cmd repo update
  else
    log "Offline mode: skipping 'helm repo add/update' for Argo CD (using local chart: ${ARGO_CHART})"
  fi
  
  # If a previous run left Argo CD CRDs behind with Helm ownership annotations pointing at the
  # old release name, Helm will refuse to install. Fix up ownership metadata so the new
  # release can adopt them safely.
  if ! helm_cmd status "${ARGO_RELEASE}" -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    local crd
    for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do
      if ! kubectl get crd "${crd}" >/dev/null 2>&1; then
        continue
      fi
      local current_owner
      current_owner="$(kubectl get crd "${crd}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
      if [[ -n "${current_owner}" && "${current_owner}" != "${ARGO_RELEASE}" ]]; then
        log_warn "CRD ${crd} is annotated for Helm release '${current_owner}', but '${ARGO_RELEASE}' is being installed; updating ownership annotations so Helm can proceed."
        kubectl annotate crd "${crd}" \
          "meta.helm.sh/release-name=${ARGO_RELEASE}" \
          "meta.helm.sh/release-namespace=${ARGOCD_NAMESPACE}" \
          --overwrite >/dev/null
        kubectl label crd "${crd}" "app.kubernetes.io/managed-by=Helm" --overwrite >/dev/null || true
      fi
    done
  fi

  # Bootstrap mode: HTTP, local admin auth
  # NOTE: Argo CD must be configured to run `kustomize build --enable-helm` so it can
  # render our HelmChartInflationGenerator-based components (e.g. cert-manager).
  local argocd_url="https://argocd.${CLUSTER_DOMAIN}"
  local existing_url=""
  existing_url=$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.url}' 2>/dev/null || true)
  if [[ -n "${existing_url}" ]]; then
    argocd_url="${existing_url}"
  fi

  local -a upgrade_args=()
  mapfile -t upgrade_args < <(helm_upgrade_extra_args)

  # Production hardening defaults (can be overridden at runtime).
  local enable_redis_ha="${ARGOCD_ENABLE_REDIS_HA:-true}"
  local server_replicas="${ARGOCD_SERVER_REPLICAS:-2}"
  local repo_replicas="${ARGOCD_REPOSERVER_REPLICAS:-2}"
  local appset_replicas="${ARGOCD_APPSET_REPLICAS:-2}"
  local controller_replicas="${ARGOCD_CONTROLLER_REPLICAS:-1}"

  local enable_pdbs="${ARGOCD_ENABLE_PDBS:-true}"
  local enable_topology_spread="${ARGOCD_ENABLE_TOPOLOGY_SPREAD:-true}"
  local pod_anti_affinity="${ARGOCD_POD_ANTI_AFFINITY:-hard}"
  local force_istio_injection="${ARGOCD_FORCE_ISTIO_INJECTION:-true}"

  local -a hardening_args=()

  hardening_args+=(
    --set "server.replicas=${server_replicas}"
    --set "repoServer.replicas=${repo_replicas}"
    --set "applicationSet.replicas=${appset_replicas}"
    --set "controller.replicas=${controller_replicas}"
  )

  if [[ "${enable_pdbs}" == "true" ]]; then
    if [[ "${server_replicas}" -gt 1 ]]; then
      hardening_args+=(--set server.pdb.enabled=true --set server.pdb.maxUnavailable=1)
    fi
    if [[ "${repo_replicas}" -gt 1 ]]; then
      hardening_args+=(--set repoServer.pdb.enabled=true --set repoServer.pdb.maxUnavailable=1)
    fi
  fi

  if [[ "${enable_topology_spread}" == "true" ]]; then
    hardening_args+=(
      --set "global.affinity.podAntiAffinity=${pod_anti_affinity}"
      --set "global.topologySpreadConstraints[0].maxSkew=1"
      --set "global.topologySpreadConstraints[0].topologyKey=kubernetes.io/hostname"
      --set "global.topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway"
    )
  fi

  if [[ "${force_istio_injection}" == "true" ]]; then
    hardening_args+=(
      --set-string 'server.podAnnotations.sidecar\.istio\.io/inject=true'
      --set-string 'repoServer.podAnnotations.sidecar\.istio\.io/inject=true'
      --set-string 'applicationSet.podAnnotations.sidecar\.istio\.io/inject=true'
      --set-string 'controller.podAnnotations.sidecar\.istio\.io/inject=true'
    )
  fi

  if [[ "${enable_redis_ha}" == "true" ]]; then
    hardening_args+=(--set redis.enabled=false --set redis-ha.enabled=true)
  fi

  local -a argocd_version_args=(--version "${ARGO_CHART_VERSION}")
  if [[ -f "${ARGO_CHART}" ]]; then
    argocd_version_args=()
  fi

  helm_cmd upgrade --install "${ARGO_RELEASE}" "${ARGO_CHART}" \
    --namespace "${ARGOCD_NAMESPACE}" \
    "${argocd_version_args[@]}" \
    --values "${ARGO_VALUES_RESOURCES}" \
    --values "${ARGO_VALUES_PROBES}" \
    --set "global.image.tag=${ARGO_APP_VERSION}" \
    --set server.insecure=false \
    --set server.service.type=LoadBalancer \
    --set configs.params."server\.insecure"=false \
    --set configs.params."server\.repo\.server\.strict\.tls"=true \
    --set configs.cm."kustomize\.buildOptions"="--enable-helm" \
    --set configs.cm."url"="${argocd_url}" \
    --set configs.cm."admin\.enabled"=false \
    --set configs.cm."exec\.enabled"=true \
    --set-string redisSecretInit.podAnnotations."sidecar\.istio\.io/inject"="false" \
    "${hardening_args[@]}" \
    "${upgrade_args[@]}" \
    --wait --timeout=600s
  
  log_success "Argo CD installed"

  ensure_argocd_sops_secret
  
  # Print local admin password only when the account is enabled.
  ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
  
  if [[ -n "${ARGOCD_PASSWORD}" && "${ARGOCD_PRINT_ADMIN_PASSWORD:-false}" == "true" ]]; then
    log "Argo CD admin password: ${ARGOCD_PASSWORD}"
  elif [[ -n "${ARGOCD_PASSWORD}" ]]; then
    log "Argo CD admin password available via: kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  fi
  
  # Get Argo CD external IP
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    local svc="${ARGO_RELEASE}-argocd-server"
    if ! kubectl -n "${ARGOCD_NAMESPACE}" get svc "${svc}" >/dev/null 2>&1; then
      svc="argocd-server"
    fi
    ARGOCD_IP=$(kubectl -n "${ARGOCD_NAMESPACE}" get svc "${svc}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${ARGOCD_IP}" ]]; then
      break
    fi
    sleep 5
    attempts=$((attempts + 1))
  done
  
  if [[ -n "${ARGOCD_IP}" ]]; then
    log_success "Argo CD accessible at https://${ARGOCD_IP}"
  fi
}

# =============================================================================
# Register Forgejo Repository in Argo CD
# =============================================================================

register_repo() {
  log "Registering Forgejo repository in Argo CD..."
  
  # Prefer the GitOps-managed secret names to avoid duplicate repo secrets:
  # - components/platform/argocd/config/externalsecret-repository.yaml creates repo-forgejo-platform via ESO.
  # During bootstrap, Vault/ESO may not be ready yet, so we seed the same secret name directly.
  local forgejo_repo_url="https://${FORGEJO_REPO_TLS_HOST}/platform/cluster-config.git"

  # Delete any stale/duplicate repository secrets pointing at the same URL (best effort).
  local s
  for s in $(kubectl -n "${ARGOCD_NAMESPACE}" get secrets -l argocd.argoproj.io/secret-type=repository -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    [[ -z "${s}" ]] && continue
    local url=""
    url=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret "${s}" -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ "${url}" == "${forgejo_repo_url}" && "${s}" != "repo-forgejo-platform" ]]; then
      log_warn "Deleting duplicate Argo repository secret ${ARGOCD_NAMESPACE}/${s} for ${forgejo_repo_url}"
      kubectl -n "${ARGOCD_NAMESPACE}" delete secret "${s}" --ignore-not-found >/dev/null 2>&1 || true
    fi
  done

  kubectl -n "${ARGOCD_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-forgejo-platform
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${forgejo_repo_url}"
  username: "${FORGEJO_ADMIN_USERNAME}"
  password: "${FORGEJO_ADMIN_TOKEN:-${FORGEJO_ADMIN_PASSWORD}}"
EOF

  # Remove legacy host-wide credential template secret if present.
  kubectl -n "${ARGOCD_NAMESPACE}" delete secret repo-creds-forgejo --ignore-not-found >/dev/null 2>&1 || true
  
  log_success "Repository registered in Argo CD"
}

ensure_argocd_forgejo_tls_trust() {
  log "Configuring Argo CD trust for Forgejo internal TLS endpoint..."
  local cert cert_key repo_server_deploy
  cert="$(kubectl -n "${FORGEJO_NAMESPACE}" get secret "${FORGEJO_REPO_TLS_SECRET}" -o jsonpath='{.data.tls\.crt}' | base64 -d)"
  cert_key="${FORGEJO_REPO_TLS_HOST}"
  cat <<EOF | kubectl -n "${ARGOCD_NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-tls-certs-cm
  labels:
    app.kubernetes.io/part-of: argocd
data:
  ${cert_key}: |
$(printf '%s\n' "${cert}" | sed 's/^/    /')
EOF
  repo_server_deploy="${ARGO_RELEASE}-argocd-repo-server"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deployment "${repo_server_deploy}" >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment "${repo_server_deploy}" --timeout=300s
}

# =============================================================================
# Apply Root Application
# =============================================================================

apply_root_application() {
  log "Applying root Application: ${ROOT_APPLICATION}..."
  
  local forgejo_url="https://${FORGEJO_REPO_TLS_HOST}/platform/cluster-config.git"

  local autosync_yaml=""
  if [[ "${PLATFORM_APPS_AUTOSYNC}" == "true" ]]; then
    autosync_yaml="$(cat <<EOF
    automated:
      prune: true
      selfHeal: true
EOF
)"
  fi
  
  kubectl -n "${ARGOCD_NAMESPACE}" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ROOT_APPLICATION}
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: "${forgejo_url}"
    # Use an explicit branch rather than HEAD: Forgejo repos created earlier may have a different default branch,
    # which makes Argo report "app path does not exist" when it fetches the wrong branch.
    targetRevision: "${GITOPS_REVISION}"
    path: apps/environments/${GITOPS_OVERLAY}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
${autosync_yaml}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
  
  log_success "Root Application applied"
}

ensure_argocd_platform_project() {
  local appproject="${REPO_ROOT}/platform/gitops/apps/base/appproject-platform.yaml"
  if [[ ! -f "${appproject}" ]]; then
    log_error "missing AppProject manifest: ${appproject}"
    exit 1
  fi
  log "Applying Argo CD AppProject/platform..."
  kubectl apply -f "${appproject}"
  log_success "Argo CD AppProject/platform applied"
}

ensure_bootstrap_namespaces_for_root_app() {
  # platform-apps renders tenant-registry ConfigMaps in these namespaces before child
  # Applications may have created them; precreate to avoid root sync failures.
  local ns
  for ns in keycloak vault-system garage rbac-system backup-system; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
}

# =============================================================================
# Wait for Sync
# =============================================================================

wait_for_sync() {
  if [[ "${WAIT_FOR_PLATFORM_APPS}" != "true" ]]; then
    log "Skipping wait for root Application sync (WAIT_FOR_PLATFORM_APPS=${WAIT_FOR_PLATFORM_APPS})"
    return 0
  fi
  log "Waiting for root Application to sync..."
  
  local attempts=0
  local reseed_attempted=false
  while [[ $attempts -lt 60 ]]; do
    if ! kubectl -n "${ARGOCD_NAMESPACE}" get application "${ROOT_APPLICATION}" >/dev/null 2>&1; then
      if [[ $attempts -ge 6 ]]; then
        log_error "Root Application ${ROOT_APPLICATION} not found in namespace ${ARGOCD_NAMESPACE}"
        log_error "Stage 1 cannot proceed; check KUBECONFIG=${KUBECONFIG} and rerun Stage 1"
        exit 1
      fi
      log "Root Application ${ROOT_APPLICATION} not found yet, waiting..."
      sleep 10
      attempts=$((attempts + 1))
      continue
    fi

    local sync_status=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${ROOT_APPLICATION}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    local health_status=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${ROOT_APPLICATION}" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    local cond_type=""
    local cond_msg=""
    cond_type=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${ROOT_APPLICATION}" \
      -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
    cond_msg=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${ROOT_APPLICATION}" \
      -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "")
    
    if [[ "${sync_status}" == "Synced" ]]; then
      log_success "Root Application synced (health: ${health_status})"
      return
    fi
    
    log "Sync status: ${sync_status}, Health: ${health_status}, waiting..."
    if [[ -n "${cond_type}" ]]; then
      log "Condition: ${cond_type}: ${cond_msg}"
    fi

    if [[ "${cond_type}" == "ComparisonError" ]] && [[ "${AUTO_RESEED_ON_COMPARISON_ERROR}" == "true" ]] && [[ "${reseed_attempted}" == "false" ]]; then
      if printf '%s' "${cond_msg}" | grep -qiE 'app path does not exist|failed to generate manifest'; then
        log_warn "ComparisonError detected; attempting a one-time forced reseed of the GitOps repo (clears the common 'sentinel skipped seeding' case)..."
        reseed_attempted=true
        FORGEJO_FORCE_SEED=true seed_gitops_repo
        kubectl -n "${ARGOCD_NAMESPACE}" annotate application "${ROOT_APPLICATION}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
        sleep 10
        attempts=$((attempts + 1))
        continue
      fi
    fi

    # If Argo is in ComparisonError, continuing will not help; fail fast with the message.
    if [[ "${cond_type}" == "ComparisonError" ]] && [[ $attempts -ge 6 ]]; then
      log_error "Argo CD cannot generate manifests for ${ROOT_APPLICATION} (ComparisonError)."
      log_error "Fix the condition above, then rerun Stage 1 with FORGEJO_FORCE_SEED=true (or patch the Application)."
      exit 1
    fi
    sleep 10
    attempts=$((attempts + 1))
  done
  
  log_warn "Timeout waiting for sync - check Argo CD for details"
}

# =============================================================================
# Main
# =============================================================================

main() {
  log "Starting Stage 1: GitOps Bootstrap"
  
  setup_helm_env
  parse_config
  maybe_wire_offline_bundle
  verify_gitops_overlay_seedable

  if [[ "${STAGE1_SKIP_SEED:-false}" != "true" ]]; then
    "${REPO_ROOT}/shared/scripts/preflight-gitops-seed-guardrail.sh" \
      --deployment-id "${DEPLOYKUBE_DEPLOYMENT_ID:-proxmox-talos}" \
      --seed-sentinel "${FORGEJO_SEED_SENTINEL}" \
      --force-seed "${FORGEJO_FORCE_SEED:-false}"
  fi

  if [[ "${STAGE1_SKIP_FORGEJO:-false}" != "true" ]]; then
    install_forgejo
    ensure_forgejo_repo_tls_endpoint
  else
    log_warn "Skipping Forgejo install (STAGE1_SKIP_FORGEJO=true)"
  fi

  if [[ "${STAGE1_SKIP_SEED:-false}" != "true" ]]; then
    seed_gitops_repo
  else
    log_warn "Skipping Forgejo GitOps seeding (STAGE1_SKIP_SEED=true)"
  fi

  if [[ "${STAGE1_SKIP_ARGOCD:-false}" != "true" ]]; then
    install_argocd
    ensure_argocd_forgejo_tls_trust
  else
    log_warn "Skipping Argo CD install/upgrade (STAGE1_SKIP_ARGOCD=true)"
  fi

  if [[ "${STAGE1_SKIP_REPO_REGISTER:-false}" != "true" ]]; then
    register_repo
  else
    log_warn "Skipping Argo CD repo registration (STAGE1_SKIP_REPO_REGISTER=true)"
  fi

  if [[ "${STAGE1_SKIP_ROOT_APP:-false}" != "true" ]]; then
    ensure_argocd_platform_project
    ensure_bootstrap_namespaces_for_root_app
    apply_root_application
    wait_for_sync
  else
    log_warn "Skipping root Application apply/sync wait (STAGE1_SKIP_ROOT_APP=true)"
  fi
  
  log_success "Stage 1 complete!"
  echo ""
  echo "GitOps Infrastructure:"
  echo "  Forgejo: https://forgejo.${CLUSTER_DOMAIN} (port-forward or LoadBalancer)"
  echo "  Argo CD: https://${ARGOCD_IP:-<pending>}"
  echo "  Root App: ${ROOT_APPLICATION}"
  echo ""
}

main "$@"
