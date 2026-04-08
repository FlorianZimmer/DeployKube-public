#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
GIT_BIN="${GIT_BIN:-git}"
JQ_BIN="${JQ_BIN:-jq}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_BIN="${CURL_BIN:-curl}"

KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-kind-deploykube-dev}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
FORGEJO_SENTINEL="${FORGEJO_SENTINEL:-forgejo-https-switch-complete}"
FORGEJO_ORG="${FORGEJO_ORG:-platform}"
FORGEJO_REPO="${FORGEJO_REPO:-cluster-config}"
GITOPS_LOCAL_REPO="${GITOPS_LOCAL_REPO:-${REPO_ROOT}/platform/gitops}"
GIT_REMOTE_NAME="${GIT_REMOTE_NAME:-origin}"
FORGEJO_PUBLIC_HOST="${FORGEJO_PUBLIC_HOST:-}"
FORGEJO_CA_CERT="${FORGEJO_CA_CERT:-${REPO_ROOT}/shared/certs/deploykube-root-ca.crt}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
FORGEJO_HTTPS_PROTOCOL="https"
FORGEJO_SKIP_REMOTE_VERIFY="${FORGEJO_SKIP_REMOTE_VERIFY:-false}"
FORGEJO_ADMIN_USERNAME="${FORGEJO_ADMIN_USERNAME:-forgejo-admin}"
FORGEJO_ADMIN_SECRET_NAME="${FORGEJO_ADMIN_SECRET_NAME:-forgejo-admin}"
FORGEJO_ADMIN_PASSWORD="${FORGEJO_ADMIN_PASSWORD:-}"
FORGEJO_HTTPS_READY_TIMEOUT="${FORGEJO_HTTPS_READY_TIMEOUT:-600}"
FORGEJO_HTTPS_READY_POLL="${FORGEJO_HTTPS_READY_POLL:-5}"
FORGEJO_HTTPS_CANARY_PATH="${FORGEJO_HTTPS_CANARY_PATH:-/}"
FORGEJO_REMOTE_VERIFY_RETRIES="${FORGEJO_REMOTE_VERIFY_RETRIES:-60}"
FORGEJO_REMOTE_VERIFY_BACKOFF="${FORGEJO_REMOTE_VERIFY_BACKOFF:-5}"

FORGEJO_PORT_FORWARD_FALLBACK="${FORGEJO_PORT_FORWARD_FALLBACK:-true}"
FORGEJO_PORT_FORWARD_FALLBACK_STANDALONE="${FORGEJO_PORT_FORWARD_FALLBACK_STANDALONE:-true}"
ISTIO_GATEWAY_NAMESPACE="${ISTIO_GATEWAY_NAMESPACE:-istio-system}"
ISTIO_GATEWAY_SERVICE_PRIMARY="${ISTIO_GATEWAY_SERVICE_PRIMARY:-public-gateway-istio}"
ISTIO_GATEWAY_SERVICE_FALLBACK="${ISTIO_GATEWAY_SERVICE_FALLBACK:-istio-ingressgateway}"
GATEWAY_PORT_FORWARD_LOG="${GATEWAY_PORT_FORWARD_LOG:-${REPO_ROOT}/tmp/forgejo-gateway-port-forward.log}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --context <kubectl-context>         Override kubectl context (default: ${KUBECTL_CONTEXT})
  --namespace <namespace>             Forgejo namespace (default: ${FORGEJO_NAMESPACE})
  --sentinel <configmap>              ConfigMap created by the HTTPS switch job (default: ${FORGEJO_SENTINEL})
  --gitops-path <path>                Path to the local GitOps repo (default: ${GITOPS_LOCAL_REPO})
  --remote-name <name>                Git remote to rewrite (default: ${GIT_REMOTE_NAME})
  --org <forgejo-org>                 Forgejo organisation (default: ${FORGEJO_ORG})
  --repo <forgejo-repo>               Forgejo repository (default: ${FORGEJO_REPO})
  --ca-file <path>                    Custom CA bundle for HTTPS probes (default: ${FORGEJO_CA_CERT})
  --host <hostname>                   Skip Kubernetes watch and force a specific host
  --wait-timeout <seconds>            Max seconds to wait for the sentinel ConfigMap (default: ${WAIT_TIMEOUT_SECONDS})
  --poll-interval <seconds>           Seconds between sentinel checks (default: ${POLL_INTERVAL_SECONDS})
  --skip-verify                       Skip git ls-remote validation (useful for dry-runs/tests)
  -h|--help                           Show this message

