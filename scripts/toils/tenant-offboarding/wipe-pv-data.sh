#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./scripts/toils/tenant-offboarding/wipe-pv-data.sh --org-id <orgId> [--jobs-namespace <ns>] [--out <file>] [--apply --confirm <orgId>]

Generates (and optionally runs) Kubernetes Jobs that wipe PV backend data for a tenant.

This is required because the default StorageClass `shared-rwo` uses `reclaimPolicy: Retain`,
so deleting namespaces/PVCs does not delete underlying bytes.

Safety model:
- Only wipes PVs referenced by PVCs in namespaces labeled `darksite.cloud/tenant-id=<orgId>`.
- Only wipes paths that match the expected `rwo/<namespace>-<pvc>` contract.
- Default is dry-run (prints a Job manifest bundle).

Options:
  --jobs-namespace <ns>   Namespace for wipe Jobs (default: storage-system)
  --image <ref>           Container image to use for wipe Jobs (default: auto-discover from an existing bootstrap-tools CronJob)
  --out <file>            Write the Job manifest bundle to a file instead of stdout
  --apply                 Create Jobs and wait for completion (destructive)
  --confirm <orgId>       Required with --apply (must equal --org-id)
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
check_dependency python3
check_dependency yq

org_id=""
jobs_namespace="storage-system"
tools_image=""
out_path=""
apply="false"
confirm=""

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
    --jobs-namespace)
      jobs_namespace="${2:-}"
      shift 2
      ;;
    --image)
      tools_image="${2:-}"
      shift 2
      ;;
    --out)
      out_path="${2:-}"
      shift 2
      ;;
    --apply)
      apply="true"
      shift
      ;;
    --confirm)
      confirm="${2:-}"
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

if [[ "${apply}" == "true" && "${confirm}" != "${org_id}" ]]; then
  echo "error: --apply requires --confirm <orgId> (got: '${confirm}', expected: '${org_id}')" >&2
  exit 2
fi

if [[ -z "${tools_image}" ]]; then
  tools_image="$(kubectl -n "${jobs_namespace}" get cronjob storage-smoke-shared-rwo-io -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
fi
if [[ -z "${tools_image}" ]]; then
  tools_image="registry.example.internal/deploykube/bootstrap-tools:1.4"
  echo "WARN: failed to discover bootstrap-tools image from CronJob/storage-smoke-shared-rwo-io; falling back to ${tools_image}" >&2
fi

