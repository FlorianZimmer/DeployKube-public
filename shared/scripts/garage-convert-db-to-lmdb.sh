#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  garage-convert-db-to-lmdb.sh --kubeconfig <path>

What it does:
  - Scales StatefulSet/garage to 0 (namespace: garage)
  - Converts Garage metadata DB from sqlite -> lmdb on the data PVC
  - Leaves the cluster stopped so you can flip db_engine to lmdb via GitOps and scale back up

Notes:
  - This only converts the metadata DB file (/var/lib/garage/meta/db.sqlite -> db.lmdb).
  - It does not change any Kubernetes manifests; do that via GitOps after conversion.
EOF
}

kubeconfig=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      kubeconfig="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${kubeconfig}" ]]; then
  echo "missing --kubeconfig" >&2
  usage >&2
  exit 2
fi

K="kubectl --kubeconfig ${kubeconfig}"
NS="garage"
STS="garage"
PVC="data-garage-0"
INPUT="/var/lib/garage/meta/db.sqlite"
OUTPUT="/var/lib/garage/meta/db.lmdb"
MAP_SIZE="64GiB"

echo "[garage-convert-db] scaling down ${NS}/${STS} to 0..." >&2
${K} -n "${NS}" scale statefulset "${STS}" --replicas=0

echo "[garage-convert-db] waiting for garage-0 to terminate..." >&2
for _ in $(seq 1 180); do
  if ! ${K} -n "${NS}" get pod garage-0 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ${K} -n "${NS}" get pod garage-0 >/dev/null 2>&1; then
  echo "garage-0 still exists after timeout; refusing to convert while Garage is running" >&2
  exit 1
fi

job="garage-convert-db-lmdb-$(date +%Y%m%d%H%M%S)"
echo "[garage-convert-db] running conversion job ${NS}/${job} (map size ${MAP_SIZE})..." >&2

cat <<EOF | ${K} -n "${NS}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: convert
          image: docker.io/dxflrs/garage:v2.1.0
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          command:
            - /garage
          args:
            - convert-db
            - -a
            - sqlite
            - -i
            - ${INPUT}
            - -b
            - lmdb
            - -o
            - ${OUTPUT}
            - --lmdb-map-size
            - ${MAP_SIZE}
          volumeMounts:
            - name: data
              mountPath: /var/lib/garage
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC}
        - name: tmp
          emptyDir: {}
EOF

${K} -n "${NS}" wait --for=condition=complete "job/${job}" --timeout=3600s
${K} -n "${NS}" logs "job/${job}" --tail=200

echo "[garage-convert-db] conversion completed." >&2
echo "[garage-convert-db] next steps:" >&2
echo "  - apply GitOps change: set db_engine=lmdb + lmdb_map_size in ${NS} config" >&2
echo "  - scale ${NS}/${STS} back to 1 (or let Argo apply)" >&2
