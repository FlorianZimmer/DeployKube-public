#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./scripts/toils/tenant-offboarding/delete-garage-tenant-s3.sh --org-id <orgId> [--garage-namespace <ns>] [--out <file>] [--apply --confirm <orgId>]

Deletes tenant-scoped Garage buckets + keys for an orgId using the Garage admin API.

Scope (v1):
- Buckets with a global alias prefix: `tenant-<orgId>-`
- Keys with name prefix: `tenant-<orgId>-`

Safety:
- Default is dry-run (the Job prints what it would delete).
- --apply requires --confirm <orgId> to match.
- Deletion is executed inside the cluster as a Job (logs are evidence-friendly).

Prereqs:
- Garage is installed and exposes the admin API at `garage.garage.svc:3903` in-cluster.
- `Secret/garage/garage-credentials` contains `GARAGE_ADMIN_TOKEN`.
- `Secret/garage/garage-s3` contains the platform S3 key material (`S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_REGION`).
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
check_dependency python3

org_id=""
garage_namespace="garage"
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
    --garage-namespace)
      garage_namespace="${2:-}"
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
  tools_image="$(kubectl -n "${garage_namespace}" get cronjob garage-tenant-s3-provisioner -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
fi
if [[ -z "${tools_image}" ]]; then
  tools_image="registry.example.internal/deploykube/bootstrap-tools:1.4"
  echo "WARN: failed to discover bootstrap-tools image from CronJob/garage-tenant-s3-provisioner; falling back to ${tools_image}" >&2
fi

run_id="$(date -u +%y%m%d%H%M%S)"
job_name="$(python3 - "${run_id}" "${org_id}" <<'PY'
import hashlib
import sys

run_id = sys.argv[1]
org = sys.argv[2]
h = hashlib.sha256(f"{org}:{run_id}".encode("utf-8")).hexdigest()[:8]
print(f"garage-tenant-s3-offboard-{run_id}-{h}")
PY
)"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}" || true; }
trap cleanup EXIT INT TERM

