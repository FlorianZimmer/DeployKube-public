#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require python3
require yq

package_index_file="platform/gitops/artifacts/package-index.yaml"
exemptions_file="tests/fixtures/trivy-repo-owned-image-exemptions.txt"

if [[ ! -f "${package_index_file}" ]]; then
  echo "error: missing ${package_index_file}" >&2
  exit 1
fi

if [[ ! -f "${exemptions_file}" ]]; then
  echo "error: missing ${exemptions_file}" >&2
  exit 1
fi

tmpdir="$(mktemp -d "${root_dir}/tmp/validate-trivy-repo-owned-images.XXXXXX")"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT INT TERM

package_index_refs_file="${tmpdir}/package-index-refs.txt"
exemptions_refs_file="${tmpdir}/exemptions-refs.txt"
discovered_refs_file="${tmpdir}/discovered-refs.tsv"
missing_refs_file="${tmpdir}/missing-refs.tsv"

normalize_ref() {
  local ref="$1"
  ref="${ref%%@sha256:*}"
  if [[ "${ref}" == *:* ]]; then
    local suffix="${ref##*:}"
    if [[ ! "${suffix}" =~ / ]]; then
      ref="${ref%:*}"
    fi
  fi
  printf '%s\n' "${ref}"
}

while IFS= read -r ref; do
  [[ -z "${ref}" || "${ref}" == "null" ]] && continue
  normalize_ref "${ref}"
done < <(yq -r '.spec.images[]?.source' "${package_index_file}") | sort -u > "${package_index_refs_file}"

while IFS= read -r ref; do
  [[ -z "${ref}" || "${ref}" == \#* ]] && continue
  normalize_ref "${ref}"
done < "${exemptions_file}" | sort -u > "${exemptions_refs_file}"

python3 - <<'PY' > "${discovered_refs_file}"
from pathlib import Path
import re

root = Path("platform/gitops")
pattern = re.compile(
    r'^\s*(?:image|repository)\s*:\s*["\']?(registry\.example\.internal/deploykube/[A-Za-z0-9._/-]+(?:[:@][A-Za-z0-9._:-]+)?)["\']?\s*$'
)

for path in sorted(root.rglob("*.y*ml")):
    rel = path.as_posix()
    if rel == "platform/gitops/artifacts/package-index.yaml":
        continue
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        match = pattern.search(line)
        if not match:
            continue
        ref = match.group(1)
        print(f"{rel}\t{lineno}\t{ref}")
PY

if [[ ! -s "${discovered_refs_file}" ]]; then
  echo "error: no repo-owned GitOps image references were discovered; validator pattern likely drifted" >&2
  exit 1
fi

while IFS=$'\t' read -r file line ref; do
  [[ -z "${ref}" ]] && continue
  normalized_ref="$(normalize_ref "${ref}")"
  if rg -n -q -F -- "${normalized_ref}" "${package_index_refs_file}"; then
    continue
  fi
  if rg -n -q -F -- "${normalized_ref}" "${exemptions_refs_file}"; then
    continue
  fi
  printf '%s\t%s\t%s\n' "${file}" "${line}" "${normalized_ref}" >> "${missing_refs_file}"
done < "${discovered_refs_file}"

if [[ -s "${missing_refs_file}" ]]; then
  echo "FAIL: discovered DeployKube-owned GitOps image repositories that are neither package-indexed nor explicitly exempt:" >&2
  while IFS=$'\t' read -r file line ref; do
    printf '  - %s:%s -> %s\n' "${file}" "${line}" "${ref}" >&2
  done < "${missing_refs_file}"
  echo "Fix: add the image to ${package_index_file} and centralized Trivy coverage, or add a justified entry to ${exemptions_file}." >&2
  exit 1
fi

echo "validate-trivy-repo-owned-image-coverage: OK"
