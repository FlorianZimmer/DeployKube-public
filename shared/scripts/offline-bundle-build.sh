#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

OUT_DIR=""
PROFILE="${PROFILE:-bootstrap}"
PLATFORM="${PLATFORM:-linux/amd64}"
BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-${REPO_ROOT}/bootstrap/proxmox-talos/config.yaml}"
FORCE="${FORCE:-0}"
SKIP_IMAGES="${SKIP_IMAGES:-0}"
SKIP_GITOPS="${SKIP_GITOPS:-0}"
SKIP_TALOS_ISO="${SKIP_TALOS_ISO:-0}"

log() { printf '[offline-bundle-build] %s\n' "$1" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --out <dir> [--profile bootstrap] [--platform linux/amd64]

Builds an "offline bundle" directory containing:
  - bundle.yaml + bom.json (metadata + BOM),
  - charts/ (Stage 0/Stage 1 chart tgz),
  - oci/images/ (OCI image archives for the selected profile),
  - manifests/ (bootstrap-time vendored manifests),
  - talos/ (optional Talos ISO for proxmox/talos).

Options:
  --out <dir>            Output directory (must not exist unless --force)
  --profile <name>       Bundle profile (default: ${PROFILE})
                         - bootstrap: Stage 0/Stage 1 artefacts (charts + bootstrap images)
  --platform <os/arch>   OCI platform (default: ${PLATFORM})
  --bootstrap-config <p> Proxmox/Talos bootstrap config (default: ${BOOTSTRAP_CONFIG#${REPO_ROOT}/})
  --force                Overwrite output directory if it exists
  --skip-images           Do not export OCI images (charts/manifests/gitops still exported)
  --skip-gitops           Do not export platform/gitops snapshot
  --skip-talos-iso        Do not include Talos ISO

Dependencies:
  git, helm, skopeo, jq, python3, curl, tar
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --bootstrap-config) BOOTSTRAP_CONFIG="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --skip-gitops) SKIP_GITOPS=1; shift ;;
    --skip-talos-iso) SKIP_TALOS_ISO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log "unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${OUT_DIR}" ]]; then
  usage; exit 1
fi

ensure_dep() {
  local bin="$1"
  command -v "${bin}" >/dev/null 2>&1 || { log "missing dependency: ${bin}"; exit 1; }
}

ensure_dep git
ensure_dep helm
ensure_dep skopeo
ensure_dep jq
ensure_dep python3
ensure_dep yq
ensure_dep curl
ensure_dep tar

