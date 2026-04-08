#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-no-secrets-in-git.sh [--source <dir>]

Runs gitleaks against the provided source directory (default: .) to ensure no
credentials are committed to Git.

This is a static PR gate: it does not require cluster access.
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
    return 0
  fi
  echo "error: need shasum or sha256sum to compute SHA256" >&2
  exit 1
}

source_dir="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --source)
      source_dir="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${source_dir}" || ! -d "${source_dir}" ]]; then
  echo "error: --source must be a directory (got: ${source_dir})" >&2
  exit 2
fi

require curl
require tar

GITLEAKS_VERSION="8.30.0"
declare -A GITLEAKS_TARBALL_SHA256=(
  ["darwin-arm64"]="b251ab2bcd4cd8ba9e56ff37698c033ebf38582b477d21ebd86586d927cf87e7"
  ["darwin-amd64"]="ca221d012d247080c2f6f61f4b7a83bffa2453806b0c195c795bbe9a8c775ed5"
  ["linux-arm64"]="b4cbbb6ddf7d1b2a603088cd03a4e3f7ce48ee7fd449b51f7de6ee2906f5fa2f"
  ["linux-amd64"]="79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e"
)

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${os}" in
  darwin|linux) ;;
  *)
    echo "error: unsupported OS for gitleaks download: ${os}" >&2
    exit 1
    ;;
esac

arch="$(uname -m)"
case "${arch}" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *)
    echo "error: unsupported arch for gitleaks download: ${arch}" >&2
    exit 1
    ;;
esac

key="${os}-${arch}"
expected="${GITLEAKS_TARBALL_SHA256[${key}]:-}"
if [[ -z "${expected}" ]]; then
  echo "error: missing pinned gitleaks tarball SHA256 for ${key}" >&2
  exit 1
fi

goreleaser_arch="${arch}"
if [[ "${arch}" == "amd64" ]]; then
  goreleaser_arch="x64"
fi

tarball_name="gitleaks_${GITLEAKS_VERSION}_${os}_${goreleaser_arch}.tar.gz"
url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball_name}"

cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}/deploykube"
install_dir="${cache_root}/tools/gitleaks/v${GITLEAKS_VERSION}/${key}"
gitleaks_path="${install_dir}/gitleaks"

if [[ ! -x "${gitleaks_path}" ]]; then
  tmpdir="$(mktemp -d)"
  tarball="${tmpdir}/gitleaks.tar.gz"
  extracted="${tmpdir}/extracted"
  mkdir -p "${extracted}"

  echo "info: downloading gitleaks v${GITLEAKS_VERSION} (${key})" >&2
  curl -fsSL "${url}" -o "${tarball}"
  actual="$(sha256_file "${tarball}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "error: gitleaks tarball SHA256 mismatch for ${key}" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi

  tar -xzf "${tarball}" -C "${extracted}"

  found="$(find "${extracted}" -maxdepth 2 -type f -name gitleaks -print -quit)"
  if [[ -z "${found}" || ! -f "${found}" ]]; then
    echo "error: gitleaks tarball did not contain expected 'gitleaks' binary" >&2
    exit 1
  fi

  mkdir -p "${install_dir}"
  install -m 0755 "${found}" "${gitleaks_path}"

  rm -rf "${tmpdir}"
fi

"${gitleaks_path}" detect --source "${source_dir}" --no-git --redact
