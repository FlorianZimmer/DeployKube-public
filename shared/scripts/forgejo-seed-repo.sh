#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FORGEJO_RELEASE="${FORGEJO_RELEASE:-forgejo}"
FORGEJO_NAMESPACE="${FORGEJO_NAMESPACE:-forgejo}"
FORGEJO_ORG="${FORGEJO_ORG:-platform}"
FORGEJO_REPO="${FORGEJO_REPO:-cluster-config}"
FORGEJO_ADMIN_USERNAME="${FORGEJO_ADMIN_USERNAME:-forgejo-admin}"
FORGEJO_ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN:-}"
FORGEJO_PORT_FORWARD_PORT="${FORGEJO_PORT_FORWARD_PORT:-38080}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
GITOPS_LOCAL_REPO="${GITOPS_LOCAL_REPO:-${REPO_ROOT}/platform/gitops}"
FORGEJO_SEED_SENTINEL="${FORGEJO_SEED_SENTINEL:-${REPO_ROOT}/tmp/bootstrap/forgejo-repo-seeded}"
FORGEJO_FORCE_SEED="${FORGEJO_FORCE_SEED:-false}"

PORT_FORWARD_LOG="${PORT_FORWARD_LOG:-${REPO_ROOT}/tmp/forgejo-port-forward.log}"

log() {
  printf '[forgejo-seed] %s\n' "$1" >&2
}

git_no_prompt() {
  # Avoid any interactive credential/UI prompts (Git Credential Manager, macOS GUI, etc.).
  # The remote URL is expected to include credentials or use token auth.
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/usr/bin/false \
  GCM_INTERACTIVE=never \
  git -c credential.helper= -c core.askPass=/usr/bin/false "$@"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force] [--context <kubectl-context>] [--gitops-path <path>] [--sentinel <path>] [--port <local-port>]

Environment variables can also override defaults:
  FORGEJO_RELEASE, FORGEJO_NAMESPACE, FORGEJO_ORG, FORGEJO_REPO,
  FORGEJO_PORT_FORWARD_PORT, KUBECTL_CONTEXT, GITOPS_LOCAL_REPO,
  FORGEJO_SEED_SENTINEL, FORGEJO_FORCE_SEED

Notes:
  - ${GITOPS_LOCAL_REPO} may be either a standalone git repository or a subdirectory inside the main DeployKube repo.
  - The seed always snapshots the current git HEAD (commit), not uncommitted working tree changes.
  - Security: running this script can bypass upstream PR approval controls in a "GitHub -> Forgejo mirror" setup.
    Treat it as a privileged deployment action (prefer CI-only execution after merge, with evidence/audit).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORGEJO_FORCE_SEED=true
      shift
      ;;
    --context)
      KUBECTL_CONTEXT="$2"
      shift 2
      ;;
    --gitops-path)
      GITOPS_LOCAL_REPO="$2"
      shift 2
      ;;
    --sentinel)
      FORGEJO_SEED_SENTINEL="$2"
      shift 2
      ;;
    --port)
      FORGEJO_PORT_FORWARD_PORT="$2"
      shift 2
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

KUBECTL_CONTEXT_ARGS=()
if [[ -n "${KUBECTL_CONTEXT}" ]]; then
  KUBECTL_CONTEXT_ARGS=(--context "${KUBECTL_CONTEXT}")
fi

curl_auth_args() {
  local password="$1"
  # Prefer access token when provided (Forgejo may disable password auth for git/API).
  if [[ -n "${FORGEJO_ADMIN_TOKEN}" ]]; then
    printf '%s\n' "-H" "Authorization: token ${FORGEJO_ADMIN_TOKEN}"
    return 0
  fi
  printf '%s\n' "-u" "${FORGEJO_ADMIN_USERNAME}:${password}"
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    log "missing dependency '${bin}'"
    exit 1
  fi
}

