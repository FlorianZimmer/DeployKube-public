#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/shared/scripts/forgejo-switch-gitops-remote.sh"

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mock_curl="${tmp_dir}/curl"
cat <<'MOCK' > "${mock_curl}"
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "${mock_curl}"

repo_dir="${tmp_dir}/gitops"
mkdir -p "${repo_dir}"
cd "${repo_dir}"
git init >/dev/null 2>&1
git config user.email "test@local"
git config user.name "test"
git commit --allow-empty -m "init" >/dev/null 2>&1
git remote add origin "https://forgejo-https.forgejo.svc.cluster.local/platform/cluster-config.git"

mock_kubectl="${tmp_dir}/kubectl"
cat <<'MOCK' > "${mock_kubectl}"
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "--context" ]]; then
    shift 2
    break
  fi
done
# Simplistic parser; assume command is: kubectl -n <ns> get configmap <name> -o json
while [[ "$1" == -* ]]; do
  if [[ "$1" == "-n" ]]; then
    shift 2
  else
    shift
  fi
done
if [[ "$1" == "get" && "$2" == "configmap" && "$3" == "forgejo-https-switch-complete" ]]; then
  cat <<'JSON'
{
  "metadata": {"name": "forgejo-https-switch-complete"},
  "data": {"host": "forgejo.dev.internal.example.com"}
}
JSON
  exit 0
fi
>&2 echo "mock kubectl: unsupported args $*"
exit 1
MOCK
chmod +x "${mock_kubectl}"

KUBECTL_BIN="${mock_kubectl}" \
CURL_BIN="${mock_curl}" \
GITOPS_LOCAL_REPO="${repo_dir}" \
FORGEJO_SKIP_REMOTE_VERIFY=true \
${SCRIPT} --context kind-test --gitops-path "${repo_dir}" --sentinel forgejo-https-switch-complete --skip-verify >/dev/null

new_remote=$(git -C "${repo_dir}" remote get-url origin)
expected="https://forgejo.dev.internal.example.com/platform/cluster-config.git"
if [[ "${new_remote}" != "${expected}" ]]; then
  echo "expected remote ${expected}, got ${new_remote}" >&2
  exit 1
fi

mono_dir="${tmp_dir}/mono"
gitops_subdir="${mono_dir}/platform/gitops"
mkdir -p "${gitops_subdir}"
git -C "${mono_dir}" init >/dev/null 2>&1
git -C "${mono_dir}" config user.email "test@local"
git -C "${mono_dir}" config user.name "test"
git -C "${mono_dir}" commit --allow-empty -m "init" >/dev/null 2>&1
git -C "${mono_dir}" remote add origin "git@github.com:example/DeployKube.git"

KUBECTL_BIN="${mock_kubectl}" \
CURL_BIN="${mock_curl}" \
GITOPS_LOCAL_REPO="${gitops_subdir}" \
FORGEJO_SKIP_REMOTE_VERIFY=true \
${SCRIPT} --context kind-test --gitops-path "${gitops_subdir}" --sentinel forgejo-https-switch-complete --skip-verify >/dev/null

root_remote=$(git -C "${mono_dir}" remote get-url origin)
if [[ "${root_remote}" != "git@github.com:example/DeployKube.git" ]]; then
  echo "expected monorepo origin unchanged, got ${root_remote}" >&2
  exit 1
fi