if [[ "${PLATFORM}" != */* ]]; then
  log "invalid --platform '${PLATFORM}' (expected os/arch, e.g. linux/amd64)"
  exit 1
fi
OS="${PLATFORM%/*}"
ARCH="${PLATFORM#*/}"

if [[ -e "${OUT_DIR}" ]]; then
  if [[ "${FORCE}" != "1" ]]; then
    log "output path exists: ${OUT_DIR} (use --force to overwrite)"
    exit 1
  fi
  log "removing existing output dir (FORCE=1): ${OUT_DIR}"
  rm -rf "${OUT_DIR}"
fi

mkdir -p "${OUT_DIR}"

git_sha="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
created_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

mkdir -p \
  "${OUT_DIR}/charts" \
  "${OUT_DIR}/oci/images" \
  "${OUT_DIR}/manifests/gateway-api" \
  "${OUT_DIR}/talos" \
  "${OUT_DIR}/gitops" \
  "${OUT_DIR}/install"

write_bundle_yaml() {
  cat >"${OUT_DIR}/bundle.yaml" <<EOF
apiVersion: darksite.cloud/v1alpha1
kind: OfflineBundle
metadata:
  name: deploykube
spec:
  profile: ${PROFILE}
  gitSha: ${git_sha}
  createdAt: ${created_at}
  platform: ${PLATFORM}
  bootstrapConfig: ${BOOTSTRAP_CONFIG}
  bom: bom.json
EOF
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
  log "need shasum or sha256sum"; exit 1
}

yq_get() {
  local file="$1" expr="$2"
  yq -r "${expr} // \"\"" "${file}" 2>/dev/null || true
}

export_gitops_snapshot() {
  if [[ "${SKIP_GITOPS}" == "1" ]]; then
    log "SKIP_GITOPS=1; not exporting platform/gitops snapshot"
    return 0
  fi
  log "exporting platform/gitops from git HEAD (${git_sha:0:12})"
  git -C "${REPO_ROOT}" archive --format=tar "HEAD:platform/gitops" | tar -x -C "${OUT_DIR}/gitops"
}

export_gateway_api_manifest() {
  local src="${REPO_ROOT}/platform/gitops/components/networking/gateway-api/standard-install.yaml"
  if [[ ! -f "${src}" ]]; then
    log "missing Gateway API manifest: ${src}"
    exit 1
  fi
  cp "${src}" "${OUT_DIR}/manifests/gateway-api/standard-install.yaml"
}

pull_charts_bootstrap() {
  # Chart versions must match Stage 0/Stage 1 defaults.
  local forgejo_ver="15.0.2"
  local argocd_ver="9.1.0"
  local cilium_ver="1.18.5"
  local metallb_ver="0.15.2"
  local nfs_ver="4.0.18"

  log "pulling charts (bootstrap profile) into ${OUT_DIR}/charts"

  HELM_NO_PLUGINS=1 helm pull "oci://code.forgejo.org/forgejo-helm/forgejo" \
    --version "${forgejo_ver}" \
    --destination "${OUT_DIR}/charts" >/dev/null

  HELM_NO_PLUGINS=1 helm pull "argo-cd" \
    --repo "https://argoproj.github.io/argo-helm" \
    --version "${argocd_ver}" \
    --destination "${OUT_DIR}/charts" >/dev/null

  HELM_NO_PLUGINS=1 helm pull "cilium" \
    --repo "https://helm.cilium.io" \
    --version "${cilium_ver}" \
    --destination "${OUT_DIR}/charts" >/dev/null

  HELM_NO_PLUGINS=1 helm pull "metallb" \
    --repo "https://metallb.github.io/metallb" \
    --version "${metallb_ver}" \
    --destination "${OUT_DIR}/charts" >/dev/null

  HELM_NO_PLUGINS=1 helm pull "nfs-subdir-external-provisioner" \
    --repo "https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner" \
    --version "${nfs_ver}" \
    --destination "${OUT_DIR}/charts" >/dev/null
}

ensure_talos_iso() {
  if [[ "${SKIP_TALOS_ISO}" == "1" ]]; then
    log "SKIP_TALOS_ISO=1; not including Talos ISO"
    return 0
  fi
  if [[ ! -f "${BOOTSTRAP_CONFIG}" ]]; then
    log "missing bootstrap config: ${BOOTSTRAP_CONFIG}"
    exit 1
  fi
  local talos_ver
  talos_ver="$(yq_get "${BOOTSTRAP_CONFIG}" ".cluster.talos_version")"
  if [[ -z "${talos_ver}" ]]; then
    log "could not read cluster.talos_version from ${BOOTSTRAP_CONFIG}"
    exit 1
  fi
  local iso="talos-${talos_ver}-metal-amd64.iso"
  local out="${OUT_DIR}/talos/${iso}"

  # Phase 0: use GitHub releases (bundle build happens in a connected environment).
  local url="https://github.com/siderolabs/talos/releases/download/${talos_ver}/metal-amd64.iso"
  log "downloading Talos ISO: ${url}"
  curl -fsSL -o "${out}" "${url}"
  test -s "${out}"
}

extract_images_from_stdin() {
  python3 -c '
import re, sys
text = sys.stdin.read()
FULL_IMAGE_RE = re.compile(
    r"(?P<img>"
    r"(?:(?:[a-zA-Z0-9-]+\\.)+[a-zA-Z0-9-]+/)?"
    r"[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*/"
    r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*"
    r"(?:(?::[A-Za-z0-9][A-Za-z0-9._-]{0,127})|(?:@sha256:[a-f0-9]{64}))"
    r")"
)
def normalize(img: str) -> str:
    if "/" not in img:
        return f"docker.io/library/{img}"
    if img.count("/") == 1 and "." not in img.split("/", 1)[0]:
        return f"docker.io/{img}"
    return img
def plausible(img: str) -> bool:
    if not img or "//" in img:
        return False
    if img.startswith(("http:", "https:")):
        return False
    first = img.split("/", 1)[0]
    if first.isdigit():
        return False
    return True
images = set()
for m in FULL_IMAGE_RE.finditer(text):
    img = m.group("img").strip().strip("\"\\x27")
    if not plausible(img):
        continue
    images.add(normalize(img))
for img in sorted(images):
    print(img)
' <&0
}

discover_images_bootstrap() {
  # Minimal, explicit bootstrap image set + images rendered from Stage 0/Stage 1 charts.
  local tmp
  tmp="$(mktemp)"

  local talos_ver
  talos_ver="$(yq_get "${BOOTSTRAP_CONFIG}" ".cluster.talos_version")"

  {
    echo "registry.example.internal/deploykube/bootstrap-tools:1.4"
    echo "registry.example.internal/deploykube/validation-tools-core:0.1.0"
    echo "registry.example.internal/deploykube/tenant-provisioner:0.2.24"
    echo "registry.example.internal/siderolabs/installer:${talos_ver}"
    # Some charts construct tags dynamically; include the expected resolved tags explicitly for Phase 0 bundles.
    echo "quay.io/metallb/controller:v0.15.2"
    echo "quay.io/metallb/speaker:v0.15.2"
    echo "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2"
  } >>"${tmp}"

  # Forgejo bootstrap (proxmox stage1 uses --set; mac stage1 uses a values file. Render with defaults; images are stable enough for Phase 0.)
  HELM_NO_PLUGINS=1 helm template deploykube-forgejo "${OUT_DIR}/charts/forgejo-15.0.2.tgz" \
    --namespace forgejo --include-crds 2>/dev/null | extract_images_from_stdin >>"${tmp}" || true

  # Argo CD bootstrap (render with a subset of the Stage 1 args that influence image selection).
  HELM_NO_PLUGINS=1 helm template deploykube-argocd "${OUT_DIR}/charts/argo-cd-9.1.0.tgz" \
    --namespace argocd \
    --include-crds \
    --set "global.image.tag=v3.2.0" \
    --set redis.enabled=false \
    --set redis-ha.enabled=true 2>/dev/null | extract_images_from_stdin >>"${tmp}" || true

  # Cilium (ensure Hubble images are included).
  HELM_NO_PLUGINS=1 helm template deploykube-cilium "${OUT_DIR}/charts/cilium-1.18.5.tgz" \
    --namespace kube-system \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true 2>/dev/null | extract_images_from_stdin >>"${tmp}" || true

  # MetalLB (GitOps installs it, but Stage 0 may still install it before Argo exists).
  HELM_NO_PLUGINS=1 helm template deploykube-metallb "${OUT_DIR}/charts/metallb-0.15.2.tgz" \
    --namespace metallb-system \
    --include-crds 2>/dev/null | extract_images_from_stdin >>"${tmp}" || true

  # NFS provisioner.
  HELM_NO_PLUGINS=1 helm template deploykube-nfs "${OUT_DIR}/charts/nfs-subdir-external-provisioner-4.0.18.tgz" \
    --namespace storage-system 2>/dev/null | extract_images_from_stdin >>"${tmp}" || true

  # Filter obvious non-images that can leak through template sources (e.g. unfinished templating fragments).
  # Example: a tag ending with '.' is not a valid OCI tag.
  sort -u "${tmp}" | grep -Ev ':[^[:space:]]*\\.$' || true
  rm -f "${tmp}"
}

export_images() {
  if [[ "${SKIP_IMAGES}" == "1" ]]; then
    log "SKIP_IMAGES=1; not exporting OCI images"
    return 0
  fi

  local images
  case "${PROFILE}" in
    bootstrap) images="$(discover_images_bootstrap)" ;;
    *) log "unknown profile: ${PROFILE}"; exit 1 ;;
  esac

  log "exporting OCI images for ${PLATFORM} (count=$(printf '%s\n' "${images}" | wc -l | tr -d ' '))"

  local images_json charts_json manifests_json talos_json
  images_json='[]'
  charts_json='[]'
  manifests_json='[]'
  talos_json='[]'

  while IFS= read -r chart; do
    [[ -z "${chart}" ]] && continue
    local file="${OUT_DIR}/charts/${chart}"
    [[ -f "${file}" ]] || continue
    local sha
    sha="$(sha256_file "${file}")"
    charts_json="$(jq -c --arg file "charts/${chart}" --arg sha256 "${sha}" '. + [{file:$file, sha256:$sha256}]' <<<"${charts_json}")"
  done < <(ls -1 "${OUT_DIR}/charts" 2>/dev/null || true)

  if [[ -f "${OUT_DIR}/manifests/gateway-api/standard-install.yaml" ]]; then
    sha="$(sha256_file "${OUT_DIR}/manifests/gateway-api/standard-install.yaml")"
    manifests_json="$(jq -c --arg file "manifests/gateway-api/standard-install.yaml" --arg sha256 "${sha}" '. + [{file:$file, sha256:$sha256}]' <<<"${manifests_json}")"
  fi

  if [[ -d "${OUT_DIR}/talos" ]]; then
    while IFS= read -r iso; do
      [[ -z "${iso}" ]] && continue
      sha="$(sha256_file "${OUT_DIR}/talos/${iso}")"
      talos_json="$(jq -c --arg file "talos/${iso}" --arg sha256 "${sha}" '. + [{file:$file, sha256:$sha256}]' <<<"${talos_json}")"
    done < <(ls -1 "${OUT_DIR}/talos" 2>/dev/null || true)
  fi

  local bootstrap_registry_host bootstrap_registry_local_port
  bootstrap_registry_host="$(yq_get "${BOOTSTRAP_CONFIG}" ".registry.host")"
  bootstrap_registry_local_port="$(yq_get "${BOOTSTRAP_CONFIG}" ".registry.local_port")"

  while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    # Normalize and drop common control characters that can leak in from templating outputs.
    local normalized="${img//$'\r'/}"
    if [[ "${normalized}" != *.*/* ]]; then
      normalized="docker.io/${normalized}"
    fi

    local reg="${normalized%%/*}"
    local rest="${normalized#*/}"
    local repo tag digest
    digest=""
    if [[ "${rest}" == *@sha256:* ]]; then
      repo="${rest%@sha256:*}"
      tag="digest"
      digest="${rest#*@}"
    else
      repo="${rest%:*}"
      tag="${rest##*:}"
    fi

    if [[ "${tag}" == *"." ]]; then
      log "  - skipping invalid image ref (tag ends with '.'): ${normalized}"
      continue
    fi

    local out_dir="${OUT_DIR}/oci/images/${reg}/${repo}"
    mkdir -p "${out_dir}"
    local out_file="${out_dir}/${tag}.tar"

    local src_ref="docker://${normalized}"
    local -a src_verify_args=()
    # Phase 0: DeployKube-owned images are often not published to a public registry.
    # Prefer exporting them from the deployment's bootstrap registry when available.
    if [[ "${normalized}" == registry.example.internal/deploykube/bootstrap-tools:* && -n "${bootstrap_registry_host}" && -n "${bootstrap_registry_local_port}" ]]; then
      src_ref="docker://${bootstrap_registry_host}:${bootstrap_registry_local_port}/deploykube/bootstrap-tools:${tag}"
      src_verify_args=(--src-tls-verify=false)
    fi
    if [[ "${normalized}" == registry.example.internal/deploykube/tenant-provisioner:* && -n "${bootstrap_registry_host}" && -n "${bootstrap_registry_local_port}" ]]; then
      src_ref="docker://${bootstrap_registry_host}:${bootstrap_registry_local_port}/deploykube/tenant-provisioner:${tag}"
      src_verify_args=(--src-tls-verify=false)
    fi

    # Export the platform-specific image into an OCI archive tar.
    log "  - ${normalized} -> oci/images/${reg}/${repo}/${tag}.tar"
    skopeo copy \
      --retry-times 3 \
      --override-os "${OS}" \
      --override-arch "${ARCH}" \
      "${src_verify_args[@]}" \
      "${src_ref}" \
      "oci-archive:${out_file}:image" >/dev/null

    local resolved_digest
    if [[ "${#src_verify_args[@]}" -gt 0 ]]; then
      resolved_digest="$(skopeo inspect --tls-verify=false --override-os "${OS}" --override-arch "${ARCH}" --format '{{.Digest}}' "${src_ref}")"
    else
      resolved_digest="$(skopeo inspect --override-os "${OS}" --override-arch "${ARCH}" --format '{{.Digest}}' "${src_ref}")"
    fi
    images_json="$(jq -c \
      --arg source "${normalized}" \
      --arg digest "${resolved_digest}" \
      --arg oci "oci/images/${reg}/${repo}/${tag}.tar" \
      '. + [{source:$source, digest:$digest, ociArchive:$oci}]' <<<"${images_json}")"
  done < <(printf '%s\n' "${images}")

  jq -n \
    --arg profile "${PROFILE}" \
    --arg gitSha "${git_sha}" \
    --arg createdAt "${created_at}" \
    --arg platform "${PLATFORM}" \
    --arg bootstrapConfig "${BOOTSTRAP_CONFIG}" \
    --argjson charts "${charts_json}" \
    --argjson manifests "${manifests_json}" \
    --argjson talos "${talos_json}" \
    --argjson images "${images_json}" \
    '{profile:$profile, gitSha:$gitSha, createdAt:$createdAt, platform:$platform, bootstrapConfig:$bootstrapConfig, charts:$charts, manifests:$manifests, talos:$talos, images:$images}' \
    >"${OUT_DIR}/bom.json"
}

write_bundle_yaml
export_gitops_snapshot
export_gateway_api_manifest
pull_charts_bootstrap
ensure_talos_iso

# Include the loader script into the bundle for offline-only environments.
cp "${REPO_ROOT}/shared/scripts/offline-bundle-load-registry.sh" "${OUT_DIR}/install/offline-bundle-load-registry.sh"
chmod +x "${OUT_DIR}/install/offline-bundle-load-registry.sh"

export_images

log "wrote bundle:"
log "  - ${OUT_DIR}/bundle.yaml"
log "  - ${OUT_DIR}/bom.json"
log "  - ${OUT_DIR}/charts/"
log "  - ${OUT_DIR}/oci/images/"