Notes:
  - If --gitops-path points at a monorepo subdirectory, this script only verifies Forgejo HTTPS readiness and exits without rewriting any git remotes.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      KUBECTL_CONTEXT="$2"
      shift 2
      ;;
    --namespace)
      FORGEJO_NAMESPACE="$2"
      shift 2
      ;;
    --sentinel)
      FORGEJO_SENTINEL="$2"
      shift 2
      ;;
    --gitops-path)
      GITOPS_LOCAL_REPO="$2"
      shift 2
      ;;
    --remote-name)
      GIT_REMOTE_NAME="$2"
      shift 2
      ;;
    --org)
      FORGEJO_ORG="$2"
      shift 2
      ;;
    --repo)
      FORGEJO_REPO="$2"
      shift 2
      ;;
    --ca-file)
      FORGEJO_CA_CERT="$2"
      shift 2
      ;;
    --host)
      FORGEJO_PUBLIC_HOST="$2"
      shift 2
      ;;
    --wait-timeout)
      WAIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --skip-verify)
      FORGEJO_SKIP_REMOTE_VERIFY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

log() {
  printf '[forgejo-remote-switch] %s\n' "$1" >&2
}

gateway_pf_pid=""
gateway_pf_port=""

check_dependency() {
  local bin="$1" label="$2"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    log "missing dependency '${label}'"
    exit 1
  fi
}

ensure_dependencies() {
  check_dependency "${KUBECTL_BIN}" kubectl
  check_dependency "${GIT_BIN}" git
  check_dependency "${JQ_BIN}" jq
  check_dependency "${PYTHON_BIN}" python3
  check_dependency "${CURL_BIN}" curl
  check_dependency nc netcat
}

