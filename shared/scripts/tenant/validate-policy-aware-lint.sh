#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-policy-aware-lint.sh [--org-id <orgId>] <rendered.yaml...>

Static lint for known tenant constraints (fast PR feedback).

Current checks:
- Fail on NetworkPolicy ipBlock usage (tenant posture forbids ipBlock).
- Fail on unsafe cross-namespace NetworkPolicy peers:
  - deny empty peers (`from/to: - {}`) and `namespaceSelector: {}` patterns
  - deny `matchExpressions` for selectors (keep policies reviewable)
  - require tenant-scoped namespaceSelectors (`darksite.cloud/tenant-id`) for non-platform namespaces
  - allow platform namespaces only via narrow allowlists (DNS + Istio ingress gateway + tenant gateway + Garage S3)
- Fail on Service type NodePort/LoadBalancer (tenant exposure must use Gateway API).
- Fail on HTTPRoute attachments which violate the tenant gateway pattern:
  - deny parentRefs to Gateway/public-gateway (route hijack prevention)
  - when --org-id is provided, require parentRefs to Gateway/istio-system/tenant-<orgId>-gateway (sectionName=http)
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

require rg
require yq

org_id=""
if [[ "${1:-}" == "--org-id" ]]; then
  org_id="${2:-}"
  if [[ -z "${org_id}" ]]; then
    echo "error: --org-id requires a value" >&2
    usage >&2
    exit 2
  fi
  shift 2
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

failures=0

