#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

STRICT_NAMESPACES=(observability loki tempo mimir grafana)
EXCEPTIONS_FILE="tests/fixtures/resource-contract-exceptions.yaml"
HELM_BIN="${HELM_BIN:-}"
HELM_V3_VERSION="3.19.4"
declare -A HELM_V3_TARBALL_SHA256=(
  ["darwin-amd64"]="d9c9b1fc499c54282c4127c60cdd506da2c6202506b708a2b45fb6dfdb318f43"
  ["darwin-arm64"]="7e82ca63fe80a298cecefad61d0c10bc47963ff3551e94ab6470be6393a6a74b"
  ["linux-amd64"]="759c656fbd9c11e6a47784ecbeac6ad1eb16a9e76d202e51163ab78504848862"
  ["linux-arm64"]="9e1064f5de43745bdedbff2722a1674d0397bc4b4d8d8196d52a2b730909fe62"
)

require_cmd() {
  local cmd="$1"
  if [[ "${cmd}" == */* ]]; then
    if [ ! -x "${cmd}" ]; then
      echo "error: ${cmd} not executable" >&2
      exit 1
    fi
    return 0
  fi
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: ${cmd} not found" >&2
    exit 1
  fi
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

helm_short() {
  local cmd="$1"
  "${cmd}" version --short 2>/dev/null || true
}

helm_is_v3() {
  local cmd="$1"
  helm_short "${cmd}" | rg -q '^v3\.'
}

ensure_helm_v3_downloaded() {
  require_cmd curl
  require_cmd tar

  local os arch key expected url cache_root install_dir helm_path tmpdir tarball actual extracted
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "${os}" in
    darwin|linux) ;;
    *)
      echo "error: unsupported OS for Helm v3 download: ${os}" >&2
      exit 1
      ;;
  esac

  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "error: unsupported arch for Helm v3 download: ${arch}" >&2
      exit 1
      ;;
  esac

  key="${os}-${arch}"
  expected="${HELM_V3_TARBALL_SHA256[${key}]:-}"
  if [ -z "${expected}" ]; then
    echo "error: missing pinned Helm v3 tarball SHA256 for ${key}" >&2
    exit 1
  fi

  cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}/deploykube"
  install_dir="${cache_root}/tools/helm/v${HELM_V3_VERSION}/${key}"
  helm_path="${install_dir}/helm"
  if [ -x "${helm_path}" ] && helm_is_v3 "${helm_path}"; then
    echo "${helm_path}"
    return 0
  fi

  url="https://get.helm.sh/helm-v${HELM_V3_VERSION}-${key}.tar.gz"
  tmpdir="$(mktemp -d)"
  tarball="${tmpdir}/helm.tar.gz"
  extracted="${tmpdir}/extracted"
  mkdir -p "${extracted}"

  echo "info: downloading Helm v${HELM_V3_VERSION} for kustomize --enable-helm (${key})" >&2
  curl -fsSL "${url}" -o "${tarball}"
  actual="$(sha256_file "${tarball}")"
  if [ "${actual}" != "${expected}" ]; then
    echo "error: Helm v3 tarball SHA256 mismatch for ${key}" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi

  tar -xzf "${tarball}" -C "${extracted}"
  if [ ! -x "${extracted}/${key}/helm" ]; then
    echo "error: Helm v3 tarball did not contain expected binary at ${key}/helm" >&2
    exit 1
  fi

  mkdir -p "${install_dir}"
  install -m 0755 "${extracted}/${key}/helm" "${helm_path}"
  if ! helm_is_v3 "${helm_path}"; then
    echo "error: downloaded helm is not Helm v3: $(helm_short "${helm_path}")" >&2
    exit 1
  fi

  rm -rf "${tmpdir}"
  echo "${helm_path}"
}

resolve_helm_bin() {
  if [ -n "${HELM_BIN}" ]; then
    echo "${HELM_BIN}"
    return 0
  fi

  if command -v helm >/dev/null 2>&1 && helm_is_v3 helm; then
    echo "helm"
    return 0
  fi

  if command -v helm3 >/dev/null 2>&1 && helm_is_v3 helm3; then
    echo "helm3"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local prefix
    prefix="$(brew --prefix helm@3 2>/dev/null || true)"
    if [ -n "${prefix}" ] && [ -x "${prefix}/bin/helm" ] && helm_is_v3 "${prefix}/bin/helm"; then
      echo "${prefix}/bin/helm"
      return 0
    fi
  fi

  ensure_helm_v3_downloaded
}

require_cmd jq
require_cmd yq
require_cmd kustomize
require_cmd rg
HELM_BIN="$(resolve_helm_bin)"
require_cmd "${HELM_BIN}"

tmp_helm_dir=""
tmp_render_root=""
cleanup() {
  if [ -n "${tmp_helm_dir}" ] && [ -d "${tmp_helm_dir}" ]; then
    rm -rf "${tmp_helm_dir}"
  fi
  if [ -n "${tmp_render_root}" ] && [ -d "${tmp_render_root}" ]; then
    rm -rf "${tmp_render_root}"
  fi
}
trap cleanup EXIT INT TERM

if [ "${HELM_BIN}" != "helm" ]; then
  tmp_helm_dir="$(mktemp -d)"
  if [[ "${HELM_BIN}" == */* ]]; then
    helm_target="$(cd "$(dirname "${HELM_BIN}")" && pwd)/$(basename "${HELM_BIN}")"
    ln -s "${helm_target}" "${tmp_helm_dir}/helm"
  else
    ln -s "$(command -v "${HELM_BIN}")" "${tmp_helm_dir}/helm"
  fi
  export PATH="${tmp_helm_dir}:${PATH}"
fi

helm_short="$(helm version --short 2>/dev/null || true)"
if ! echo "${helm_short}" | rg -q '^v3\.'; then
  echo "error: helm v3 required for kustomize --enable-helm rendering (found: ${helm_short:-unknown})" >&2
  echo "hint: set HELM_BIN to a Helm v3 binary (macOS/Homebrew: brew install helm@3; export HELM_BIN=\"$(brew --prefix helm@3)/bin/helm\")" >&2
  exit 1
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

tmp_render_root="$(mktemp -d)"
mkdir -p "${tmp_render_root}/platform"
tar -cf - platform/gitops | tar -xf - -C "${tmp_render_root}"

declare -A exempt

if [ -f "${EXCEPTIONS_FILE}" ]; then
  mapfile -t exc_lines < <(
    yq -o=json '.' "${EXCEPTIONS_FILE}" \
      | jq -r --arg now "${now}" '
          . as $root
          | if ($root|type) != "array" then
              "error\tinvalid-root"
            else
              $root[]
              | [
                  (.namespace // ""),
                  (.kind // ""),
                  (.name // ""),
                  ((.containers // []) | join(",")),
                  (.expires // ""),
                  (.ticket // "")
                ] | @tsv
            end
        '
  )

  for line in "${exc_lines[@]}"; do
    if echo "${line}" | rg -q '^error\t'; then
      echo "error: ${EXCEPTIONS_FILE} must be a YAML array" >&2
      exit 1
    fi

    IFS=$'\t' read -r ns kind name containers expires ticket <<<"${line}"
    if [ -z "${ns}" ] || [ -z "${kind}" ] || [ -z "${name}" ] || [ -z "${expires}" ]; then
      echo "error: invalid exception entry (need namespace/kind/name/expires): ${line}" >&2
      exit 1
    fi
    if [[ "${expires}" < "${now}" ]]; then
      echo "error: expired resource-contract exception: ${ns} ${kind}/${name} (expires ${expires}, now ${now})" >&2
      echo "ticket: ${ticket:-missing}" >&2
      exit 1
    fi

    if [ -z "${containers}" ]; then
      exempt["${ns}|${kind}|${name}|*"]=1
      continue
    fi

    IFS=',' read -r -a cs <<<"${containers}"
    for c in "${cs[@]}"; do
      [ -n "${c}" ] || continue
      exempt["${ns}|${kind}|${name}|${c}"]=1
    done
  done
fi

check_ns_label() {
  local rendered_json="$1"
  local ns="$2"
  if ! echo "${rendered_json}" | jq -e --arg ns "${ns}" '
      .[]
      | select(.kind=="Namespace" and .metadata.name==$ns)
      | (.metadata.labels["darksite.cloud/resource-contract"] // "") == "strict"
    ' >/dev/null; then
    echo "FAIL: Namespace/${ns} missing label darksite.cloud/resource-contract=strict in Git" >&2
    return 1
  fi
  return 0
}

render_json() {
  local dir="$1"
  local render_dir="${tmp_render_root}/${dir}"
  if [ ! -d "${render_dir}" ]; then
    echo "FAIL: expected render dir missing: ${render_dir}" >&2
    return 1
  fi
  local rendered
  rendered="$(kustomize build --enable-helm "${render_dir}" 2>&1)" || {
    echo "${rendered}" >&2
    echo "FAIL: render failed for ${dir}" >&2
    return 1
  }
  printf '%s\n' "${rendered}" | yq eval-all -o=json '[.]' -
}

validate_ns_labels() {
  local namespaces_dir="platform/gitops/components/platform/observability/namespaces"
  echo ""
  echo "==> ${namespaces_dir}"

  local rendered_json
  rendered_json="$(render_json "${namespaces_dir}")" || return 1

  local ns_failures=0
  local ns
  for ns in "${STRICT_NAMESPACES[@]}"; do
    if ! check_ns_label "${rendered_json}" "${ns}"; then
      ns_failures=$((ns_failures + 1))
    fi
  done
  if [ "${ns_failures}" -ne 0 ]; then
    return 1
  fi

  echo "namespace label contract PASSED"
  return 0
}

validate_kustomization_dir() {
  local dir="$1"
  echo ""
  echo "==> ${dir}"

  local rendered_json
  rendered_json="$(render_json "${dir}")" || return 1

  local strict_regex
  strict_regex="$(IFS='|'; echo "${STRICT_NAMESPACES[*]}")"

  local failures=0
  mapfile -t violations < <(
    echo "${rendered_json}" | jq -r --arg re "^(${strict_regex})$" '
      def ns: (.metadata.namespace // "default");
      def name: (.metadata.name // "(unknown)");
      def kind: (.kind // "(unknown)");
      def podspec:
        if kind == "Pod" then .spec
        elif kind == "CronJob" then .spec.jobTemplate.spec.template.spec
        elif (kind == "Deployment" or kind == "StatefulSet" or kind == "DaemonSet" or kind == "ReplicaSet" or kind == "Job") then .spec.template.spec
        else null end;
      def tier1_missing(c):
        [
          (if (c.resources.requests.cpu? // null) == null then "requests.cpu" else empty end),
          (if (c.resources.requests.memory? // null) == null then "requests.memory" else empty end),
          (if (c.resources.limits.memory? // null) == null then "limits.memory" else empty end)
        ] | unique | map(select(. != "")) ;

      .[]
      | select(ns | test($re))
      | select(podspec != null)
      | . as $obj
      | (
          (podspec.containers // [])
          | map({ctype:"container", cname:(.name // "(unnamed)"), missing:tier1_missing(.)})
        )
        + (
          (podspec.initContainers // [])
          | map({ctype:"initContainer", cname:(.name // "(unnamed)"), missing:tier1_missing(.)})
        )
      | .[]
      | select(.missing | length > 0)
      | [
          ($obj.metadata.namespace // "default"),
          ($obj.kind),
          ($obj.metadata.name),
          (.ctype),
          (.cname),
          (.missing | join(","))
        ] | @tsv
    '
  )

  for v in "${violations[@]}"; do
    IFS=$'\t' read -r ns kind name ctype cname missing <<<"${v}"
    if [ -n "${exempt["${ns}|${kind}|${name}|${cname}"]+x}" ] || [ -n "${exempt["${ns}|${kind}|${name}|*"]+x}" ]; then
      echo "WARN: exempted ${ns} ${kind}/${name} ${ctype}/${cname} missing ${missing}"
      continue
    fi
    echo "FAIL: ${ns} ${kind}/${name} ${ctype}/${cname} missing ${missing}" >&2
    failures=$((failures + 1))
  done

  if [ "${failures}" -ne 0 ]; then
    echo "resource contract Tier 1 lint FAILED (${failures} issue(s)) for ${dir}" >&2
    return 1
  fi

  echo "resource contract Tier 1 lint PASSED for ${dir}"
  return 0
}

fail=0
validate_ns_labels || fail=1

mapfile -t env_dirs < <(find platform/gitops/apps/environments -mindepth 1 -maxdepth 1 -type d -print | sort)
for env_dir in "${env_dirs[@]}"; do
  echo ""
  echo "==> ${env_dir} (discover apps)"

  env_json="$(render_json "${env_dir}")" || { fail=1; continue; }
  mapfile -t paths < <(
    echo "${env_json}" \
      | jq -r '
          .[]
          | select(.kind=="Application")
          | (.spec.source.path // "")
          | select(length > 0)
        ' \
      | rg '^components/platform/observability/' \
      | sort -u
  )

  for p in "${paths[@]}"; do
    dir="platform/gitops/${p}"
    if ! validate_kustomization_dir "${dir}"; then
      fail=1
    fi
  done
done

if [ "${fail}" -ne 0 ]; then
  exit 1
fi

echo ""
echo "resource contract validation PASSED"
