#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl not found (needed for 'kubectl kustomize')" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "error: rg not found" >&2
  exit 1
fi

env_dir="platform/gitops/apps/environments/proxmox-talos"

rendered="$(kubectl kustomize "${env_dir}" 2>&1)" || {
  echo "${rendered}" >&2
  echo "FAIL: kustomize render failed for ${env_dir}" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
printf '%s\n' "${rendered}" > "${tmpdir}/all.yaml"

awk -v out="${tmpdir}/doc-" '
  BEGIN { n=0; f=sprintf("%s%03d.yaml", out, n) }
  /^---$/ { n++; f=sprintf("%s%03d.yaml", out, n); next }
  { print > f }
' "${tmpdir}/all.yaml"

want_1="deploykube/bootstrap-tools:1.4=198.51.100.11:5010/deploykube/bootstrap-tools:1.4"
want_2="registry.example.internal/deploykube/bootstrap-tools:1.4=198.51.100.11:5010/deploykube/bootstrap-tools:1.4"
want_3="registry.example.internal/deploykube/bootstrap-tools@sha256:e7be47a69e3a11bc58c857f2d690a71246ada91ac3a60bdfb0a547f091f6485a=198.51.100.11:5010/deploykube/bootstrap-tools@sha256:72407960aa586b2220673e125e20a3c6c0723460ec3064b98597bfe6d90c6456"
want_4="registry.example.internal/deploykube/tenant-provisioner:0.2.14=198.51.100.11:5010/deploykube/tenant-provisioner:0.2.14"

apps=0
checked=0
skipped=0
failures=0

for doc in "${tmpdir}"/doc-*.yaml; do
  [ -s "${doc}" ] || continue
  kind="$(awk -F': *' '/^kind:/{print $2; exit}' "${doc}")"
  [ "${kind}" = "Application" ] || continue

  apps=$((apps + 1))

  name="$(awk '/^metadata:/{m=1} m && /^  name:/{print $2; exit}' "${doc}")"
  [ -n "${name}" ] || name="(unknown)"

  source_type="$(awk '
    /^spec:/ {in_spec=1; next}
    in_spec && /^  source:/ {in_source=1; next}
    in_source && /^    kustomize:/ {print "kustomize"; found=1; exit}
    in_source && /^    helm:/ {print "helm"; found=1; exit}
    in_source && /^    chart:/ {print "helm"; found=1; exit}
    in_source && /^    path:/ {print "path"; found=1; exit}
    in_source && /^  [^ ]/ {in_source=0}
    END { if (!found) print "unknown" }
  ' "${doc}")"

  # Only Kustomize-based apps are expected to carry the bootstrap-tools image overrides.
  # Helm apps (including Helm-from-git path) must *not* have spec.source.kustomize.
  if [ "${source_type}" != "kustomize" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  checked=$((checked + 1))

  if ! rg -n -q -F -- "${want_1}" "${doc}"; then
    echo "FAIL: Application/${name} missing prod bootstrap-tools image override (${want_1})" >&2
    failures=$((failures + 1))
  fi
  if ! rg -n -q -F -- "${want_2}" "${doc}"; then
    echo "FAIL: Application/${name} missing prod bootstrap-tools image override (${want_2})" >&2
    failures=$((failures + 1))
  fi
  if ! rg -n -q -F -- "${want_3}" "${doc}"; then
    echo "FAIL: Application/${name} missing prod bootstrap-tools digest override (${want_3})" >&2
    failures=$((failures + 1))
  fi
  if ! rg -n -q -F -- "${want_4}" "${doc}"; then
    echo "FAIL: Application/${name} missing prod tenant-provisioner image override (${want_4})" >&2
    failures=$((failures + 1))
  fi
done

if [ "${apps}" -eq 0 ]; then
  echo "FAIL: no Application resources found in rendered ${env_dir} output" >&2
  exit 1
fi

if [ "${checked}" -eq 0 ]; then
  echo "FAIL: no Kustomize-based Application resources found in rendered ${env_dir} output" >&2
  exit 1
fi

if [ "${failures}" -ne 0 ]; then
  echo "" >&2
  echo "prod bootstrap-tools override lint FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "prod bootstrap-tools override lint PASSED (${checked} checked, ${skipped} skipped, ${apps} total)"