ensure_dependencies() {
  check_dependency kubectl
  check_dependency git
  check_dependency tar
  check_dependency curl
  check_dependency jq
  check_dependency python3
}

ensure_gitops_repo() {
  if [[ ! -d "${GITOPS_LOCAL_REPO}" ]]; then
    log "GitOps repo ${GITOPS_LOCAL_REPO} not found"
    exit 1
  fi
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

export_gitops_tree_to_temp_repo() {
  local temp_repo_dir="$1"

  local gitops_abs repo_root repo_head relpath
  gitops_abs="$(cd "${GITOPS_LOCAL_REPO}" && pwd -P)"

  # Prefer the outer monorepo if the GitOps directory accidentally contains its own .git
  # (nested worktree). Otherwise, seeding can export the wrong HEAD and miss committed changes.
  local repo_root_inner repo_root_outer
  repo_root_inner="$(git -C "${gitops_abs}" rev-parse --show-toplevel 2>/dev/null || true)"
  repo_root_outer="$(git -C "$(dirname "${gitops_abs}")" rev-parse --show-toplevel 2>/dev/null || true)"

  repo_root=""
  if [[ -z "${repo_root_inner}" ]]; then
    log "exporting GitOps directory snapshot (no git worktree detected): ${gitops_abs}"
    mkdir -p "${temp_repo_dir}/worktree"
    tar --exclude='.git' -C "${gitops_abs}" -cf - . | tar -x -C "${temp_repo_dir}/worktree"
    git -C "${temp_repo_dir}/worktree" init -b main >/dev/null 2>&1
    git -C "${temp_repo_dir}/worktree" config user.email "forgejo-seed@local"
    git -C "${temp_repo_dir}/worktree" config user.name "DeployKube Forgejo Seed"
    # The exported tree is a snapshot of what we *want* in Forgejo, even if it contains
    # files ignored by in-repo .gitignore patterns (e.g. vendored Helm charts).
    git -C "${temp_repo_dir}/worktree" add -A -f
    git -C "${temp_repo_dir}/worktree" commit -m "Seed from GitOps directory snapshot (${gitops_abs})" >/dev/null 2>&1
    return 0
  fi
  if [[ -n "${repo_root_outer}" && "${repo_root_outer}" != "${repo_root_inner}" ]]; then
    if [[ -d "${gitops_abs}/.git" ]]; then
      log "warning: detected nested git repository at ${gitops_abs}/.git; prefer keeping platform/gitops as a normal directory in the DeployKube repo"
    fi
    # Only prefer the outer repo if it contains the GitOps directory at HEAD.
    local outer_relpath
    outer_relpath="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "${repo_root_outer}" "${gitops_abs}")"
    if git -C "${repo_root_outer}" cat-file -e "HEAD:${outer_relpath}" >/dev/null 2>&1; then
      repo_root="${repo_root_outer}"
    fi
  fi
  if [[ -z "${repo_root}" ]]; then
    if [[ -z "${repo_root_inner}" ]]; then
      log "GitOps path ${GITOPS_LOCAL_REPO} is not inside a git worktree"
      exit 1
    fi
    repo_root="${repo_root_inner}"
  fi

  repo_root="$(cd "${repo_root}" && pwd -P)"
  repo_head=$(git -C "${repo_root}" rev-parse HEAD)

  mkdir -p "${temp_repo_dir}/worktree"

  if [[ "${repo_root}" == "${gitops_abs}" ]]; then
    log "exporting GitOps repository HEAD (${repo_head:0:12})"
    git -C "${repo_root}" archive --format=tar HEAD | tar -x -C "${temp_repo_dir}/worktree"
  else
    relpath=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "${repo_root}" "${gitops_abs}")
    if ! git -C "${repo_root}" cat-file -e "HEAD:${relpath}" >/dev/null 2>&1; then
      # This happens for offline bundle exports (e.g. tmp/offline-bundle-*/gitops):
      # the directory sits *inside* the monorepo worktree, but is not tracked at git HEAD.
      # In that case, seed from the filesystem snapshot instead of failing.
      log "GitOps path ${relpath} not present at HEAD (${repo_head:0:12}); seeding from filesystem snapshot: ${gitops_abs}"
      tar --exclude='.git' -C "${gitops_abs}" -cf - . | tar -x -C "${temp_repo_dir}/worktree"
      git -C "${temp_repo_dir}/worktree" init -b main >/dev/null 2>&1
      git -C "${temp_repo_dir}/worktree" config user.email "forgejo-seed@local"
      git -C "${temp_repo_dir}/worktree" config user.name "DeployKube Forgejo Seed"
      git -C "${temp_repo_dir}/worktree" add -A -f
      git -C "${temp_repo_dir}/worktree" commit -m "Seed from GitOps directory snapshot (${gitops_abs})" >/dev/null 2>&1
      return 0
    fi
    log "exporting ${relpath} from monorepo HEAD (${repo_head:0:12})"
    git -C "${repo_root}" archive --format=tar "HEAD:${relpath}" | tar -x -C "${temp_repo_dir}/worktree"
  fi

  git -C "${temp_repo_dir}/worktree" init -b main >/dev/null 2>&1
  git -C "${temp_repo_dir}/worktree" config user.email "forgejo-seed@local"
  git -C "${temp_repo_dir}/worktree" config user.name "DeployKube Forgejo Seed"
  # The exported tree is a snapshot of what we *want* in Forgejo, even if it contains
  # files ignored by in-repo .gitignore patterns (e.g. vendored Helm charts).
  git -C "${temp_repo_dir}/worktree" add -A -f
  git -C "${temp_repo_dir}/worktree" commit -m "Seed from DeployKube ${repo_head:0:12}" >/dev/null 2>&1
}

