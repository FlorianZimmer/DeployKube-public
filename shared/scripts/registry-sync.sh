#!/usr/bin/env bash
set -euo pipefail

# Pre-seed local registry caches/mirrors with all images referenced in this repo.
# - registry.example.internal is treated as a mirror: we copy images into the local registry on :5002.
# - docker.io/quay.io/registry.k8s.io are warmed by pulling through their proxies.
#
# Usage:
#   shared/scripts/registry-sync.sh          # normal run
#   REGISTRY_SYNC_DRY_RUN=1 ...              # just print actions
#   REGISTRY_SYNC_DISCOVER_ONLY=1 ...        # print discovered image refs only
#
# Optional environment:
#   REGISTRY_SYNC_SCAN_DIRS="platform shared bootstrap scripts"  # override scan roots
#   REGISTRY_SYNC_EXTRA_IMAGES="docker.io/istio/pilot:1.23.3 ..." # add pinned images manually
#   REGISTRY_SYNC_SKIP_IMAGES="docker.io/my/local:* other/pattern:*" # skip warming specific images
#   REGISTRY_SYNC_INCLUDE_VENDORED_CHARTS=1  # also scan vendored Helm charts under */helm/charts/*
#   REGISTRY_SYNC_HELM_RENDER=0  # disable Helm-template discovery (default: enabled)
#   REGISTRY_SYNC_PULL_TIMEOUT_SECONDS=180   # per-image docker pull timeout
#   REGISTRY_SYNC_CACHE_HOST=127.0.0.1       # cache/mirror host
#   REGISTRY_SYNC_PORT_OVERRIDES="registry.example.internal=5012" # override cache ports
#
# Requirements: skopeo, docker, rg, python3, yq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DRY_RUN="${REGISTRY_SYNC_DRY_RUN:-0}"
HELM_RENDER="${REGISTRY_SYNC_HELM_RENDER:-1}"
FAIL_ON_ERROR="${REGISTRY_SYNC_FAIL_ON_ERROR:-0}"
PULL_TIMEOUT_SECONDS="${REGISTRY_SYNC_PULL_TIMEOUT_SECONDS:-180}"
DISCOVER_ONLY="${REGISTRY_SYNC_DISCOVER_ONLY:-0}"
CACHE_HOST="${REGISTRY_SYNC_CACHE_HOST:-127.0.0.1}"
PORT_OVERRIDES="${REGISTRY_SYNC_PORT_OVERRIDES:-}"

declare -A CACHE_PORTS=(
  [docker.io]=5001
  [registry-1.docker.io]=5001
  [registry.example.internal]=5002
  [quay.io]=5003
  [registry.k8s.io]=5004
  [cr.smallstep.com]=5005
  [codeberg.org]=5006
  [code.forgejo.org]=5007
)
declare -A DARKSITE_DISTRIBUTION_SOURCES=()

ensure_dep() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || { echo "missing dependency: $bin" >&2; exit 1; }
}

ensure_dep rg
ensure_dep python3
ensure_dep yq
if [[ "${HELM_RENDER}" != "0" ]]; then
  ensure_dep helm
fi
if [[ "${DISCOVER_ONLY}" != "1" ]]; then
  ensure_dep docker
  ensure_dep skopeo
fi

log() { printf '[registry-sync] %s\n' "$1"; }
warn() { printf '[registry-sync][WARN] %s\n' "$1" >&2; }

apply_port_overrides() {
  local raw entry registry port

  [[ -n "${PORT_OVERRIDES}" ]] || return 0
  IFS=';' read -r -a raw <<<"${PORT_OVERRIDES}"
  for entry in "${raw[@]}"; do
    [[ -n "${entry}" ]] || continue
    if [[ "${entry}" != *=* ]]; then
      warn "ignoring invalid REGISTRY_SYNC_PORT_OVERRIDES entry '${entry}'"
      continue
    fi
    registry="${entry%%=*}"
    port="${entry#*=}"
    if [[ -z "${registry}" || -z "${port}" ]]; then
      warn "ignoring invalid REGISTRY_SYNC_PORT_OVERRIDES entry '${entry}'"
      continue
    fi
    CACHE_PORTS["${registry}"]="${port}"
  done
}

