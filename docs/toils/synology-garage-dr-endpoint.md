# Toil: Synology-hosted Garage as DR S3 replication target

Goal: run an off-cluster, S3-compatible DR endpoint on the Synology NAS and use it as the `backup-system` S3 replication destination (`backup.s3Mirror.mode=s3-replication`).

This keeps S3 backup payload **out of the NFS filesystem** (markers only), avoiding the “hundreds of thousands of tiny files on btrfs” failure mode.

## Assumptions

- Synology NAS is reachable at `198.51.100.11` (SSH as `root` works).
- DSM 7.x with ContainerManager / Docker engine available (`/usr/local/bin/docker`).
- We use Garage image `docker.io/dxflrs/garage:v2.1.0` (same as the in-cluster Garage component).

## Ports and paths

- S3 API: `198.51.100.11:3900` (HTTP)
- Garage RPC: `198.51.100.11:3901`
- Admin API: `198.51.100.11:3903` (HTTP)

Host paths:
- Config: `/volume1/deploykube/garage-dr/config/garage.toml`
- Data: `/volume1/deploykube/garage-dr/data` (includes `meta/` + `data/`)

## 1) Create config + start container (Synology)

Run on the operator machine:

```bash
ssh root@198.51.100.11 <<'EOF'
set -euo pipefail

base=/volume1/deploykube/garage-dr
mkdir -p "$base/config" "$base/data/meta" "$base/data/data"
chmod 700 "$base" "$base/config" || true

envfile="$base/config/garage.env"
repfile="$base/config/replication.env"

umask 077
if [ ! -f "$envfile" ]; then
  rpc_secret="$(openssl rand -hex 32)"
  admin_token="$(openssl rand -hex 32)"
  metrics_token="$(openssl rand -hex 32)"
  cat >"$envfile" <<EOT
GARAGE_RPC_SECRET=$rpc_secret
GARAGE_ADMIN_TOKEN=$admin_token
GARAGE_METRICS_TOKEN=$metrics_token
S3_REGION=us-east-1
EOT
fi

if [ ! -f "$repfile" ]; then
  access_hex="$(openssl rand -hex 12)"
  secret_hex="$(openssl rand -hex 32)"
  cat >"$repfile" <<EOT
S3_ACCESS_KEY=GK$access_hex
S3_SECRET_KEY=$secret_hex
EOT
fi. "$envfile"
cat >"$base/config/garage.toml" <<EOT
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"
lmdb_map_size = "64G"
replication_factor = 1
rpc_bind_addr = "0.0.0.0:3901"
rpc_public_addr = "198.51.100.11:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
s3_region = "${S3_REGION}"
api_bind_addr = "0.0.0.0:3900"
root_domain = ""

[admin]
api_bind_addr = "0.0.0.0:3903"
admin_token = "${GARAGE_ADMIN_TOKEN}"
metrics_token = "${GARAGE_METRICS_TOKEN}"
EOT

chmod 600 "$envfile" "$repfile" "$base/config/garage.toml"

img=docker.io/dxflrs/garage:v2.1.0
name=garage-dr
/usr/local/bin/docker pull "$img" >/dev/null
if /usr/local/bin/docker ps -a --format "{{.Names}}" | grep -qx "$name"; then
  /usr/local/bin/docker rm -f "$name" >/dev/null || true
fi
/usr/local/bin/docker run -d --name "$name" --restart unless-stopped \
  -p 3900:3900 -p 3901:3901 -p 3903:3903 \
  -v "$base/config/garage.toml":/config/garage.toml:ro \
  -v "$base/data":/var/lib/garage \
  "$img" /garage -c /config/garage.toml server >/dev/null

/usr/local/bin/docker ps --filter "name=^/${name}$" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
EOF
```

## 2) Bootstrap layout + replication key + destination bucket (Synology)

Creates a single destination bucket `deploykube-dr` and grants the replication key owner read/write.

