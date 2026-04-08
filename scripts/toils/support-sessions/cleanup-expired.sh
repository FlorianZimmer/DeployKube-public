#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${root_dir}"

tenant_root="platform/gitops/tenants"

usage() {
  cat <<'EOF'
Usage: ./scripts/toils/support-sessions/cleanup-expired.sh [--apply] [--now <rfc3339>]

Scans SupportSession folders under:
  platform/gitops/tenants/<orgId>/support-sessions/<sessionId>/

And removes expired sessions by:
  1) deleting references from tenant project kustomizations
  2) deleting the session folder

By default this is a dry-run (no files are modified). Pass --apply to write changes.

Options:
  --apply            Apply changes (destructive; edits files + deletes folders)
  --now <rfc3339>    Override "now" (UTC) for testing (example: 2026-01-21T12:00:00Z)
EOF
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency yq
check_dependency rg
check_dependency python3

apply="false"
now_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --apply)
      apply="true"
      shift
      ;;
    --now)
      now_override="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "${tenant_root}" ]]; then
  echo "error: missing tenant root: ${tenant_root}" >&2
  exit 1
fi

now_epoch="$(python3 - "${now_override}" <<'PY'
import datetime
import sys

raw = sys.argv[1].strip()

def parse_rfc3339(val: str) -> datetime.datetime:
    v = val.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(v)
    if dt.tzinfo is None:
        raise ValueError("timestamp must include timezone offset (or Z)")
    return dt.astimezone(datetime.timezone.utc)

if raw:
    now = parse_rfc3339(raw)
else:
    now = datetime.datetime.now(datetime.timezone.utc)

print(int(now.timestamp()))
PY
)"

mapfile -t session_metas < <(
  find "${tenant_root}" -mindepth 4 -maxdepth 4 -type f -name metadata.yaml \
    -path "${tenant_root}/*/support-sessions/*/metadata.yaml" \
    -not -path "${tenant_root}/_templates/*" \
    -not -path "${tenant_root}/.*/**" \
    | sort
)

if [[ "${#session_metas[@]}" -eq 0 ]]; then
  echo "info: no support sessions found under ${tenant_root} (nothing to do)"
  exit 0
fi

expired=()
declare -A session_expires=()

for meta in "${session_metas[@]}"; do
  session_dir="$(dirname "${meta}")"
  session_id="$(basename "${session_dir}")"
  org_dir="$(dirname "$(dirname "${session_dir}")")"
  org_id="$(basename "${org_dir}")"

  expires_at="$(yq -r '.expiresAt // ""' "${meta}" 2>/dev/null || true)"
  if [[ -z "${expires_at}" ]]; then
    echo "WARN: ${meta}: missing expiresAt; skipping (treat as manual cleanup)" >&2
    continue
  fi

  python3 - "${expires_at}" "${now_epoch}" <<'PY' >/dev/null 2>&1
import datetime
import sys

raw = sys.argv[1]
now_epoch = int(sys.argv[2])

def parse_rfc3339(val: str) -> datetime.datetime:
    v = val.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(v)
    if dt.tzinfo is None:
        raise ValueError("timestamp must include timezone offset (or Z)")
    return dt.astimezone(datetime.timezone.utc)

try:
    expires = parse_rfc3339(raw)
except Exception:
    raise SystemExit(2)

expires_epoch = int(expires.timestamp())
if expires_epoch <= now_epoch:
    raise SystemExit(0)  # expired
raise SystemExit(3)  # not expired
PY
  rc=$?
  case "${rc}" in
    0)
      key="${org_id}/${session_id}"
      expired+=("${key}")
      session_expires["${key}"]="${expires_at}"
      ;;
    3)
      ;;
    *)
      echo "WARN: ${meta}: invalid expiresAt '${expires_at}'; skipping (treat as manual cleanup)" >&2
      continue
      ;;
  esac
done

if [[ "${#expired[@]}" -eq 0 ]]; then
  echo "info: no expired support sessions found (now_epoch=${now_epoch})"
  exit 0
fi

echo "==> Expired support sessions (now_epoch=${now_epoch})"
for key in "${expired[@]}"; do
  echo "- ${key} expiresAt=${session_expires[${key}]}"
done

echo ""
if [[ "${apply}" != "true" ]]; then
  echo "DRY-RUN (pass --apply to modify files)"
else
  echo "APPLY MODE (editing files + deleting folders)"
fi

modified_files=0
deleted_sessions=0

for key in "${expired[@]}"; do
  org_id="${key%%/*}"
  session_id="${key#*/}"
  session_dir="${tenant_root}/${org_id}/support-sessions/${session_id}"

  echo ""
  echo "==> Cleanup ${key}"

  if [[ ! -d "${session_dir}" ]]; then
    echo "info: session dir already missing: ${session_dir}"
    continue
  fi

  # Remove kustomize references first so deleting the dir doesn't break builds.
  mapfile -t refs < <(
    rg -n --no-heading "support-sessions/${session_id}" "${tenant_root}/${org_id}" -g 'kustomization.yaml' 2>/dev/null \
      | cut -d: -f1 | sort -u
  )

  if [[ "${#refs[@]}" -eq 0 ]]; then
    echo "info: no kustomize references found for ${key}"
  else
    echo "references:"
    printf '  - %s\n' "${refs[@]}"
    if [[ "${apply}" == "true" ]]; then
      for f in "${refs[@]}"; do
        tmp="$(mktemp)"
        sed "\|support-sessions/${session_id}|d" "${f}" >"${tmp}"
        if ! cmp -s "${f}" "${tmp}"; then
          mv "${tmp}" "${f}"
          modified_files=$((modified_files + 1))
        else
          rm -f "${tmp}" || true
        fi
      done
    fi
  fi

  echo "session dir: ${session_dir}"
  if [[ "${apply}" == "true" ]]; then
    rm -rf "${session_dir}"
    deleted_sessions=$((deleted_sessions + 1))
  fi
done

echo ""
echo "==> Summary"
echo "- Modified files: ${modified_files}"
echo "- Deleted sessions: ${deleted_sessions}"

if [[ "${apply}" == "true" ]]; then
  echo ""
  echo "==> Post-check (support session validation)"
  ./tests/scripts/validate-support-sessions.sh
fi