repo_exists() {
  local base_url="$1" username="$2" password="$3"
  local -a auth=()
  mapfile -t auth < <(curl_auth_args "${password}")
  local status
  status=$(curl --silent --show-error --output /dev/null --write-out "%{http_code}" \
    "${auth[@]}" \
    "${base_url}/api/v1/repos/${FORGEJO_ORG}/${FORGEJO_REPO}" || echo "000")
  [[ "${status}" == "200" ]]
}

maybe_skip_remote() {
  local base_url="$1" username="$2" password="$3"
  if [[ "${FORGEJO_FORCE_SEED}" == "true" ]]; then
    return
  fi
  if [[ ! -f "${FORGEJO_SEED_SENTINEL}" ]]; then
    return
  fi
  if repo_exists "${base_url}" "${username}" "${password}"; then
    log "seed sentinel ${FORGEJO_SEED_SENTINEL} present and repo exists – skipping"
    exit 0
  fi
  log "seed sentinel ${FORGEJO_SEED_SENTINEL} found but ${FORGEJO_ORG}/${FORGEJO_REPO} is missing; reseeding"
  rm -f "${FORGEJO_SEED_SENTINEL}"
}

get_admin_password() {
  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${FORGEJO_NAMESPACE}" \
    get secret "${FORGEJO_RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode
}

get_admin_username() {
  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${FORGEJO_NAMESPACE}" \
    get secret "${FORGEJO_RELEASE}-admin" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode
}

maybe_load_admin_token() {
  if [[ -n "${FORGEJO_ADMIN_TOKEN}" ]]; then
    return 0
  fi
  local raw=""
  raw=$(kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${FORGEJO_NAMESPACE}" \
    get secret forgejo-admin-token -o jsonpath='{.data.token}' 2>/dev/null || true)
  if [[ -n "${raw}" ]]; then
    FORGEJO_ADMIN_TOKEN="$(printf '%s' "${raw}" | base64 --decode 2>/dev/null || true)"
  fi
}

maybe_load_admin_username() {
  local u=""
  u=$(get_admin_username 2>/dev/null || true)
  if [[ -n "${u}" ]]; then
    FORGEJO_ADMIN_USERNAME="${u}"
  fi
}

require_admin_password() {
  local pw
  pw=$(get_admin_password || true)
  if [[ -z "${pw}" ]]; then
    log "could not read ${FORGEJO_RELEASE}-admin Secret in namespace ${FORGEJO_NAMESPACE}"
    exit 1
  fi
  printf '%s' "${pw}"
}

start_port_forward() {
  mkdir -p "$(dirname "${PORT_FORWARD_LOG}")"
  # Port-forwarding a Service requires at least one Running pod endpoint.
  # During bootstrap, Forgejo may be mid-rollout (e.g. HTTPS switch Job), so wait briefly.
  local selector="app.kubernetes.io/instance=${FORGEJO_RELEASE},app.kubernetes.io/name=forgejo"
  local attempts=0
  while [[ ${attempts} -lt 60 ]]; do
    if kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${FORGEJO_NAMESPACE}" get pod -l "${selector}" >/dev/null 2>&1; then
      local ready_count
      ready_count=$(
        kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${FORGEJO_NAMESPACE}" get pod -l "${selector}" -o json 2>/dev/null \
          | jq -r '[.items[] | select(.status.phase=="Running") | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length' \
          2>/dev/null || echo 0
      )
      if [[ "${ready_count}" != "0" ]]; then
        break
      fi
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "${FORGEJO_NAMESPACE}" port-forward \
    "svc/${FORGEJO_RELEASE}-http" "${FORGEJO_PORT_FORWARD_PORT}:3000" \
    >"${PORT_FORWARD_LOG}" 2>&1 &
  FORGEJO_PORT_FORWARD_PID=$!

  local base_url="http://127.0.0.1:${FORGEJO_PORT_FORWARD_PORT}"
  # Wait for the port-forward to become usable and surface any kubectl errors.
  for _ in {1..30}; do
    if ! kill -0 "${FORGEJO_PORT_FORWARD_PID}" >/dev/null 2>&1; then
      log "kubectl port-forward exited early; recent output:"
      tail -n 80 "${PORT_FORWARD_LOG}" >&2 || true
      exit 1
    fi
    if curl --silent --show-error --max-time 2 "${base_url}/api/v1/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log "port-forward did not become ready; recent output:"
  tail -n 80 "${PORT_FORWARD_LOG}" >&2 || true
  exit 1
}

stop_port_forward() {
  if [[ -n "${FORGEJO_PORT_FORWARD_PID:-}" ]]; then
    kill "${FORGEJO_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${FORGEJO_PORT_FORWARD_PID}" 2>/dev/null || true
    unset FORGEJO_PORT_FORWARD_PID
  fi
}

ensure_org_exists() {
  local base_url="$1"
  local username="$2"
  local password="$3"
  local -a auth=()
  mapfile -t auth < <(curl_auth_args "${password}")
  local status
  status=$(curl --silent --show-error --output /dev/null --write-out "%{http_code}" \
    "${auth[@]}" \
    "${base_url}/api/v1/orgs/${FORGEJO_ORG}" || echo "000")
  if [[ "${status}" == "404" ]]; then
    local payload
    payload=$(jq -n --arg name "${FORGEJO_ORG}" --arg desc "DeployKube GitOps" '{username: $name, full_name: $name, visibility: "private", description: $desc}')
    curl --fail --silent --show-error \
      "${auth[@]}" \
      -H "Content-Type: application/json" \
      -X POST "${base_url}/api/v1/orgs" \
      -d "${payload}" >/dev/null
    log "created Forgejo organisation ${FORGEJO_ORG}"
  elif [[ "${status}" == "200" ]]; then
    log "organisation ${FORGEJO_ORG} already exists"
  else
    log "unexpected status checking org ${FORGEJO_ORG}: HTTP ${status}"
    exit 1
  fi
}

ensure_repo_exists() {
  local base_url="$1"
  local username="$2"
  local password="$3"
  local -a auth=()
  mapfile -t auth < <(curl_auth_args "${password}")
  local status
  status=$(curl --silent --show-error --output /dev/null --write-out "%{http_code}" \
    "${auth[@]}" \
    "${base_url}/api/v1/repos/${FORGEJO_ORG}/${FORGEJO_REPO}" || echo "000")
  if [[ "${status}" == "404" ]]; then
    local payload
    payload=$(jq -n --arg name "${FORGEJO_REPO}" --arg desc "Platform configuration" '{name: $name, description: $desc, private: false, auto_init: false, default_branch: "main"}')
    curl --fail --silent --show-error \
      "${auth[@]}" \
      -H "Content-Type: application/json" \
      -X POST "${base_url}/api/v1/orgs/${FORGEJO_ORG}/repos" \
      -d "${payload}" >/dev/null
    log "created Forgejo repository ${FORGEJO_REPO}"
  elif [[ "${status}" == "200" ]]; then
    log "repository ${FORGEJO_ORG}/${FORGEJO_REPO} already exists"
  else
    log "unexpected status checking repo ${FORGEJO_ORG}/${FORGEJO_REPO}: HTTP ${status}"
    exit 1
  fi
}

push_gitops_repo() {
  local username="$1"
  local password="$2"
  local secret="${FORGEJO_ADMIN_TOKEN:-${password}}"
  local encoded_password
  encoded_password=$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${secret}")
  local local_url="http://${username}:${encoded_password}@127.0.0.1:${FORGEJO_PORT_FORWARD_PORT}/${FORGEJO_ORG}/${FORGEJO_REPO}.git"

  log "seeding Forgejo repo ${FORGEJO_ORG}/${FORGEJO_REPO} from ${GITOPS_LOCAL_REPO}"
  local tmp_repo
  tmp_repo=$(mktemp -d)
  export_gitops_tree_to_temp_repo "${tmp_repo}"

  local max_attempts="${FORGEJO_GIT_PUSH_MAX_ATTEMPTS:-5}"
  local attempt=1
  local push_log
  push_log=$(mktemp)
  while (( attempt <= max_attempts )); do
    if git_no_prompt -C "${tmp_repo}/worktree" push --force "${local_url}" main:main >"${push_log}" 2>&1; then
      break
    fi
    if (( attempt == max_attempts )); then
      log "git push failed; recent output:"
      tail -n 120 "${push_log}" >&2 || true
      rm -f "${push_log}" || true
      rm -rf "${tmp_repo}" || true
      exit 1
    fi
    log "git push attempt ${attempt}/${max_attempts} failed; retrying after $((attempt * 2))s"
    sleep "$((attempt * 2))"
    attempt=$((attempt + 1))
  done
  rm -f "${push_log}" || true
  log "git push completed"
  rm -rf "${tmp_repo}"
}

write_sentinel() {
  mkdir -p "$(dirname "${FORGEJO_SEED_SENTINEL}")"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${FORGEJO_SEED_SENTINEL}"
  log "recorded seed sentinel at ${FORGEJO_SEED_SENTINEL}"
}

cleanup() {
  stop_port_forward
}

main() {
  trap cleanup EXIT
  ensure_dependencies
  ensure_gitops_repo

  maybe_load_admin_username
  maybe_load_admin_token

  local admin_password
  admin_password=$(require_admin_password)

  start_port_forward
  local base_url="http://127.0.0.1:${FORGEJO_PORT_FORWARD_PORT}"
  maybe_skip_remote "${base_url}" "${FORGEJO_ADMIN_USERNAME}" "${admin_password}"
  ensure_org_exists "${base_url}" "${FORGEJO_ADMIN_USERNAME}" "${admin_password}"
  ensure_repo_exists "${base_url}" "${FORGEJO_ADMIN_USERNAME}" "${admin_password}"
  push_gitops_repo "${FORGEJO_ADMIN_USERNAME}" "${admin_password}"
  write_sentinel
}

main "$@"
