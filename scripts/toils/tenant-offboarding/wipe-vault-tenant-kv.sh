#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./scripts/toils/tenant-offboarding/wipe-vault-tenant-kv.sh --org-id <orgId> [--mount <kvMount>] [--prefix <pathPrefix>] [--apply --confirm <orgId>]

Recursively deletes Vault KV v2 metadata (permanent key deletion) under:
  <mount>/metadata/<prefix>/<orgId>/

Defaults:
  mount:  secret
  prefix: tenants

This implements the offboarding contract described in:
  docs/design/multitenancy-secrets-and-vault.md#9-offboarding-and-wipe-semantics

Required environment:
  VAULT_ADDR   Vault base URL (example: https://vault.example)
  VAULT_TOKEN  Vault token with permission to list + metadata delete under the tenant prefix

Safety:
- Default is dry-run (prints which keys would be deleted).
- --apply requires --confirm <orgId> to match.
EOF
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency python3

org_id=""
mount="secret"
prefix="tenants"
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
    --mount)
      mount="${2:-}"
      shift 2
      ;;
    --prefix)
      prefix="${2:-}"
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

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "error: VAULT_ADDR is required" >&2
  exit 2
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "error: VAULT_TOKEN is required" >&2
  exit 2
fi

python3 - "${VAULT_ADDR}" "${VAULT_TOKEN}" "${mount}" "${prefix}" "${org_id}" "${apply}" <<'PY'
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

vault_addr = sys.argv[1].rstrip("/")
vault_token = sys.argv[2]
mount = sys.argv[3].strip().strip("/")
prefix = sys.argv[4].strip().strip("/")
org_id = sys.argv[5].strip()
apply = sys.argv[6].strip().lower() == "true"

base_path = f"{prefix}/{org_id}".strip("/")


def _request(method: str, path: str, *, query: dict[str, str] | None = None) -> tuple[int, bytes]:
    url = vault_addr + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(
        url,
        method=method,
        headers={"X-Vault-Token": vault_token},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def list_keys(path: str) -> list[str]:
    st, data = _request("GET", f"/v1/{mount}/metadata/{path}", query={"list": "true"})
    if st == 404:
        return []
    if st != 200:
        raise RuntimeError(f"list failed: {path} status={st} err={data[:300]!r}")
    doc = json.loads(data.decode("utf-8"))
    keys = ((doc.get("data") or {}).get("keys") or [])
    if not isinstance(keys, list):
        raise RuntimeError(f"unexpected list response for {path}: {doc}")
    return [str(k) for k in keys]


def delete_metadata(path: str) -> None:
    st, data = _request("DELETE", f"/v1/{mount}/metadata/{path}")
    if st not in (200, 204, 404):
        raise RuntimeError(f"delete failed: {path} status={st} err={data[:300]!r}")


def walk(path: str) -> list[str]:
    out: list[str] = []
    for k in list_keys(path):
        if k.endswith("/"):
            out.extend(walk(f"{path}/{k[:-1]}".strip("/")))
        else:
            out.append(f"{path}/{k}".strip("/"))
    return out


keys = walk(base_path)
keys = sorted(set(keys))

print(f"==> Vault KV v2 tenant wipe plan")
print(f"- VAULT_ADDR: {vault_addr}")
print(f"- mount: {mount}")
print(f"- base: {base_path}")
print(f"- keys: {len(keys)}")
print("")

if not keys:
    print("info: no keys found (nothing to delete)")
    raise SystemExit(0)

for k in keys:
    print(k)

if not apply:
    print("")
    print("DRY-RUN: pass --apply --confirm to delete metadata for the keys above.")
    raise SystemExit(0)

print("")
print("==> Deleting KV v2 metadata (permanent)")
for k in keys:
    delete_metadata(k)
    print(f"deleted: {k}")

print("")
print("OK: tenant KV metadata wipe completed")
PY