abspath() {
  local path="$1"
  if [[ -z "${path}" ]]; then
    return
  fi
  if [[ "${path}" == /* ]]; then
    printf '%s' "${path}"
    return
  fi
  local dir
  dir="$(cd "$(dirname "${path}")" && pwd)"
  printf '%s/%s' "${dir}" "$(basename "${path}")"
}

find_free_port() {
  ${PYTHON_BIN} - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

select_gateway_service() {
  local svc=""
  if ${KUBECTL_BIN} --context "${KUBECTL_CONTEXT}" -n "${ISTIO_GATEWAY_NAMESPACE}" \
    get svc "${ISTIO_GATEWAY_SERVICE_PRIMARY}" >/dev/null 2>&1; then
    svc="${ISTIO_GATEWAY_SERVICE_PRIMARY}"
  elif ${KUBECTL_BIN} --context "${KUBECTL_CONTEXT}" -n "${ISTIO_GATEWAY_NAMESPACE}" \
    get svc "${ISTIO_GATEWAY_SERVICE_FALLBACK}" >/dev/null 2>&1; then
    svc="${ISTIO_GATEWAY_SERVICE_FALLBACK}"
  fi
  if [[ -z "${svc}" ]]; then
    log "could not find an Istio gateway Service in ${ISTIO_GATEWAY_NAMESPACE} (tried ${ISTIO_GATEWAY_SERVICE_PRIMARY}, ${ISTIO_GATEWAY_SERVICE_FALLBACK})"
    return 1
  fi
  printf '%s' "${svc}"
}

stop_gateway_port_forward() {
  if [[ -n "${gateway_pf_pid}" ]]; then
    kill "${gateway_pf_pid}" >/dev/null 2>&1 || true
    wait "${gateway_pf_pid}" 2>/dev/null || true
    gateway_pf_pid=""
    gateway_pf_port=""
  fi
}

start_gateway_port_forward() {
  if [[ -n "${gateway_pf_pid}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${GATEWAY_PORT_FORWARD_LOG}")"
  local svc
  svc=$(select_gateway_service) || return 1

  gateway_pf_port="$(find_free_port)"
  log "starting port-forward via svc/${svc} ${ISTIO_GATEWAY_NAMESPACE} (127.0.0.1:${gateway_pf_port} -> 443) to bypass workstation DNS"

  ${KUBECTL_BIN} --context "${KUBECTL_CONTEXT}" -n "${ISTIO_GATEWAY_NAMESPACE}" port-forward \
    "svc/${svc}" "${gateway_pf_port}:443" \
    >"${GATEWAY_PORT_FORWARD_LOG}" 2>&1 &
  gateway_pf_pid=$!

  # Wait briefly for the port-forward to become usable.
  for _ in {1..30}; do
    if ! kill -0 "${gateway_pf_pid}" >/dev/null 2>&1; then
      log "kubectl port-forward exited early; recent output:"
      tail -n 80 "${GATEWAY_PORT_FORWARD_LOG}" >&2 || true
      stop_gateway_port_forward
      return 1
    fi
    if nc -z 127.0.0.1 "${gateway_pf_port}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  log "kubectl port-forward did not become ready; recent output:"
  tail -n 80 "${GATEWAY_PORT_FORWARD_LOG}" >&2 || true
  stop_gateway_port_forward
  return 1
}

ensure_gitops_repo() {
  if [[ ! -d "${GITOPS_LOCAL_REPO}" ]]; then
    log "GitOps repo ${GITOPS_LOCAL_REPO} not found"
    exit 1
  fi
  if ! ${GIT_BIN} -C "${GITOPS_LOCAL_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "${GITOPS_LOCAL_REPO} is not a git repository"
    exit 1
  fi
}

is_standalone_git_repo() {
  local gitops_abs repo_root
  gitops_abs="$(cd "${GITOPS_LOCAL_REPO}" && pwd -P)"
  repo_root="$(${GIT_BIN} -C "${gitops_abs}" rev-parse --show-toplevel)"
  repo_root="$(cd "${repo_root}" && pwd -P)"
  [[ "${repo_root}" == "${gitops_abs}" ]]
}

get_remote_url() {
  ${GIT_BIN} -C "${GITOPS_LOCAL_REPO}" remote get-url "${GIT_REMOTE_NAME}"
}

fetch_sentinel_host() {
  local json
  if ! json=$(${KUBECTL_BIN} --context "${KUBECTL_CONTEXT}" -n "${FORGEJO_NAMESPACE}" \
    get configmap "${FORGEJO_SENTINEL}" -o json 2>/dev/null); then
    return 1
  fi
  local host
  host=$(printf '%s' "${json}" | ${JQ_BIN} -r '.data.host // empty')
  if [[ -z "${host}" ]]; then
    return 1
  fi
  printf '%s' "${host}"
}

wait_for_sentinel_host() {
  if [[ -n "${FORGEJO_PUBLIC_HOST}" ]]; then
    log "host override provided (${FORGEJO_PUBLIC_HOST}); skipping sentinel wait"
    printf '%s' "${FORGEJO_PUBLIC_HOST}"
    return
  fi
  local start
  start=$(date +%s)
  while true; do
    if host=$(fetch_sentinel_host); then
      log "detected HTTPS switch sentinel ${FORGEJO_SENTINEL} with host ${host}"
      printf '%s' "${host}"
      return
    fi
    local now
    now=$(date +%s)
    if (( now - start >= WAIT_TIMEOUT_SECONDS )); then
      log "timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for ConfigMap/${FORGEJO_SENTINEL}"
      exit 1
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done
}

build_remote_url() {
  local host="$1"
  printf '%s://%s/%s/%s.git' "${FORGEJO_HTTPS_PROTOCOL}" "${host}" "${FORGEJO_ORG}" "${FORGEJO_REPO}"
}

probe_https_endpoint() {
  local host="$1"
  local url="${FORGEJO_HTTPS_PROTOCOL}://${host}${FORGEJO_HTTPS_CANARY_PATH}"
  local abs_ca=""
  if [[ -n "${FORGEJO_CA_CERT}" && -f "${FORGEJO_CA_CERT}" ]]; then
    abs_ca=$(abspath "${FORGEJO_CA_CERT}")
  fi

  # First try: direct reachability (requires workstation DNS + routing to the LoadBalancer IP).
  local curl_args=(--silent --show-error --fail --head --max-time 5 "${url}")
  if [[ -n "${abs_ca}" ]]; then
    curl_args=(--silent --show-error --fail --head --max-time 5 --cacert "${abs_ca}" "${url}")
  fi
  if ${CURL_BIN} "${curl_args[@]}" >/dev/null 2>&1; then
    return 0
  fi

  # Fallback: probe through a kubectl port-forward to the gateway (bypasses workstation DNS/routing).
  if [[ "${FORGEJO_PORT_FORWARD_FALLBACK}" != "true" ]]; then
    return 1
  fi

  if ! start_gateway_port_forward; then
    return 1
  fi

  curl_args=(--silent --show-error --fail --head --max-time 5 --connect-to "${host}:443:127.0.0.1:${gateway_pf_port}" "${url}")
  if [[ -n "${abs_ca}" ]]; then
    curl_args=(--silent --show-error --fail --head --max-time 5 --cacert "${abs_ca}" --connect-to "${host}:443:127.0.0.1:${gateway_pf_port}" "${url}")
  fi
  ${CURL_BIN} "${curl_args[@]}" >/dev/null 2>&1
}

wait_for_https_endpoint() {
  local host="$1"
  local start
  start=$(date +%s)
  while true; do
    if probe_https_endpoint "${host}"; then
      log "HTTPS endpoint for ${host} is reachable"
      return
    fi
    local now
    now=$(date +%s)
    if (( now - start >= FORGEJO_HTTPS_READY_TIMEOUT )); then
      log "timed out after ${FORGEJO_HTTPS_READY_TIMEOUT}s waiting for HTTPS endpoint ${host}"
      exit 1
    fi
    sleep "${FORGEJO_HTTPS_READY_POLL}"
  done
}

get_admin_password_from_secret() {
  ${KUBECTL_BIN} --context "${KUBECTL_CONTEXT}" -n "${FORGEJO_NAMESPACE}" \
    get secret "${FORGEJO_ADMIN_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode
}

obtain_admin_password() {
  if [[ -n "${FORGEJO_ADMIN_PASSWORD}" ]]; then
    printf '%s' "${FORGEJO_ADMIN_PASSWORD}"
    return
  fi
  local secret_pw
  secret_pw=$(get_admin_password_from_secret || true)
  if [[ -z "${secret_pw}" ]]; then
    log "failed to read admin password from Secret ${FORGEJO_ADMIN_SECRET_NAME} in namespace ${FORGEJO_NAMESPACE}"
    exit 1
  fi
  printf '%s' "${secret_pw}"
}

configure_git_ssl() {
  if [[ -n "${FORGEJO_CA_CERT}" && -f "${FORGEJO_CA_CERT}" ]]; then
    local abs_ca
    abs_ca=$(abspath "${FORGEJO_CA_CERT}")
    ${GIT_BIN} -C "${GITOPS_LOCAL_REPO}" config http."${FORGEJO_HTTPS_PROTOCOL}://${FORGEJO_PUBLIC_HOST}".sslCAInfo "${abs_ca}"
    log "configured git sslCAInfo for ${FORGEJO_PUBLIC_HOST}"
  fi
}

update_remote_url() {
  local new_url="$1"
  ${GIT_BIN} -C "${GITOPS_LOCAL_REPO}" remote set-url "${GIT_REMOTE_NAME}" "${new_url}"
  log "set ${GIT_REMOTE_NAME} remote to ${new_url}"
}

verify_git_access() {
  local host="$1"
  if [[ "${FORGEJO_SKIP_REMOTE_VERIFY}" == "true" ]]; then
    log "skipping Forgejo git-upload-pack verification (FORGEJO_SKIP_REMOTE_VERIFY=true)"
    return
  fi
  local password
  password=$(obtain_admin_password)
  local abs_ca=""
  if [[ -n "${FORGEJO_CA_CERT}" && -f "${FORGEJO_CA_CERT}" ]]; then
    abs_ca=$(abspath "${FORGEJO_CA_CERT}")
  fi
  local url="${FORGEJO_HTTPS_PROTOCOL}://${host}/${FORGEJO_ORG}/${FORGEJO_REPO}.git/info/refs?service=git-upload-pack"
  local attempt=1
  while true; do
    local curl_args=(--silent --show-error --fail --max-time 10 --user "${FORGEJO_ADMIN_USERNAME}:${password}" "${url}")
    if [[ -n "${abs_ca}" ]]; then
      curl_args=(--silent --show-error --fail --max-time 10 --cacert "${abs_ca}" --user "${FORGEJO_ADMIN_USERNAME}:${password}" "${url}")
    fi
    if ${CURL_BIN} "${curl_args[@]}" >/dev/null 2>&1; then
      log "Forgejo git-upload-pack endpoint responded successfully"
      return
    fi

    if [[ "${FORGEJO_PORT_FORWARD_FALLBACK}" == "true" ]] && start_gateway_port_forward; then
      curl_args=(--silent --show-error --fail --max-time 10 --connect-to "${host}:443:127.0.0.1:${gateway_pf_port}" --user "${FORGEJO_ADMIN_USERNAME}:${password}" "${url}")
      if [[ -n "${abs_ca}" ]]; then
        curl_args=(--silent --show-error --fail --max-time 10 --cacert "${abs_ca}" --connect-to "${host}:443:127.0.0.1:${gateway_pf_port}" --user "${FORGEJO_ADMIN_USERNAME}:${password}" "${url}")
      fi
      if ${CURL_BIN} "${curl_args[@]}" >/dev/null 2>&1; then
        log "Forgejo git-upload-pack endpoint responded successfully (via port-forward)"
        return
      fi
    fi

    if [[ "${attempt}" -ge "${FORGEJO_REMOTE_VERIFY_RETRIES}" ]]; then
      log "Forgejo git-upload-pack endpoint ${url} failed after ${FORGEJO_REMOTE_VERIFY_RETRIES} attempts"
      exit 1
    fi
    log "Forgejo git-upload-pack not ready yet (attempt ${attempt}/${FORGEJO_REMOTE_VERIFY_RETRIES}); retrying in ${FORGEJO_REMOTE_VERIFY_BACKOFF}s"
    attempt=$((attempt + 1))
    sleep "${FORGEJO_REMOTE_VERIFY_BACKOFF}"
  done
}

main() {
  trap stop_gateway_port_forward EXIT
  ensure_dependencies
  ensure_gitops_repo

  if is_standalone_git_repo && [[ "${FORGEJO_PORT_FORWARD_FALLBACK_STANDALONE}" != "true" ]]; then
    FORGEJO_PORT_FORWARD_FALLBACK=false
  fi

  local host
  host=$(wait_for_sentinel_host)
  FORGEJO_PUBLIC_HOST="${host}"
  wait_for_https_endpoint "${host}"
  local new_url
  new_url=$(build_remote_url "${host}")
  verify_git_access "${host}"

  if ! is_standalone_git_repo; then
    log "GitOps path is a monorepo subdirectory; no local git remote to rewrite"
    log "Forgejo HTTPS endpoint verified; seeding continues via forgejo-seed-repo.sh"
    exit 0
  fi

  local current_url
  current_url=$(get_remote_url)
  log "current ${GIT_REMOTE_NAME} remote: ${current_url}"
  if [[ "${current_url}" == "${new_url}" ]]; then
    log "${GIT_REMOTE_NAME} already points at ${new_url}; nothing to do"
    exit 0
  fi

  update_remote_url "${new_url}"
  configure_git_ssl
  log "Forgejo GitOps remote switched to HTTPS"
}

main "$@"