job_yaml="${tmpdir}/job.yaml"
cat >"${job_yaml}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${garage_namespace}
  labels:
    app.kubernetes.io/name: garage
    app.kubernetes.io/component: tenant-s3-offboard
    darksite.cloud/tenant-id: ${org_id}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  ttlSecondsAfterFinished: 21600
  template:
    metadata:
      annotations:
        sidecar.istio.io/nativeSidecar: "true"
    spec:
      restartPolicy: Never
      containers:
        - name: offboard
          image: ${tools_image}
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: garage-credentials
            - secretRef:
                name: garage-s3
          env:
            - name: APPLY
              value: "${apply}"
            - name: ORG_ID
              value: "${org_id}"
            - name: GARAGE_ADMIN_ENDPOINT
              value: "http://garage.garage.svc:3903"
            - name: GARAGE_S3_ENDPOINT
              value: "http://garage.garage.svc:3900"
            - name: PLATFORM_S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: garage-s3
                  key: S3_ACCESS_KEY
            - name: PLATFORM_S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: garage-s3
                  key: S3_SECRET_KEY
            - name: GARAGE_S3_REGION
              valueFrom:
                secretKeyRef:
                  name: garage-s3
                  key: S3_REGION
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail

              ISTIO_HELPER="/helpers/istio-native-exit.sh"
              [ -f "/helpers/istio-native-exit.sh" ] || { echo "missing istio-native-exit helper" >&2; exit 1; }
              . "/helpers/istio-native-exit.sh"
              trap deploykube_istio_quit_sidecar EXIT INT TERM

              python3 - <<'PY'
              import json
              import os
              import subprocess
              import time
              import urllib.error
              import urllib.parse
              import urllib.request

              apply = os.environ.get("APPLY", "false").strip().lower() == "true"
              org_id = os.environ.get("ORG_ID", "").strip()
              if not org_id:
                raise SystemExit("missing ORG_ID")

              garage_admin_endpoint = os.environ.get("GARAGE_ADMIN_ENDPOINT", "http://garage.garage.svc:3903").strip()
              garage_s3_endpoint = os.environ.get("GARAGE_S3_ENDPOINT", "http://garage.garage.svc:3900").strip()
              garage_s3_region = os.environ.get("GARAGE_S3_REGION", "us-east-1").strip()

              admin_token = os.environ.get("GARAGE_ADMIN_TOKEN", "").strip()
              if not admin_token:
                raise SystemExit("missing GARAGE_ADMIN_TOKEN (expected from Secret/garage-credentials)")

              platform_access = os.environ.get("PLATFORM_S3_ACCESS_KEY", "").strip()
              platform_secret = os.environ.get("PLATFORM_S3_SECRET_KEY", "").strip()
              if not platform_access or not platform_secret:
                raise SystemExit("missing PLATFORM_S3_ACCESS_KEY/PLATFORM_S3_SECRET_KEY (expected from Secret/garage-s3)")

              prefix_bucket = f"tenant-{org_id}-"
              prefix_key = f"tenant-{org_id}-"

              def _json_request(method, url, payload=None, timeout=15):
                body = b"" if payload is None else json.dumps(payload).encode("utf-8")
                headers = {"Authorization": f"Bearer {admin_token}"}
                if payload is not None:
                  headers["Content-Type"] = "application/json"
                req = urllib.request.Request(url, method=method, data=(body if payload is not None else None), headers=headers)
                try:
                  with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return resp.status, resp.read()
                except urllib.error.HTTPError as e:
                  return e.code, e.read()
                except Exception as e:
                  return 0, str(e).encode("utf-8", errors="replace")

              def _admin_get(path):
                url = garage_admin_endpoint.rstrip("/") + path
                st, data = _json_request("GET", url, payload=None, timeout=15)
                if st != 200:
                  raise RuntimeError(f"admin GET {path} failed: status={st} err={data[:300]!r}")
                return json.loads(data.decode("utf-8"))

              def _admin_post(path, payload=None):
                url = garage_admin_endpoint.rstrip("/") + path
                st, data = _json_request("POST", url, payload=payload, timeout=30)
                if st != 200:
                  raise RuntimeError(f"admin POST {path} failed: status={st} err={data[:300]!r}")
                return json.loads(data.decode("utf-8")) if data else {}

              def _retry(fn, what, attempts=60, sleep_s=3):
                last = None
                for _ in range(attempts):
                  try:
                    return fn()
                  except Exception as e:
                    last = e
                    time.sleep(sleep_s)
                raise RuntimeError(f"{what} failed after {attempts} attempts: {last}")

              print(f"[offboard] orgId={org_id} apply={apply}", flush=True)
              print(f"[offboard] waiting for Garage admin API ({garage_admin_endpoint})...", flush=True)
              _retry(lambda: _admin_get("/v2/GetClusterHealth"), "GetClusterHealth", attempts=60, sleep_s=5)

              buckets = _admin_get("/v2/ListBuckets")
              to_delete_buckets = []
              for b in buckets:
                bid = b.get("id")
                aliases = b.get("globalAliases") or []
                alias = next((a for a in aliases if isinstance(a, str) and a.startswith(prefix_bucket)), None)
                if bid and alias:
                  to_delete_buckets.append((bid, alias))
              to_delete_buckets.sort(key=lambda x: x[1])

              keys = _admin_get("/v2/ListKeys")
              to_delete_keys = []
              for k in keys:
                kid = k.get("accessKeyId") or k.get("id")
                name = (k.get("name") or "").strip()
                if kid and name.startswith(prefix_key):
                  to_delete_keys.append((kid, name))
              to_delete_keys.sort(key=lambda x: x[1])

              print(f"[offboard] buckets matching '{prefix_bucket}*': {len(to_delete_buckets)}", flush=True)
              for bid, alias in to_delete_buckets:
                print(f"[offboard] bucket: {alias} (id={bid})", flush=True)
              print(f"[offboard] keys matching name '{prefix_key}*': {len(to_delete_keys)}", flush=True)
              for kid, name in to_delete_keys:
                print(f"[offboard] key: {name} (id={kid})", flush=True)

              if not apply:
                print("[offboard] dry-run only; exiting", flush=True)
                raise SystemExit(0)

              # Prepare rclone config using the platform key material.
              rclone_conf = "/tmp/rclone.conf"
              with open(rclone_conf, "w", encoding="utf-8") as f:
                f.write(
                  "\n".join(
                    [
                      "[garage]",
                      "type = s3",
                      "provider = Other",
                      "env_auth = false",
                      f"access_key_id = {platform_access}",
                      f"secret_access_key = {platform_secret}",
                      f"endpoint = {garage_s3_endpoint}",
                      f"region = {garage_s3_region}",
                      "force_path_style = true",
                      "",
                    ]
                  )
                )

              # Ensure the platform key has owner rights so it can delete objects/buckets.
              for bid, alias in to_delete_buckets:
                _admin_post(
                  "/v2/AllowBucketKey",
                  {"bucketId": bid, "accessKeyId": platform_access, "permissions": {"read": True, "write": True, "owner": True}},
                )
                print(f"[offboard] ensured platform delete rights for bucket={alias}", flush=True)

              # Purge buckets (objects + bucket).
              for bid, alias in to_delete_buckets:
                print(f"[offboard] purging bucket via S3: {alias}", flush=True)
                subprocess.check_call(["rclone", "--config", rclone_conf, "purge", f"garage:{alias}"])
                # Best-effort: ensure bucket object is gone from the admin view as well.
                try:
                  _admin_post("/v2/DeleteBucket?" + urllib.parse.urlencode({"id": bid}))
                  print(f"[offboard] deleted bucket via admin API: {alias}", flush=True)
                except Exception as e:
                  print(f"[offboard] WARN: DeleteBucket failed for {alias}: {e}", flush=True)

              # Delete keys last.
              for kid, name in to_delete_keys:
                _admin_post("/v2/DeleteKey?" + urllib.parse.urlencode({"id": kid}))
                print(f"[offboard] deleted key: {name} (id={kid})", flush=True)

              print("[offboard] OK", flush=True)
              PY
          volumeMounts:
            - name: istio-native-exit
              mountPath: /helpers
              readOnly: true
      volumes:
        - name: istio-native-exit
          configMap:
            name: istio-native-exit-script
            defaultMode: 0444
EOF

if [[ -n "${out_path}" ]]; then
  cp "${job_yaml}" "${out_path}"
  echo "wrote: ${out_path}"
else
  cat "${job_yaml}"
fi

if [[ "${apply}" != "true" ]]; then
  echo ""
  echo "DRY-RUN: pass --apply --confirm ${org_id} to create the Job"
  exit 0
fi

echo ""
echo "==> Applying Job/${job_name} in namespace ${garage_namespace}"
kubectl -n "${garage_namespace}" apply -f "${job_yaml}"
kubectl -n "${garage_namespace}" wait --for=condition=complete "job/${job_name}" --timeout=90m
kubectl -n "${garage_namespace}" logs "job/${job_name}" --all-containers --tail=200 || true

echo ""
echo "OK: Garage tenant S3 offboarding job completed"
