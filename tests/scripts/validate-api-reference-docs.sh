#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) not found" >&2
  exit 1
fi

failures=0

echo "==> validating product-owned API reference docs (CRDs: *.darksite.cloud)"

if [ ! -f docs/apis/README.md ]; then
  echo "FAIL: missing docs/apis/README.md" >&2
  failures=$((failures + 1))
fi

mapfile -t crd_files < <(
  rg -l "^kind: CustomResourceDefinition$" -S platform/gitops -g'*.yaml' | sort
)

if [ "${#crd_files[@]}" -eq 0 ]; then
  echo "FAIL: no CRD manifests found under platform/gitops (unexpected)" >&2
  exit 1
fi

extract_group() {
  local doc="$1"
  awk '
    BEGIN { in_spec=0 }
    /^spec:[[:space:]]*$/ { in_spec=1; next }
    in_spec && /^[[:space:]]+group:[[:space:]]*/ {
      g=$0
      sub(/^[[:space:]]+group:[[:space:]]*/, "", g)
      print g
      exit
    }
  ' "${doc}"
}

extract_kind() {
  local doc="$1"
  awk '
    BEGIN { in_spec=0; in_names=0 }
    /^spec:[[:space:]]*$/ { in_spec=1; next }
    in_spec && /^[[:space:]]+names:[[:space:]]*$/ { in_names=1; next }
    in_names && /^[[:space:]]+kind:[[:space:]]*/ {
      k=$0
      sub(/^[[:space:]]+kind:[[:space:]]*/, "", k)
      print k
      exit
    }
  ' "${doc}"
}

extract_versions() {
  local doc="$1"
  awk '
    BEGIN { in_spec=0; in_versions=0 }
    /^spec:[[:space:]]*$/ { in_spec=1; next }
    in_spec && /^[[:space:]]+versions:[[:space:]]*$/ { in_versions=1; next }
    in_versions && /^[[:space:]]+- name:[[:space:]]*/ {
      v=$0
      sub(/^[[:space:]]+- name:[[:space:]]*/, "", v)
      print v
    }
    in_versions && /^[^[:space:]]/ { exit } # next top-level document key
  ' "${doc}" | sort -u
}

for f in "${crd_files[@]}"; do
  tmpdir="$(mktemp -d)"
  cp "${f}" "${tmpdir}/all.yaml"

  awk -v out="${tmpdir}/doc-" '
    BEGIN { n=0; f=sprintf("%s%03d.yaml", out, n) }
    /^---$/ { n++; f=sprintf("%s%03d.yaml", out, n); next }
    { print > f }
  ' "${tmpdir}/all.yaml"

  for doc in "${tmpdir}"/doc-*.yaml; do
    [ -s "${doc}" ] || continue

    top_kind="$(awk -F': *' '/^kind:/{print $2; exit}' "${doc}")"
    if [ "${top_kind}" != "CustomResourceDefinition" ]; then
      continue
    fi

    group="$(extract_group "${doc}")"
    kind="$(extract_kind "${doc}")"

    # Some upstream components ship CRD "stubs" (metadata-only) purely to force
    # Argo sync-options (Replace=true). Those do not have spec/group/names.kind.
    if [ -z "${group}" ] || [ -z "${kind}" ]; then
      continue
    fi

    if [[ "${group}" != *.darksite.cloud ]]; then
      continue
    fi

    area="${group%%.*}"

    group_readme="docs/apis/${area}/${group}/README.md"
    if [ ! -f "${group_readme}" ]; then
      echo "FAIL: missing group API reference: ${group_readme} (CRD ${kind}.${group})" >&2
      failures=$((failures + 1))
    fi

    mapfile -t versions < <(extract_versions "${doc}")
    if [ "${#versions[@]}" -eq 0 ]; then
      echo "FAIL: CRD has no versions parsed: ${f} (CRD ${kind}.${group})" >&2
      failures=$((failures + 1))
      continue
    fi

    for v in "${versions[@]}"; do
      version_readme="docs/apis/${area}/${group}/${v}/README.md"
      if [ ! -f "${version_readme}" ]; then
        echo "FAIL: missing version API reference: ${version_readme} (CRD ${kind}.${group})" >&2
        failures=$((failures + 1))
      fi

      kind_doc="docs/apis/${area}/${group}/${v}/${kind}.md"
      if [ ! -f "${kind_doc}" ]; then
        echo "FAIL: missing kind API reference: ${kind_doc} (CRD ${kind}.${group})" >&2
        failures=$((failures + 1))
      fi
    done
  done

  rm -rf "${tmpdir}"
done

if [ "${failures}" -ne 0 ]; then
  exit 1
fi

echo "PASS"