load_darksite_distribution_sources() {
  local runtime_index="${REPO_ROOT}/platform/gitops/artifacts/runtime-artifact-index.yaml"
  local source_ref distribution_ref

  [[ -f "${runtime_index}" ]] || return 0

  while IFS=$'\t' read -r source_ref distribution_ref; do
    [[ -n "${source_ref}" && -n "${distribution_ref}" ]] || continue
    if [[ "${distribution_ref}" == registry.example.internal/* ]]; then
      DARKSITE_DISTRIBUTION_SOURCES["${distribution_ref}"]="${source_ref}"
    fi
  done < <(
    yq -r '.spec.images[]? | [(.source_ref // ""), (.distribution_ref // "")] | @tsv' "${runtime_index}"
  )
}

# Images that are built/loaded locally (Stage 0) should not be “warmed” via remote registries.
# You can extend this list via REGISTRY_SYNC_SKIP_IMAGES (space-separated shell globs).
DEFAULT_SKIP_PATTERNS=(
  "deploykube/bootstrap-tools:*"
  "docker.io/deploykube/bootstrap-tools:*"
  "registry.example.internal/deploykube/bootstrap-tools:*"
  "registry.example.internal/deploykube/scim-bridge:*"
  "deploykube/orb-nfs:*"
  "docker.io/deploykube/orb-nfs:*"
)
read -r -a EXTRA_SKIP_PATTERNS <<<"${REGISTRY_SYNC_SKIP_IMAGES:-}"

should_skip_image() {
  local img="$1"
  local pat
  for pat in "${DEFAULT_SKIP_PATTERNS[@]}" "${EXTRA_SKIP_PATTERNS[@]}"; do
    [[ -z "${pat}" ]] && continue
    if [[ "${img}" == ${pat} ]]; then
      return 0
    fi
  done
  return 1
}

# Discover image references from repo.
#
# This intentionally avoids chart-specific logic and instead extracts:
# - explicit images like: "image: quay.io/org/app:v1.2.3"
# - common Helm-values shapes like:
#     image:
#       repository: quay.io/org/app
#       tag: v1.2.3
#   (and variants including image.registry + repository + tag)
#
# The older hardcoded “always-needed” list was removed to reduce maintenance.
# If something important is not discovered (e.g. chart renders images dynamically),
# provide it via REGISTRY_SYNC_EXTRA_IMAGES or add a concrete image reference in Git.
discover_images() {
  python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ.get("REPO_ROOT", Path.cwd()))

EXTRA = os.environ.get("REGISTRY_SYNC_EXTRA_IMAGES", "").strip()
extra_images = [i.strip() for i in EXTRA.split() if i.strip()]

# Full image ref heuristic: registry? + path + (tag|digest)
# Keep intentionally conservative to avoid false positives.
FULL_IMAGE_RE = re.compile(
    r"(?P<img>"
    r"(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+/)?"
    r"[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*/"
    r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*"
    r"(?:(?::[A-Za-z0-9][A-Za-z0-9._-]{0,127})|(?:@sha256:[a-f0-9]{64}))"
    r")"
)

KEY_VALUE_RE = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$")

def clean_value(v: str) -> str:
    v = v.strip().strip("'\"")
    if v.lower() in ("null", "~"):
        return ""
    if not v or "${" in v or "{{" in v:
        return ""
    # strip inline comment if it looks like YAML
    if " #" in v:
        v = v.split(" #", 1)[0].strip()
    return v

def normalize_registry(img: str) -> str:
    # kind/containerd treats images without a dot-host as docker.io
    if "/" not in img:
        return f"docker.io/library/{img}"
    if img.count("/") == 1 and "." not in img.split("/", 1)[0]:
        # like "nginx:1.2" (no registry host)
        return f"docker.io/{img}"
    return img

def is_plausible_image(img: str) -> bool:
    if not img or "//" in img:
        return False
    if img.startswith(("http:", "https:")):
        return False
    if img.endswith(":null") or img.endswith(":~"):
        return False
    # Reject accidental matches like "5000/foo/bar:tag" (often port/path strings).
    first = img.split("/", 1)[0]
    if first.isdigit():
        return False
    return True

def discover_in_text(text: str) -> set[str]:
    images: set[str] = set()

    # 1) explicit full image refs anywhere
    for m in FULL_IMAGE_RE.finditer(text):
        img = clean_value(m.group("img"))
        if not img:
            continue
        # Avoid false positives like: "secret:namespace/name:key"
        start = m.start("img")
        if text[max(0, start - 7):start] == "secret:":
            continue
        if img and is_plausible_image(img):
            images.add(normalize_registry(img))

    # 2) repository/tag/registry blocks (simple indentation-based scan)
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        m = KEY_VALUE_RE.match(line)
        if not m:
            continue
        key = m.group(1)
        val = clean_value(m.group(2))
        if key not in ("repository", "image.repository", "imageRepository", "image.repositoryName"):
            continue
        if not val or (":" in val) or ("@sha256:" in val):
            # already looks pinned or empty; explicit full refs handled above
            continue

        indent = len(line) - len(line.lstrip(" "))
        tag = ""
        registry = ""

        # Determine the "block" of sibling keys at this indentation (scan both directions).
        block_start = idx
        for j in range(idx - 1, max(-1, idx - 31), -1):
            l2 = lines[j]
            if not l2.strip():
                continue
            indent2 = len(l2) - len(l2.lstrip(" "))
            if indent2 < indent:
                break
            block_start = j

        block_end = idx
        for j in range(idx + 1, min(idx + 31, len(lines))):
            l2 = lines[j]
            if not l2.strip():
                continue
            indent2 = len(l2) - len(l2.lstrip(" "))
            if indent2 < indent:
                break
            block_end = j

        # scan within the block; capture tag/registry at same indent (either order)
        for j in range(block_start, block_end + 1):
            l2 = lines[j]
            if not l2.strip():
                continue
            indent2 = len(l2) - len(l2.lstrip(" "))
            if indent2 != indent:
                continue
            m2 = KEY_VALUE_RE.match(l2)
            if not m2:
                continue
            k2 = m2.group(1)
            v2 = clean_value(m2.group(2))
            if not v2:
                continue
            if k2 in ("tag", "image.tag", "imageTag"):
                tag = v2
            if k2 in ("registry", "image.registry", "imageRegistry", "imageRegistryOverride", "global.imageRegistry", "imageRegistry"):
                registry = v2.rstrip("/")

        if tag:
            if tag.lower() in ("null", "~"):
                continue
            repo = val
            if registry and "." in registry and "/" not in registry:
                # registry host without scheme
                repo = f"{registry}/{repo}"
            img = f"{repo}:{tag}"
            if is_plausible_image(img):
                images.add(normalize_registry(img))

    return images

def iter_candidate_files(root: Path):
    exts = {".yaml", ".yml", ".json", ".tpl", ".gotmpl", ".tf", ".hcl"}
    scan_dirs = os.environ.get("REGISTRY_SYNC_SCAN_DIRS", "").strip()
    if scan_dirs:
        roots = [root / d for d in scan_dirs.split()]
    else:
        # Default: only scan sources of truth (manifests/bootstrap/shared), not docs/tests.
        roots = [root / "platform", root / "shared", root / "bootstrap", root / "scripts"]

    include_vendored = os.environ.get("REGISTRY_SYNC_INCLUDE_VENDORED_CHARTS", "").strip() in ("1", "true", "yes")

    for r in roots:
        if not r.exists():
            continue
        for p in r.rglob("*"):
            if not p.is_file():
                continue
            if p.name.startswith("."):
                continue
            if p.parts and ".git" in p.parts:
                continue
            if p.suffix.lower() not in exts:
                continue
            # Avoid pulling images from vendored Helm charts by default (they often include
            # alternate profiles like OpenShift that don't apply to our kind clusters).
            if not include_vendored:
                parts = [s.lower() for s in p.parts]
                if "helm" in parts and "charts" in parts:
                    continue
            # skip vendored binaries/large artifacts
            try:
                if p.stat().st_size > 2_000_000:
                    continue
            except OSError:
                continue
            yield p

images: set[str] = set()
for path in iter_candidate_files(repo_root):
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    images |= discover_in_text(text)

for img in extra_images:
    if img:
        images.add(normalize_registry(img))

for img in sorted(images):
    print(img)
PY
}

extract_images_from_text() {
  # Reads arbitrary YAML/JSON-ish text from stdin and prints normalized image references (1 per line).
  python3 -c '
import re, sys
text = sys.stdin.read()
FULL_IMAGE_RE = re.compile(
    r"(?P<img>"
    r"(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+/)?"
    r"[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*/"
    r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*"
    r"(?:(?::[A-Za-z0-9][A-Za-z0-9._-]{0,127})|(?:@sha256:[a-f0-9]{64}))"
    r")"
)
def normalize_registry(img: str) -> str:
    if "/" not in img:
        return f"docker.io/library/{img}"
    if img.count("/") == 1 and "." not in img.split("/", 1)[0]:
        return f"docker.io/{img}"
    return img
def is_plausible_image(img: str) -> bool:
    if not img or "//" in img:
        return False
    if img.startswith(("http:", "https:")):
        return False
    if img.endswith(":null") or img.endswith(":~"):
        return False
    first = img.split("/", 1)[0]
    if first.isdigit():
        return False
    return True
images = set()
for m in FULL_IMAGE_RE.finditer(text):
    img = m.group("img").strip().strip("\"\\x27")
    if not img:
        continue
    start = m.start("img")
    if text[max(0, start - 7):start] == "secret:":
        continue
    if not is_plausible_image(img):
        continue
    images.add(normalize_registry(img))
for img in sorted(images):
    print(img)
'
}

discover_images_from_helm_templates() {
  if [[ "${HELM_RENDER}" == "0" ]]; then
    return 0
  fi

  # Render exactly the charts we actually install during bootstrap with the values we apply.
  # This is safer than scanning vendored chart defaults (which may include irrelevant profiles).
  local forgejo_chart="${FORGEJO_CHART:-oci://code.forgejo.org/forgejo-helm/forgejo}"
  local forgejo_version="${FORGEJO_CHART_VERSION:-15.0.2}"
  local forgejo_values="${FORGEJO_VALUES:-${REPO_ROOT}/bootstrap/mac-orbstack/forgejo/values-bootstrap.yaml}"

  local argocd_chart="${ARGO_CHART:-argo/argo-cd}"
  local argocd_version="${ARGO_CHART_VERSION:-9.1.0}"
  local argocd_values="${ARGO_VALUES:-${REPO_ROOT}/bootstrap/mac-orbstack/argocd/values-bootstrap.yaml}"

  # Forgejo (OCI): should work without adding repos.
  if [[ -f "${forgejo_values}" ]]; then
    if ! HELM_NO_PLUGINS=1 helm template deploykube-forgejo "${forgejo_chart}" \
      --version "${forgejo_version}" \
      --namespace forgejo \
      -f "${forgejo_values}" \
      --include-crds 2>/dev/null | extract_images_from_text; then
      warn "helm template Forgejo failed; continuing without it"
    fi
  else
    warn "Forgejo values file missing: ${forgejo_values} (skipping helm discovery)"
  fi

  # Argo CD (Helm repo): best-effort; don't fail the run if repo isn't configured.
  if [[ -f "${argocd_values}" ]]; then
    if ! HELM_NO_PLUGINS=1 helm template deploykube-argocd "${argocd_chart}" \
      --version "${argocd_version}" \
      --namespace argocd \
      -f "${argocd_values}" \
      --include-crds 2>/dev/null | extract_images_from_text; then
      warn "helm template Argo CD failed (repo may be missing); continuing without it"
    fi
  else
    warn "Argo CD values file missing: ${argocd_values} (skipping helm discovery)"
  fi
}

mirror_darksite() {
  local source_img="$1"
  local target_img="${2:-$1}"
  local rest="${target_img#registry.example.internal/}"
  local target="${CACHE_HOST}:${CACHE_PORTS[registry.example.internal]}/${rest}"
  local src="docker://${source_img}"
  local dest="docker://${target}"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "skopeo copy --all --dest-tls-verify=false --format v2s2 ${src} ${dest}"
  else
    log "mirroring ${source_img} -> ${target_img} (all platforms) -> ${target}"
    if ! skopeo copy \
      --retry-times 3 \
      --all \
      --format v2s2 \
      --dest-tls-verify=false \
      "${src}" "${dest}"; then
      warn "failed to mirror ${img} with --all; retrying single-manifest copy"
      if ! skopeo copy \
        --retry-times 3 \
        --format v2s2 \
        --dest-tls-verify=false \
        "${src}" "${dest}"; then
        warn "failed to mirror ${img} into local cache (continuing)"
        return 1
      fi
    fi
  fi
}

warm_proxy() {
  local img="$1" registry="$2" port="$3"
  local path="${img#*/}"  # strip registry
  local target="${CACHE_HOST}:${port}/${path}"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "docker pull ${target}"
  else
    log "warming ${img} via cache ${port}"
    if ! python3 - "${target}" "${PULL_TIMEOUT_SECONDS}" "${REGISTRY_SYNC_PROGRESS:-0}" <<'PY'
import subprocess
import sys

target = sys.argv[1]
timeout = int(sys.argv[2])
show_progress = sys.argv[3] == "1"

kwargs = {}
if not show_progress:
    kwargs["stdout"] = subprocess.DEVNULL
    kwargs["stderr"] = subprocess.DEVNULL

try:
    proc = subprocess.run(["docker", "pull", target], timeout=timeout, **kwargs)
except subprocess.TimeoutExpired:
    sys.exit(124)

sys.exit(proc.returncode)
PY
    then
      local rc=$?
      if [[ "${rc}" == "124" ]]; then
        warn "timed out warming ${img} via cache ${port} after ${PULL_TIMEOUT_SECONDS}s"
      fi
      return 1
    fi
  fi
}

main() {
  apply_port_overrides
  load_darksite_distribution_sources
  if [[ "${DISCOVER_ONLY}" == "1" ]]; then
    { discover_images; discover_images_from_helm_templates; } | sort -u
    return 0
  fi

  local images=("$( { discover_images; discover_images_from_helm_templates; } | sort -u | tr '\n' ' ')")
  if [[ -z "${images[*]}" ]]; then
    log "no images discovered"; exit 0
  fi

  local -a uncached_images=()

  local failures=0
  for img in ${images[*]}; do
    # normalize registry
    if [[ "$img" != *.*/* ]]; then
      img="docker.io/${img}"
    fi
    if [[ "${img}" == *":null" || "${img}" == *":~" ]]; then
      warn "skipping ${img} (invalid tag)"
      continue
    fi
    if should_skip_image "${img}"; then
      log "skipping ${img} (local-build image)"
      continue
    fi
    registry="${img%%/*}"
    port="${CACHE_PORTS[$registry]:-}"
    if [[ -z "$port" ]]; then
      warn "no cache configured for registry '${registry}' (image: ${img})"
      uncached_images+=("${img}")
      continue
    fi
    if [[ "$registry" == "registry.example.internal" ]]; then
      source_img="${DARKSITE_DISTRIBUTION_SOURCES[$img]:-$img}"
      if ! mirror_darksite "${source_img}" "${img}"; then
        failures=$((failures + 1))
      fi
    else
      if ! warm_proxy "$img" "$registry" "$port"; then
        warn "failed to warm ${img} via cache ${port} (continuing)"
        failures=$((failures + 1))
      fi
    fi
  done

  if (( ${#uncached_images[@]} > 0 )); then
    warn "uncached images detected: ${#uncached_images[@]} (add a cache+mirror if you want these warmed)"
    for img in "${uncached_images[@]}"; do
      warn "  - ${img}"
    done
    if [[ "${REGISTRY_SYNC_FAIL_ON_UNCACHED:-0}" == "1" ]]; then
      warn "failing because REGISTRY_SYNC_FAIL_ON_UNCACHED=1"
      exit 2
    fi
  fi
  if (( failures > 0 )); then
    warn "warm completed with ${failures} failures"
    if [[ "${FAIL_ON_ERROR}" == "1" ]]; then
      exit 1
    fi
  fi
  log "done"
}

main "$@"
