#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./shared/scripts/smoke-kubernetes-oidc-runtime.sh --from-context <kubectl-context> [--from-kubeconfig <path>] [--deployment-id <id>] [--expected-group <group>] [--grant-type <type>] [--out <path>]

Defaults:
  --deployment-id:  derived from $DEPLOYKUBE_DEPLOYMENT_ID (default: mac-orbstack)
  --expected-group: dk-platform-admins
  --grant-type:     authcode
  --out:            tmp/kubeconfig-oidc-smoke.yaml

Notes:
  - This validates the Kubernetes OIDC runtime path:
    - `kubectl oidc-login` can mint a token
    - the API server authenticates it
    - the expected `groups` claim is visible in `kubectl auth whoami`
    - RBAC evaluation works (via `kubectl auth can-i` checks)
  - It does not mutate RBAC (access-guardrails covers RBAC mutation protection).
  - If you run the smoke from a remote shell (where the browser is *not* on the same machine),
    prefer `--grant-type=device-code` to avoid localhost callback issues.
  - The smoke forces `--token-cache-storage=none --force-refresh` to ensure the login flow is exercised
    (a cached token would defeat the purpose of this validation).
EOF
}

require() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${cmd}" >&2
    exit 1
  fi
}

FROM_CONTEXT=""
FROM_KUBECONFIG=""
DEPLOYMENT_ID="${DEPLOYKUBE_DEPLOYMENT_ID:-}"
EXPECTED_GROUP="dk-platform-admins"
GRANT_TYPE="authcode"
OUT="${REPO_ROOT}/tmp/kubeconfig-oidc-smoke.yaml"

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --from-context)
      FROM_CONTEXT="${2:-}"; shift 2;;
    --from-kubeconfig)
      FROM_KUBECONFIG="${2:-}"; shift 2;;
    --deployment-id)
      DEPLOYMENT_ID="${2:-}"; shift 2;;
    --expected-group)
      EXPECTED_GROUP="${2:-}"; shift 2;;
    --grant-type)
      GRANT_TYPE="${2:-}"; shift 2;;
    --out)
      OUT="${2:-}"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1;;
  esac
done

if [[ -z "${FROM_CONTEXT}" ]]; then
  usage
  exit 1
fi

require kubectl
require jq

if [[ -d "${HOME}/.krew/bin" ]]; then
  export PATH="${HOME}/.krew/bin:${PATH}"
fi

if ! kubectl oidc-login --help >/dev/null 2>&1; then
  echo "error: kubectl exec plugin 'oidc-login' not found" >&2
  echo "hint: install via krew, for example: kubectl krew install oidc-login" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT}")"

if [[ -n "${DEPLOYMENT_ID}" ]]; then
  export DEPLOYKUBE_DEPLOYMENT_ID="${DEPLOYMENT_ID}"
fi

"${REPO_ROOT}/shared/scripts/generate-oidc-kubeconfig.sh" \
  --from-context "${FROM_CONTEXT}" \
  --out "${OUT}" \
  --grant-type "${GRANT_TYPE}" \
  --token-cache-storage none \
  --force-refresh \
  ${FROM_KUBECONFIG:+--from-kubeconfig "${FROM_KUBECONFIG}"}

export KUBECONFIG="${OUT}"

server_url="$(awk '$1=="server:" {print $2; exit}' "${OUT}" || true)"
if [[ "${server_url}" =~ ^https?://(127\\.0\\.0\\.1|localhost): ]]; then
  echo
  echo "[oidc-smoke] warning: kubeconfig API server is ${server_url}"
  echo "[oidc-smoke] if this is a port-forwarded/tunneled apiserver, keep it running; otherwise re-run with:"
  echo "[oidc-smoke]   --from-kubeconfig tmp/kubeconfig-prod"
fi

echo
echo "[oidc-smoke] ensuring no stale oidc-login callback is running"
if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:18000 -sTCP:LISTEN || true
fi
pkill -f 'kubectl-oidc_login get-token' >/dev/null 2>&1 || true

echo
echo "[oidc-smoke] kubectl auth whoami"
if [[ "${GRANT_TYPE}" == "device-code" ]]; then
  echo "[oidc-smoke] note: kubelogin prints a verification URL + user code; complete it in your browser, then this continues."
else
  echo "[oidc-smoke] note: the auth URL is printed by kubectl-oidc_login to stderr; to capture it, run this script as: ... 2>&1 | tee <logfile>"
fi
whoami_json="$(kubectl auth whoami -o json)"
printf '%s\n' "${whoami_json}" | jq -r '.status.userInfo.username'
printf '%s\n' "${whoami_json}" | jq -r '.status.userInfo.groups[]' | sed 's/^/[group] /'

echo
echo "[oidc-smoke] asserting expected group: ${EXPECTED_GROUP}"
printf '%s\n' "${whoami_json}" | jq -e --arg group "${EXPECTED_GROUP}" '.status.userInfo.groups | index($group) != null' >/dev/null

echo
echo "[oidc-smoke] basic API read"
kubectl get ns >/dev/null

echo
echo "[oidc-smoke] RBAC evaluation checks (no mutations)"
kubectl auth can-i list namespaces
kubectl auth can-i get clusterrolebinding/platform-admins-cluster-admin
kubectl auth can-i create validatingwebhookconfigurations.admissionregistration.k8s.io

echo
echo "[oidc-smoke] ok"
