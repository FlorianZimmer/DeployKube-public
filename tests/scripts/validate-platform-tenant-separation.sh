#!/usr/bin/env bash
# validate-platform-tenant-separation.sh - Ensure demo apps are opt-in, not part of platform core bundles
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

failures=0

platform_apps_base="platform/gitops/components/platform/platform-apps-controller/base/platformapps.platform.darksite.cloud.yaml"
platform_apps_overlays=(
  "platform/gitops/components/platform/platform-apps-controller/overlays/mac-orbstack-single/patch-platformapps.yaml"
  "platform/gitops/components/platform/platform-apps-controller/overlays/proxmox-talos/patch-platformapps.yaml"
)

example_app_names=(
  "apps-factorio"
  "apps-minecraft-monifactory"
)

opt_in_paths=(
  "platform/gitops/apps/opt-in/examples-apps/overlays/dev"
  "platform/gitops/apps/opt-in/examples-apps/overlays/prod"
)
opt_in_base="platform/gitops/apps/opt-in/examples-apps/base"

echo "==> Validating platform/tenant separation (demo apps are opt-in)"

if [[ ! -f "${platform_apps_base}" ]]; then
  echo "FAIL: missing PlatformApps base spec: ${platform_apps_base}" >&2
  failures=$((failures + 1))
else
  for name in "${example_app_names[@]}"; do
    enabled="$(yq -r ".spec.apps[] | select(.name == \"${name}\") | (.enabled | tostring)" "${platform_apps_base}" 2>/dev/null || true)"
    if [[ "${enabled}" != "false" ]]; then
      echo "FAIL: ${name} must remain disabled in PlatformApps base spec" >&2
      failures=$((failures + 1))
    fi
  done
fi

for overlay in "${platform_apps_overlays[@]}"; do
  if [[ ! -f "${overlay}" ]]; then
    echo "FAIL: missing PlatformApps overlay patch: ${overlay}" >&2
    failures=$((failures + 1))
    continue
  fi
  for name in "${example_app_names[@]}"; do
    if yq -e ".spec.enabledApps[] | select(. == \"${name}\")" "${overlay}" >/dev/null 2>&1; then
      echo "FAIL: core PlatformApps overlay must not force-enable ${name}: ${overlay}" >&2
      failures=$((failures + 1))
    fi
  done
done

if [[ ! -d "${opt_in_base}" || ! -f "${opt_in_base}/kustomization.yaml" ]]; then
  echo "FAIL: missing opt-in examples base bundle: ${opt_in_base}" >&2
  failures=$((failures + 1))
else
  for name in "${example_app_names[@]}"; do
    if ! rg -n "^[[:space:]]*name:[[:space:]]*${name}[[:space:]]*$" "${opt_in_base}" -S >/dev/null 2>&1; then
      echo "FAIL: opt-in examples base must include ${name}: ${opt_in_base}" >&2
      failures=$((failures + 1))
    fi
  done
fi

for p in "${opt_in_paths[@]}"; do
  if [[ ! -d "${p}" ]]; then
    echo "FAIL: missing opt-in examples overlay dir: ${p}" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ ! -f "${p}/kustomization.yaml" ]]; then
    echo "FAIL: missing kustomization.yaml in opt-in overlay dir: ${p}" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! rg -n "^resources:[[:space:]]*$" "${p}/kustomization.yaml" >/dev/null 2>&1 || ! rg -n "\.\./\.\./base" "${p}/kustomization.yaml" >/dev/null 2>&1; then
    echo "FAIL: opt-in overlay must include ../../base: ${p}/kustomization.yaml" >&2
    failures=$((failures + 1))
  fi
done

# Prod overlay must patch source paths to /overlays/proxmox-talos
if [[ -f "platform/gitops/apps/opt-in/examples-apps/overlays/prod/kustomization.yaml" ]]; then
  for name in "${example_app_names[@]}"; do
    if ! rg -n "value:[[:space:]]*components/apps/.*/overlays/proxmox-talos" "platform/gitops/apps/opt-in/examples-apps/overlays/prod/kustomization.yaml" >/dev/null 2>&1; then
      echo "FAIL: opt-in prod overlay should set source paths to overlays/proxmox-talos: platform/gitops/apps/opt-in/examples-apps/overlays/prod/kustomization.yaml" >&2
      failures=$((failures + 1))
      break
    fi
  done
fi

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "platform/tenant separation validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "platform/tenant separation validation PASSED"