```bash
ssh root@198.51.100.11 <<'EOF'
set -euo pipefail
base=/volume1/deploykube/garage-dr. "$base/config/garage.env". "$base/config/replication.env"
export GARAGE_ADMIN_TOKEN S3_ACCESS_KEY S3_SECRET_KEY

python3 - <<'PY'
import json, os, time, urllib.error, urllib.parse, urllib.request

admin_endpoint = "http://127.0.0.1:3903"
admin_token = os.environ["GARAGE_ADMIN_TOKEN"]
access_key = os.environ["S3_ACCESS_KEY"]
secret_key = os.environ["S3_SECRET_KEY"]
bucket = "deploykube-dr"

def req(method, url, payload=None, timeout=10):
  body = b"" if payload is None else json.dumps(payload).encode("utf-8")
  headers = {"Authorization": f"Bearer {admin_token}"}
  if payload is not None:
    headers["Content-Type"] = "application/json"
  r = urllib.request.Request(url, method=method, data=(body if payload is not None else None), headers=headers)
  try:
    with urllib.request.urlopen(r, timeout=timeout) as resp:
      return resp.status, resp.read
  except urllib.error.HTTPError as e:
    return e.code, e.read

def get(path):
  st, data = req("GET", admin_endpoint + path, None)
  if st != 200:
    raise RuntimeError((path, st, data[:200]))
  return json.loads(data.decode("utf-8"))

def post(path, payload):
  st, data = req("POST", admin_endpoint + path, payload)
  if st != 200:
    raise RuntimeError((path, st, data[:200]))
  return json.loads(data.decode("utf-8")) if data else {}

def retry(fn, attempts=60, sleep_s=1):
  last = None
  for _ in range(attempts):
    try:
      return fn
    except Exception as e:
      last = e
      time.sleep(sleep_s)
  raise last

status = retry(lambda: get("/v2/GetClusterStatus"), attempts=120, sleep_s=1)
nodes = status.get("nodes") or []
up = [n for n in nodes if n.get("isUp") is True and n.get("id")]
if not up:
  raise SystemExit("no live garage nodes")
node_id = up[0]["id"]

layout = retry(lambda: get("/v2/GetClusterLayout"), attempts=30, sleep_s=1)
roles = layout.get("roles") or []
staged = layout.get("stagedRoleChanges") or []
has_role = any(node_id.startswith((r.get("id") or "")) for r in roles)
if not has_role and not staged:
  post("/v2/UpdateClusterLayout", {"roles": [{"id": node_id, "zone": "default", "capacity": 500_000_000_000, "tags": []}]})
layout2 = retry(lambda: get("/v2/GetClusterLayout"), attempts=30, sleep_s=1)
if layout2.get("stagedRoleChanges"):
  post("/v2/ApplyClusterLayout", {"version": int(layout2.get("version", 0)) + 1})

retry(lambda: (lambda h: h if h.get("status") in ("healthy","degraded") else (_ for _ in ).throw(RuntimeError(h)))(get("/v2/GetClusterHealth")), attempts=120, sleep_s=1)

def get_key:
  st, data = req("GET", admin_endpoint + "/v2/GetKeyInfo?" + urllib.parse.urlencode({"id": access_key}), None)
  if st != 200:
    return None
  try:
    return json.loads(data.decode("utf-8"))
  except Exception:
    return None

key_info = get_key or {}
if not key_info.get("accessKeyId"):
  post("/v2/ImportKey", {"accessKeyId": access_key, "secretAccessKey": secret_key, "name": "deploykube-dr-replication"})

items = get("/v2/ListBuckets")
bucket_id = None
for it in items:
  for ga in it.get("globalAliases") or []:
    if ga == bucket:
      bucket_id = it.get("id")
if not bucket_id:
  post("/v2/CreateBucket", {"globalAlias": bucket})
  items = get("/v2/ListBuckets")
  for it in items:
    for ga in it.get("globalAliases") or []:
      if ga == bucket:
        bucket_id = it.get("id")
if not bucket_id:
  raise SystemExit("bucket not created")

post("/v2/AllowBucketKey", {"bucketId": bucket_id, "accessKeyId": access_key, "permissions": {"read": True, "write": True, "owner": True}})
print("[garage-dr] bootstrap ok")
PY
EOF
```

## 3) Wire DeployKube to use the DR endpoint

DeploymentConfig (example for `proxmox-talos`):
- `spec.backup.s3Mirror.mode: s3-replication`
- `spec.backup.s3Mirror.replication.destination.endpoint: http://198.51.100.11:3900`
- `spec.backup.s3Mirror.replication.destination.region: us-east-1`
- `spec.backup.s3Mirror.replication.destination.bucket: deploykube-dr`
- `spec.backup.s3Mirror.replication.destination.prefix: proxmox-talos/`

Vault secret for replication target credentials:
- Path: `secret/backup/s3-replication-target`
- Keys: `S3_ACCESS_KEY`, `S3_SECRET_KEY`

Operational note: the `ExternalSecret` refresh interval is `1h`. After updating Vault, either wait or force a quick sync by deleting the materialized Secret:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n backup-system delete secret backup-system-s3-replication-target
```

## 4) Verify end-to-end

Trigger a manual replication run:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
kubectl -n backup-system create job --from=cronjob/storage-s3-mirror-to-backup-target \
  "s3-mirror-manual-$(date -u +%Y%m%d%H%M%S)"
```

Check NFS marker freshness (payload should not be written to the NFS tree in `mode=s3-replication`):

```bash
ssh root@198.51.100.11 'cat /volume1/deploykube/backups/proxmox-talos/s3-mirror/LATEST.json'
```

