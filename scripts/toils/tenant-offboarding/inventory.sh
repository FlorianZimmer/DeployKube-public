#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./scripts/toils/tenant-offboarding/inventory.sh --org-id <orgId>

Prints an inventory snapshot for offboarding evidence:
- tenant namespaces (by label)
- PVC→PV mapping per namespace
- PV backend path hints (NFS/local-path) when available

Notes:
- This script is read-only.
- It uses your current kubectl context (set KUBECONFIG / --context externally).
EOF
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency kubectl
check_dependency jq

org_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --org-id)
      org_id="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${org_id}" ]]; then
  echo "error: --org-id is required" >&2
  usage >&2
  exit 2
fi

echo "==> Tenant namespaces (darksite.cloud/tenant-id=${org_id})"
ns_json="$(kubectl get namespace -l "darksite.cloud/tenant-id=${org_id}" -o json)"
ns_count="$(echo "${ns_json}" | jq '.items | length')"
if [[ "${ns_count}" -eq 0 ]]; then
  echo "info: no namespaces found for orgId=${org_id}"
  exit 0
fi

echo "${ns_json}" | jq -r '
  .items[]
  | [
      .metadata.name,
      ("rbac=" + (.metadata.labels["darksite.cloud/rbac-profile"] // "")),
      ("project=" + (.metadata.labels["darksite.cloud/project-id"] // "")),
      ("obsTenant=" + (.metadata.labels["observability.grafana.com/tenant"] // ""))
    ]
  | @tsv
'

echo ""
echo "==> PVC → PV mapping (per tenant namespace)"
printf '%s\n' "namespace\tpvc\tpv\tstorageClass\taccessModes\trequest\tphase"

mapfile -t namespaces < <(echo "${ns_json}" | jq -r '.items[].metadata.name' | sort)

declare -A pv_seen=()
pv_list=()

for ns in "${namespaces[@]}"; do
  pvc_json="$(kubectl -n "${ns}" get pvc -o json)"
  echo "${pvc_json}" | jq -r '
    .items[]
    | [
        .metadata.namespace,
        .metadata.name,
        (.spec.volumeName // ""),
        (.spec.storageClassName // ""),
        ((.spec.accessModes // []) | join(",")),
        (.spec.resources.requests.storage // ""),
        (.status.phase // "")
      ]
    | @tsv
  '

  while IFS= read -r pv; do
    [[ -n "${pv}" && "${pv}" != "null" ]] || continue
    if [[ -z "${pv_seen[${pv}]:-}" ]]; then
      pv_seen["${pv}"]=1
      pv_list+=("${pv}")
    fi
  done < <(echo "${pvc_json}" | jq -r '.items[].spec.volumeName // empty')
done

if [[ "${#pv_list[@]}" -eq 0 ]]; then
  echo ""
  echo "info: no PVs referenced by tenant PVCs (orgId=${org_id})"
  exit 0
fi

echo ""
echo "==> PV backend paths (best-effort; for wipe allowlist checks)"
printf '%s\n' "pv\treclaimPolicy\tcapacity\tbackendType\tbackendRef"

for pv in "${pv_list[@]}"; do
  pv_json="$(kubectl get pv "${pv}" -o json)"
  echo "${pv_json}" | jq -r '
    def cap:
      (.spec.capacity.storage // "");
    def reclaim:
      (.spec.persistentVolumeReclaimPolicy // "");
    def backend:
      if .spec.nfs then
        ["nfs", (.spec.nfs.server + ":" + .spec.nfs.path)]
      elif .spec.hostPath then
        ["hostPath", (.spec.hostPath.path)]
      elif .spec.csi then
        ["csi", ((.spec.csi.driver // "") + ":" + (.spec.csi.volumeHandle // ""))]
      else
        ["unknown", ""]
      end;
    [
      (.metadata.name // ""),
      reclaim,
      cap,
      (backend[0]),
      (backend[1])
    ] | @tsv
  '
done
