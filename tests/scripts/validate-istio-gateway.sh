#!/usr/bin/env bash
# validate-istio-gateway.sh - Ensure Istio gateway is controller-owned (no rendered overlays)
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require yq
require rg

component_dir="platform/gitops/components/networking/istio/gateway"
platform_apps_file="platform/gitops/components/platform/platform-apps-controller/base/platformapps.platform.darksite.cloud.yaml"
render_script="scripts/deployments/render-istio-gateway.sh"

echo "==> Validating istio gateway (controller-owned)"

if [ -e "${render_script}" ]; then
  echo "error: legacy gateway renderer is still present: ${render_script}" >&2
  echo "hint: Gateways are now reconciled by the tenant provisioner controller." >&2
  exit 1
fi

if [ ! -d "${component_dir}" ]; then
  echo "error: missing component dir: ${component_dir}" >&2
  exit 1
fi

if [ -d "${component_dir}/overlays" ]; then
  if find "${component_dir}/overlays" -type f | rg -q '.'; then
    echo "error: istio gateway overlays must not exist anymore: ${component_dir}/overlays" >&2
    exit 1
  fi
fi

if ! yq -e '.resources[] | select(. == "base")' "${component_dir}/kustomization.yaml" >/dev/null 2>&1; then
  echo "error: expected ${component_dir}/kustomization.yaml to include resources: [base]" >&2
  exit 1
fi

base_kustomization="${component_dir}/base/kustomization.yaml"
if [ ! -f "${base_kustomization}" ]; then
  echo "error: missing base kustomization: ${base_kustomization}" >&2
  exit 1
fi
if ! yq -e '.resources[] | select(. == "gatewayclass-istio.yaml")' "${base_kustomization}" >/dev/null 2>&1; then
  echo "error: expected ${base_kustomization} to include gatewayclass-istio.yaml" >&2
  exit 1
fi

gatewayclass_file="${component_dir}/base/gatewayclass-istio.yaml"
if [ ! -f "${gatewayclass_file}" ]; then
  echo "error: missing GatewayClass manifest: ${gatewayclass_file}" >&2
  exit 1
fi
if ! yq -e '.kind == "GatewayClass" and .metadata.name == "istio" and .spec.controllerName == "istio.io/gateway-controller"' "${gatewayclass_file}" >/dev/null 2>&1; then
  echo "error: unexpected GatewayClass content in ${gatewayclass_file}" >&2
  exit 1
fi

if [ ! -f "${platform_apps_file}" ]; then
  echo "error: missing PlatformApps spec: ${platform_apps_file}" >&2
  exit 1
fi
if ! yq -e '.spec.apps[] | select(.name == "networking-istio-gateway") | .path == "components/networking/istio/gateway"' "${platform_apps_file}" >/dev/null 2>&1; then
  echo "error: PlatformApps spec must use path=components/networking/istio/gateway for networking-istio-gateway" >&2
  exit 1
fi
if ! yq -e '.spec.apps[] | select(.name == "networking-istio-gateway") | .overlay == false' "${platform_apps_file}" >/dev/null 2>&1; then
  echo "error: PlatformApps spec must set overlay=false for networking-istio-gateway" >&2
  exit 1
fi

echo "istio gateway validation PASSED"
