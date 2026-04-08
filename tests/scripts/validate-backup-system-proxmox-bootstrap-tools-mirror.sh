#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "FAIL: kubectl not found (needed for 'kubectl kustomize')" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "FAIL: rg not found" >&2
  exit 1
fi

overlay_dir="platform/gitops/components/storage/backup-system/overlays/proxmox-talos"
expected="198.51.100.11:5010/deploykube/bootstrap-tools@sha256:72407960aa586b2220673e125e20a3c6c0723460ec3064b98597bfe6d90c6456"
unexpected="registry.example.internal/deploykube/bootstrap-tools@sha256:e7be47a69e3a11bc58c857f2d690a71246ada91ac3a60bdfb0a547f091f6485a"

rendered="$(kubectl kustomize "${overlay_dir}" 2>&1)" || {
  echo "${rendered}" >&2
  echo "FAIL: kustomize render failed for ${overlay_dir}" >&2
  exit 1
}

refs="$(printf '%s\n' "${rendered}" | rg -o '[A-Za-z0-9./:-]+/deploykube/bootstrap-tools@sha256:[0-9a-f]{64}' || true)"
if [ -z "${refs}" ]; then
  echo "FAIL: ${overlay_dir} rendered no digest-pinned bootstrap-tools references" >&2
  exit 1
fi

if printf '%s\n' "${refs}" | rg -n -q -F -- "${unexpected}"; then
  echo "FAIL: ${overlay_dir} still renders canonical bootstrap-tools digest refs on proxmox" >&2
  printf '%s\n' "${refs}" | rg -n -F -- "${unexpected}" >&2
  exit 1
fi

unexpected_refs="$(printf '%s\n' "${refs}" | grep -Fvx "${expected}" || true)"
if [ -n "${unexpected_refs}" ]; then
  echo "FAIL: ${overlay_dir} rendered unexpected proxmox bootstrap-tools digest refs" >&2
  printf '%s\n' "${unexpected_refs}" >&2
  exit 1
fi

count="$(printf '%s\n' "${refs}" | wc -l | tr -d ' ')"
echo "backup-system proxmox bootstrap-tools mirror validation PASSED (${count} refs)"
