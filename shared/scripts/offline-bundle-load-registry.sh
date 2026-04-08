#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUNDLE_DIR=""
BOOTSTRAP_CONFIG=""
FORCE_OVERWRITE="${FORCE_OVERWRITE:-0}"
SKIP_UNKNOWN_REGISTRIES="${SKIP_UNKNOWN_REGISTRIES:-0}"
BEST_EFFORT="${BEST_EFFORT:-0}"
ONLY_REGISTRIES_CSV="${ONLY_REGISTRIES_CSV:-}"

log() { printf '[offline-bundle-load-registry] %s\n' "$1" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --bundle <dir> --bootstrap-config <bootstrap/proxmox-talos/config.yaml>

Loads OCI image archives from an offline bundle into the bootstrap registry layout used by
the Proxmox/Talos Stage 0 contract:
  - "local images" (DeployKube-owned) -> registry.local_port
  - upstream images -> registry.mirrors[<registryHost>] port

Options:
  --bundle <dir>            Bundle directory containing bom.json + oci/images/
  --bootstrap-config <path> Bootstrap config (reads .registry.host, .registry.local_port, .registry.mirrors)
  --force-overwrite         Allow overwriting existing tags (registry-dependent)
  --skip-unknown-registries Skip images whose registry is not present in .registry.mirrors (warn-only)
  --best-effort             Continue on individual push failures (warn-only)
  --only-registries <csv>   Only load images for these registries (comma-separated).
                            Use 'local' to include DeployKube-owned images pushed to registry.local_port.

Dependencies:
  skopeo, python3, jq
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift 2 ;;
    --bootstrap-config) BOOTSTRAP_CONFIG="$2"; shift 2 ;;
    --force-overwrite) FORCE_OVERWRITE=1; shift ;;
    --skip-unknown-registries) SKIP_UNKNOWN_REGISTRIES=1; shift ;;
    --best-effort) BEST_EFFORT=1; shift ;;
    --only-registries) ONLY_REGISTRIES_CSV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log "unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${BUNDLE_DIR}" || -z "${BOOTSTRAP_CONFIG}" ]]; then
  usage
  exit 1
fi

ensure_dep() {
  local bin="$1"
  command -v "${bin}" >/dev/null 2>&1 || { log "missing dependency: ${bin}"; exit 1; }
}
ensure_dep skopeo
ensure_dep jq
ensure_dep yq

if [[ ! -f "${BUNDLE_DIR}/bom.json" ]]; then
  log "missing bundle BOM: ${BUNDLE_DIR}/bom.json"
  exit 1
fi

if [[ ! -f "${BOOTSTRAP_CONFIG}" ]]; then
  log "missing bootstrap config: ${BOOTSTRAP_CONFIG}"
  exit 1
fi

registry_host="$(yq -r '.registry.host // ""' "${BOOTSTRAP_CONFIG}" 2>/dev/null || true)"
registry_local_port="$(yq -r '.registry.local_port // ""' "${BOOTSTRAP_CONFIG}" 2>/dev/null || true)"
mirrors_json="$(yq -o=json '.registry.mirrors // {}' "${BOOTSTRAP_CONFIG}" 2>/dev/null || echo '{}')"

if [[ -z "${registry_host}" || -z "${registry_local_port}" ]]; then
  log "bootstrap config is missing registry.host or registry.local_port"
  exit 1
fi

dest_port_for_registry() {
  local reg="$1"
  jq -r --arg reg "${reg}" '.[$reg] // ""' <<<"${mirrors_json}"
}

is_deploykube_owned() {
  local src="$1"
  case "${src}" in
    registry.example.internal/deploykube/bootstrap-tools:*|registry.example.internal/deploykube/tenant-provisioner:*|registry.example.internal/deploykube/scim-bridge:*)
      return 0 ;;
    *) return 1 ;;
  esac
}

only_registries_allows() {
  local src="$1"
  if [[ -z "${ONLY_REGISTRIES_CSV}" ]]; then
    return 0
  fi
  local reg="${src%%/*}"
  if is_deploykube_owned "${src}"; then
    [[ ",${ONLY_REGISTRIES_CSV}," == *",local,"* ]]
    return $?
  fi
  [[ ",${ONLY_REGISTRIES_CSV}," == *",${reg},"* ]]
}

dest_ref_for_image() {
  local src="$1"
  local reg="${src%%/*}"
  local rest="${src#*/}" # repo:tag or repo@sha

  if is_deploykube_owned "${src}"; then
    local repo_tag="${rest#florianzimmer/deploykube/}"
    printf '%s:%s/deploykube/%s' "${registry_host}" "${registry_local_port}" "${repo_tag}"
    return 0
  fi

  local port
  port="$(dest_port_for_registry "${reg}")"
  if [[ -z "${port}" ]]; then
    if [[ "${SKIP_UNKNOWN_REGISTRIES}" == "1" ]]; then
      printf ''
      return 0
    fi
    log "no mirror port configured for registry '${reg}' (image: ${src})"
    return 1
  fi
  printf '%s:%s/%s' "${registry_host}" "${port}" "${rest}"
}

tmp="$(mktemp)"
jq -r '.images[]? | [.source, .ociArchive] | @tsv' "${BUNDLE_DIR}/bom.json" >"${tmp}"

count="$(wc -l <"${tmp}" | tr -d ' ')"
log "loading ${count} image(s) into bootstrap registry at ${registry_host}"

while IFS=$'\t' read -r src oci_rel; do
  [[ -z "${src}" || -z "${oci_rel}" ]] && continue

  if ! only_registries_allows "${src}"; then
    log "  - skipping ${src} (filtered by --only-registries)"
    continue
  fi

  local_oci="${BUNDLE_DIR}/${oci_rel}"
  if [[ ! -f "${local_oci}" ]]; then
    log "missing OCI archive file: ${local_oci}"
    exit 1
  fi

  dest="$(dest_ref_for_image "${src}")"
  if [[ -z "${dest}" ]]; then
    log "  - skipping ${src} (no mirror port configured; SKIP_UNKNOWN_REGISTRIES=1)"
    continue
  fi
  log "  - ${src} -> ${dest}"

  extra_args=()
  if [[ "${FORCE_OVERWRITE}" == "1" ]]; then
    # skopeo overwrites tags by default on most registries, but keep the flag for clarity in logs.
    :
  fi

  if ! skopeo copy \
    --retry-times 3 \
    --dest-tls-verify=false \
    "oci-archive:${local_oci}:image" \
    "docker://${dest}" >/dev/null; then
    log "WARN: failed to push ${src} -> ${dest}"
    if [[ "${BEST_EFFORT}" != "1" ]]; then
      exit 1
    fi
  fi
done <"${tmp}"

rm -f "${tmp}"

date -u +'%Y-%m-%dT%H:%M:%SZ' > "${BUNDLE_DIR}/.registry-loaded"
log "done (wrote ${BUNDLE_DIR}/.registry-loaded)"