echo "==> Discover tenant PVs (claimRef namespace prefix: t-${org_id}-*)"
all_pv_json="$(kubectl get pv -o json)"
mapfile -t pv_lines < <(
  echo "${all_pv_json}" | jq -r --arg prefix "t-${org_id}-" '
    .items[]
    | select((.spec.claimRef.namespace // "") | startswith($prefix))
    | [
        (.metadata.name // ""),
        (.spec.claimRef.namespace // ""),
        (.spec.claimRef.name // ""),
        (.spec.storageClassName // ""),
        (.spec.persistentVolumeReclaimPolicy // ""),
        (.spec.nfs.server // ""),
        (.spec.nfs.path // ""),
        (.spec.hostPath.path // "")
      ] | @tsv
  ' | sort
)

if [[ "${#pv_lines[@]}" -eq 0 ]]; then
  echo "info: no PVs found for orgId=${org_id} (by claimRef namespace prefix); nothing to wipe"
  exit 0
fi

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}" || true; }
trap cleanup EXIT INT TERM

bundle="${tmpdir}/pv-wipe-jobs.yaml"
: >"${bundle}"

run_id="$(date -u +%y%m%d%H%M%S)"

jobs=0
skipped=0

job_name_for() {
  local pv="$1"
  python3 - "${run_id}" "${org_id}" "${pv}" <<'PY'
import hashlib
import sys

run_id = sys.argv[1]
org = sys.argv[2]
pv = sys.argv[3]
h = hashlib.sha256(f"{org}:{pv}".encode("utf-8")).hexdigest()[:10]
print(f"tenant-pv-wipe-{run_id}-{h}")
PY
}

node_for_pv() {
  local pv_json="$1"
  echo "${pv_json}" | jq -r '
    .spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?
    | select(.key == "kubernetes.io/hostname")
    | .values[0] // empty
  ' | head -n 1
}

render_job_nfs() {
  local job_name="$1"
  local pv="$2"
  local claim_ns="$3"
  local claim_name="$4"
  local server="$5"
  local parent="$6"
  local subdir="$7"

  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${jobs_namespace}
  labels:
    app.kubernetes.io/name: tenant-pv-wipe
    darksite.cloud/tenant-id: ${org_id}
    darksite.cloud/offboarding: "true"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      containers:
        - name: wipe
          image: ${tools_image}
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash","-lc"]
          args:
            - |
              set -euo pipefail
              echo "[wipe] pv=${pv} claim=${claim_ns}/${claim_name} backend=nfs server=${server} parent=${parent} dir=${subdir}"
              if [[ -z "${subdir}" || "${subdir}" == "." || "${subdir}" == ".." ]]; then
                echo "[wipe] invalid dir: '${subdir}'" >&2
                exit 1
              fi
              if [[ ! -d "/target/${subdir}" ]]; then
                echo "[wipe] WARN: /target/${subdir} does not exist (already wiped?)"
                exit 0
              fi
              rm -rf "/target/${subdir}"
              echo "[wipe] removed /target/${subdir}"
              test ! -e "/target/${subdir}"
          volumeMounts:
            - name: target
              mountPath: /target
      volumes:
        - name: target
          nfs:
            server: ${server}
            path: ${parent}
EOF
}

render_job_hostpath() {
  local job_name="$1"
  local pv="$2"
  local claim_ns="$3"
  local claim_name="$4"
  local node="$5"
  local parent="$6"
  local subdir="$7"

  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${jobs_namespace}
  labels:
    app.kubernetes.io/name: tenant-pv-wipe
    darksite.cloud/tenant-id: ${org_id}
    darksite.cloud/offboarding: "true"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector:
        kubernetes.io/hostname: ${node}
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      containers:
        - name: wipe
          image: ${tools_image}
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash","-lc"]
          args:
            - |
              set -euo pipefail
              echo "[wipe] pv=${pv} claim=${claim_ns}/${claim_name} backend=hostPath parent=${parent} dir=${subdir} node=${node}"
              if [[ -z "${subdir}" || "${subdir}" == "." || "${subdir}" == ".." ]]; then
                echo "[wipe] invalid dir: '${subdir}'" >&2
                exit 1
              fi
              if [[ ! -d "/target/${subdir}" ]]; then
                echo "[wipe] WARN: /target/${subdir} does not exist (already wiped?)"
                exit 0
              fi
              rm -rf "/target/${subdir}"
              echo "[wipe] removed /target/${subdir}"
              test ! -e "/target/${subdir}"
          volumeMounts:
            - name: target
              mountPath: /target
      volumes:
        - name: target
          hostPath:
            path: ${parent}
            type: Directory
EOF
}

for line in "${pv_lines[@]}"; do
  IFS=$'\t' read -r pv claim_ns claim_name sc reclaim backend_nfs_server backend_nfs_path backend_host_path <<<"${line}"
  [[ -n "${pv}" && -n "${claim_ns}" && -n "${claim_name}" ]] || { skipped=$((skipped + 1)); continue; }

  pv_json="$(kubectl get pv "${pv}" -o json)"
  expected_suffix="rwo/${claim_ns}-${claim_name}"
  job_name="$(job_name_for "${pv}")"

  if [[ -n "${backend_nfs_server}" && -n "${backend_nfs_path}" ]]; then
    if [[ "${backend_nfs_path}" != *"/${expected_suffix}" ]]; then
      echo "WARN: skip pv=${pv}: nfs.path='${backend_nfs_path}' does not match expected suffix '/${expected_suffix}'" >&2
      skipped=$((skipped + 1))
      continue
    fi
    parent="$(dirname "${backend_nfs_path}")"
    subdir="$(basename "${backend_nfs_path}")"
    printf '\n---\n' >>"${bundle}"
    render_job_nfs "${job_name}" "${pv}" "${claim_ns}" "${claim_name}" "${backend_nfs_server}" "${parent}" "${subdir}" >>"${bundle}"
    jobs=$((jobs + 1))
    continue
  fi

  if [[ -n "${backend_host_path}" ]]; then
    if [[ "${backend_host_path}" != *"/${expected_suffix}" ]]; then
      echo "WARN: skip pv=${pv}: hostPath.path='${backend_host_path}' does not match expected suffix '/${expected_suffix}'" >&2
      skipped=$((skipped + 1))
      continue
    fi
    node="$(node_for_pv "${pv_json}")"
    if [[ -z "${node}" ]]; then
      echo "WARN: skip pv=${pv}: missing nodeAffinity hostname (required for local-path wipe)" >&2
      skipped=$((skipped + 1))
      continue
    fi
    parent="$(dirname "${backend_host_path}")"
    subdir="$(basename "${backend_host_path}")"
    printf '\n---\n' >>"${bundle}"
    render_job_hostpath "${job_name}" "${pv}" "${claim_ns}" "${claim_name}" "${node}" "${parent}" "${subdir}" >>"${bundle}"
    jobs=$((jobs + 1))
    continue
  fi

  echo "WARN: skip pv=${pv}: unsupported backend (expected spec.nfs or spec.hostPath)" >&2
  skipped=$((skipped + 1))
done

if [[ "${jobs}" -eq 0 ]]; then
  echo "info: no wipe jobs generated (skipped=${skipped})"
  exit 0
fi

echo ""
echo "==> Generated wipe Jobs: ${jobs} (skipped=${skipped})"

if [[ -n "${out_path}" ]]; then
  cp "${bundle}" "${out_path}"
  echo "wrote: ${out_path}"
else
  cat "${bundle}"
fi

if [[ "${apply}" != "true" ]]; then
  echo ""
  echo "DRY-RUN: pass --apply --confirm ${org_id} to create Jobs"
  exit 0
fi

echo ""
echo "==> Applying wipe Jobs in namespace ${jobs_namespace}"
kubectl get namespace "${jobs_namespace}" >/dev/null 2>&1 || kubectl create namespace "${jobs_namespace}" >/dev/null

kubectl apply -f "${bundle}"

echo ""
echo "==> Waiting for completion"
mapfile -t job_names < <(yq -r 'select(.kind=="Job") | .metadata.name' "${bundle}")
for job in "${job_names[@]}"; do
  kubectl -n "${jobs_namespace}" wait --for=condition=complete "job/${job}" --timeout=30m
  kubectl -n "${jobs_namespace}" logs "job/${job}" --all-containers --tail=200 || true
done

echo ""
echo "OK: wipe Jobs completed"