for f in "$@"; do
  if [[ ! -f "${f}" ]]; then
    echo "error: input file not found: ${f}" >&2
    exit 2
  fi

  ipblock_re="^[[:space:]]*(-[[:space:]]*)?ipBlock:[[:space:]]*$"
  if rg -n "${ipblock_re}" "${f}" >/dev/null 2>&1; then
    echo "FAIL: ${f}: NetworkPolicy ipBlock is forbidden in tenant namespaces" >&2
    rg -n "${ipblock_re}" "${f}" >&2
    failures=$((failures + 1))
  fi

  bad_netpol_empty_peers="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      (
        ($np.spec.ingress[]?.from[]? | select((has("ipBlock") or has("namespaceSelector") or has("podSelector")) | not) | [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv),
        ($np.spec.egress[]?.to[]? | select((has("ipBlock") or has("namespaceSelector") or has("podSelector")) | not) | [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv)
      )
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_empty_peers}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy peers must not be empty ({}); empty peers match all namespaces" >&2
    printf '%s\n' "${bad_netpol_empty_peers}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_selector_expressions="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      (
        ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
        select(has("namespaceSelector") and (.namespaceSelector | has("matchExpressions"))) |
        [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
      ),
      (
        ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
        select(has("podSelector") and (.podSelector | has("matchExpressions"))) |
        [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
      )
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_selector_expressions}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy peers must not use matchExpressions (reviewable matchLabels-only contract)" >&2
    printf '%s\n' "${bad_netpol_selector_expressions}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_cross_namespace_missing_matchlabels="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector")) |
      select((.namespaceSelector | has("matchLabels")) | not) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_cross_namespace_missing_matchlabels}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy cross-namespace peers must use namespaceSelector.matchLabels (namespaceSelector: {} is forbidden)" >&2
    printf '%s\n' "${bad_netpol_cross_namespace_missing_matchlabels}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_cross_namespace_empty_matchlabels="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
      select((.namespaceSelector.matchLabels | length) == 0) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_cross_namespace_empty_matchlabels}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy cross-namespace peers must not use empty namespaceSelector.matchLabels (matches all namespaces)" >&2
    printf '%s\n' "${bad_netpol_cross_namespace_empty_matchlabels}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_cross_namespace_missing_podselector="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector")) |
      select((has("podSelector")) | not) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_cross_namespace_missing_podselector}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy cross-namespace peers must include podSelector (avoid opening to all pods in a namespace)" >&2
    printf '%s\n' "${bad_netpol_cross_namespace_missing_podselector}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_cross_namespace_empty_podselector="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and has("podSelector")) |
      select((.podSelector | has("matchLabels")) | not or (.podSelector.matchLabels | length) == 0) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_cross_namespace_empty_podselector}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy cross-namespace peers must use podSelector.matchLabels (podSelector: {} is forbidden cross-namespace)" >&2
    printf '%s\n' "${bad_netpol_cross_namespace_empty_podselector}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_cross_namespace_disallowed_namespace_name="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
      select(.namespaceSelector.matchLabels | has("kubernetes.io/metadata.name")) |
      select((.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "kube-system" and (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "istio-system" and (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "garage") |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_cross_namespace_disallowed_namespace_name}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy namespaceSelector must not rely on kubernetes.io/metadata.name (only kube-system/istio-system/garage are allowed)" >&2
    printf '%s\n' "${bad_netpol_cross_namespace_disallowed_namespace_name}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_cross_namespace_missing_tenant_id="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
      select((.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "kube-system" and (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "istio-system" and (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "garage") |
      select((.namespaceSelector.matchLabels | has("darksite.cloud/tenant-id")) | not) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_cross_namespace_missing_tenant_id}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy cross-namespace peers must include namespaceSelector.matchLabels.darksite.cloud/tenant-id" >&2
    printf '%s\n' "${bad_netpol_cross_namespace_missing_tenant_id}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  if [[ -n "${org_id}" ]]; then
    bad_netpol_cross_namespace_wrong_tenant_id="$(
      ORG_ID="${org_id}" yq eval-all -r '
        select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
        ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
        select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
        select((.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "kube-system" and (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "istio-system" and (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") != "garage") |
        select((.namespaceSelector.matchLabels."darksite.cloud/tenant-id" // "") != strenv(ORG_ID)) |
        [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
      ' "${f}" | sort -u
    )"
    if [[ -n "${bad_netpol_cross_namespace_wrong_tenant_id}" ]]; then
      echo "FAIL: ${f}: NetworkPolicy cross-namespace peers must scope darksite.cloud/tenant-id=${org_id}" >&2
      printf '%s\n' "${bad_netpol_cross_namespace_wrong_tenant_id}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
      failures=$((failures + 1))
    fi
  fi

  bad_netpol_system_kubedns="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
      select((.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") == "kube-system") |
      select((.podSelector.matchLabels // {}) != {"k8s-app":"kube-dns"}) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_system_kubedns}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy peers targeting kube-system must select kube-dns only (podSelector.matchLabels={k8s-app: kube-dns})" >&2
    printf '%s\n' "${bad_netpol_system_kubedns}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_system_garage="$(
    yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
      select((.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") == "garage") |
      select((.podSelector.matchLabels // {}) != {"app.kubernetes.io/name":"garage","app.kubernetes.io/component":"object-storage"}) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_system_garage}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy peers targeting garage must select Garage S3 pods only (podSelector.matchLabels={app.kubernetes.io/name: garage, app.kubernetes.io/component: object-storage})" >&2
    printf '%s\n' "${bad_netpol_system_garage}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_netpol_system_istio_ingressgateway="$(
    ORG_ID="${org_id}" yq eval-all -r '
      select(.apiVersion == "networking.k8s.io/v1" and .kind == "NetworkPolicy") as $np |
      ($np.spec.ingress[]?.from[]?, $np.spec.egress[]?.to[]?) |
      select(has("namespaceSelector") and (.namespaceSelector | has("matchLabels"))) |
      select((.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") == "istio-system") |
      (.podSelector.matchLabels // {}) as $ml |
      select(
        (
          $ml == {"istio":"ingressgateway"} or
          (
            ($ml | keys | length) == 1 and
            ($ml | has("gateway.networking.k8s.io/gateway-name")) and
            (
              (strenv(ORG_ID) != "" and $ml."gateway.networking.k8s.io/gateway-name" == ("tenant-" + strenv(ORG_ID) + "-gateway")) or
              (strenv(ORG_ID) == "" and ($ml."gateway.networking.k8s.io/gateway-name" | test("^tenant-[a-z0-9]([a-z0-9-]*[a-z0-9])?-gateway$")))
            )
          )
        ) | not
      ) |
      [($np.metadata.namespace // ""), ($np.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_netpol_system_istio_ingressgateway}" ]]; then
    echo "FAIL: ${f}: NetworkPolicy peers targeting istio-system must select the ingress gateway (podSelector.matchLabels={istio: ingressgateway}) or the tenant gateway (podSelector.matchLabels={gateway.networking.k8s.io/gateway-name: tenant-<tenantId>-gateway})" >&2
    printf '%s\n' "${bad_netpol_system_istio_ingressgateway}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  bad_services="$(yq eval-all -r 'select(.apiVersion == "v1" and .kind == "Service") | select((.spec.type // "ClusterIP") == "NodePort" or (.spec.type // "ClusterIP") == "LoadBalancer") | [(.metadata.namespace // ""), (.metadata.name // ""), (.spec.type // "ClusterIP")] | @tsv' "${f}")"
  if [[ -n "${bad_services}" ]]; then
    echo "FAIL: ${f}: Service type NodePort/LoadBalancer is forbidden in tenant namespaces" >&2
    printf '%s\n' "${bad_services}" | awk -F'\t' '{printf "  - %s/%s (%s)\n", $1, $2, $3}' >&2
    failures=$((failures + 1))
  fi

  bad_public_routes="$(
    yq eval-all -r '
      select(.apiVersion == "gateway.networking.k8s.io/v1" and .kind == "HTTPRoute") |
      select((.spec.parentRefs // []) | map(select((.name // "") == "public-gateway")) | length > 0) |
      [(.metadata.namespace // ""), (.metadata.name // "")] | @tsv
    ' "${f}" | sort -u
  )"
  if [[ -n "${bad_public_routes}" ]]; then
    echo "FAIL: ${f}: HTTPRoute parentRefs must not target Gateway/public-gateway" >&2
    printf '%s\n' "${bad_public_routes}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
    failures=$((failures + 1))
  fi

  if [[ -n "${org_id}" ]]; then
    expected_gateway="tenant-${org_id}-gateway"
    bad_parent_routes="$(
      EXPECTED_GATEWAY="${expected_gateway}" yq eval-all -r '
        select(.apiVersion == "gateway.networking.k8s.io/v1" and .kind == "HTTPRoute") |
        select((.spec.parentRefs // []) | length > 0) |
        select((.spec.parentRefs // []) | map(select(
          (
            (.name // "") != strenv(EXPECTED_GATEWAY) or
            (.namespace // "") != "istio-system" or
            (has("sectionName") and (.sectionName // "") != "http")
          )
        )) | length > 0) |
        [(.metadata.namespace // ""), (.metadata.name // "")] | @tsv
      ' "${f}" | sort -u
    )"
    if [[ -n "${bad_parent_routes}" ]]; then
      echo "FAIL: ${f}: HTTPRoute parentRefs must target Gateway/istio-system/${expected_gateway} (sectionName=http)" >&2
      printf '%s\n' "${bad_parent_routes}" | awk -F'\t' '{printf "  - %s/%s\n", $1, $2}' >&2
      failures=$((failures + 1))
    fi
  fi
done

if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi
