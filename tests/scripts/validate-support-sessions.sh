#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

tenant_root="platform/gitops/tenants"

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency yq
check_dependency kustomize
check_dependency python3

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

validate_dns_label() {
  local label="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    fail "${label}: missing"
    return 1
  fi
  if [[ "${#value}" -gt 63 ]]; then
    fail "${label}: too long (>63): ${value}"
    return 1
  fi
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    fail "${label}: must be DNS-label-safe ([a-z0-9-], start/end alnum): ${value}"
    return 1
  fi
  return 0
}

max_ttl_hours="${DK_SUPPORT_SESSION_MAX_TTL_HOURS:-72}"
if ! [[ "${max_ttl_hours}" =~ ^[0-9]+$ ]]; then
  echo "error: DK_SUPPORT_SESSION_MAX_TTL_HOURS must be an integer (got: ${max_ttl_hours})" >&2
  exit 2
fi

echo "==> Validating support sessions (folder contract + TTL gate)"

if [[ ! -d "${tenant_root}" ]]; then
  echo "error: missing tenant root: ${tenant_root}" >&2
  exit 1
fi

mapfile -t session_metas < <(
  find "${tenant_root}" -mindepth 4 -maxdepth 4 -type f -name metadata.yaml \
    -path "${tenant_root}/*/support-sessions/*/metadata.yaml" \
    -not -path "${tenant_root}/_templates/*" \
    -not -path "${tenant_root}/.*/**" \
    | sort
)

if [[ "${#session_metas[@]}" -eq 0 ]]; then
  echo "info: no support sessions found under ${tenant_root} (ok)"
  exit 0
fi

now_epoch="$(python3 - <<'PY'
import datetime
print(int(datetime.datetime.now(datetime.timezone.utc).timestamp()))
PY
)"

for meta in "${session_metas[@]}"; do
  session_dir="$(dirname "${meta}")"
  session_id="$(basename "${session_dir}")"
  org_dir="$(dirname "$(dirname "${session_dir}")")"
  org_id_path="$(basename "${org_dir}")"

  echo ""
  echo "==> ${org_id_path}/${session_id}"

  validate_dns_label "orgId folder" "${org_id_path}" || true
  validate_dns_label "sessionId folder" "${session_id}" || true

  kind="$(yq -r '.kind // ""' "${meta}" 2>/dev/null || true)"
  api_version="$(yq -r '.apiVersion // ""' "${meta}" 2>/dev/null || true)"
  org_id_meta="$(yq -r '.orgId // ""' "${meta}" 2>/dev/null || true)"
  level="$(yq -r '.level // ""' "${meta}" 2>/dev/null || true)"
  expires_at="$(yq -r '.expiresAt // ""' "${meta}" 2>/dev/null || true)"
  requested_by="$(yq -r '.requestedBy // ""' "${meta}" 2>/dev/null || true)"
  reason="$(yq -r '.reason // ""' "${meta}" 2>/dev/null || true)"

  if [[ "${kind}" != "SupportSession" ]]; then
    fail "${org_id_path}/${session_id}: metadata.kind='${kind}' (expected SupportSession)"
  fi
  if [[ -z "${api_version}" ]]; then
    fail "${org_id_path}/${session_id}: metadata.apiVersion is missing"
  fi
  if [[ "${org_id_meta}" != "${org_id_path}" ]]; then
    fail "${org_id_path}/${session_id}: metadata.orgId='${org_id_meta}' (expected ${org_id_path})"
  fi
  case "${level}" in
    L1|L2|L3) ;;
    *)
      fail "${org_id_path}/${session_id}: metadata.level='${level}' (expected L1|L2|L3)"
      ;;
  esac
  if [[ -z "${expires_at}" ]]; then
    fail "${org_id_path}/${session_id}: metadata.expiresAt is missing"
  fi
  if [[ -z "${requested_by}" ]]; then
    fail "${org_id_path}/${session_id}: metadata.requestedBy is missing"
  fi
  if [[ -z "${reason}" ]]; then
    fail "${org_id_path}/${session_id}: metadata.reason is missing"
  fi

  if [[ -n "${expires_at}" ]]; then
    if ! python3 - "${expires_at}" "${now_epoch}" "${max_ttl_hours}" <<'PY'
import datetime
import sys

raw = sys.argv[1]
now_epoch = int(sys.argv[2])
max_hours = int(sys.argv[3])

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
except Exception as e:
    print(f"invalid expiresAt '{raw}': {e}", file=sys.stderr)
    raise SystemExit(1)

expires_epoch = int(expires.timestamp())
max_epoch = now_epoch + max_hours * 3600

if expires_epoch <= now_epoch:
    print(f"expiresAt '{raw}' is expired (now={datetime.datetime.fromtimestamp(now_epoch, datetime.timezone.utc).isoformat()})", file=sys.stderr)
    raise SystemExit(1)

if expires_epoch > max_epoch:
    max_iso = datetime.datetime.fromtimestamp(max_epoch, datetime.timezone.utc).isoformat()
    print(f"expiresAt '{raw}' exceeds max TTL ({max_hours}h); must be <= {max_iso}", file=sys.stderr)
    raise SystemExit(1)
PY
    then
      fail "${org_id_path}/${session_id}: expiresAt TTL gate failed: ${expires_at}"
    fi
  fi

  kustomization="${session_dir}/kustomization.yaml"
  if [[ ! -f "${kustomization}" ]]; then
    fail "${org_id_path}/${session_id}: missing kustomization.yaml"
    continue
  fi

  if ! rendered="$(kustomize build "${session_dir}" 2>/dev/null)"; then
    fail "${org_id_path}/${session_id}: kustomize build failed: ${session_dir}"
    continue
  fi

  objects="$(
    printf '%s\n' "${rendered}" | yq eval -r '
      select(.kind != null) |
      [
        (.apiVersion // ""),
        (.kind // ""),
        (.metadata.name // ""),
        (.metadata.namespace // ""),
        (.metadata.labels."darksite.cloud/support-session-id" // ""),
        (.metadata.annotations."darksite.cloud/support-session-level" // ""),
        (.metadata.annotations."darksite.cloud/support-session-expires-at" // "")
      ] | @tsv
    ' - 2>/dev/null || true
  )"

  if [[ -z "${objects}" ]]; then
    fail "${org_id_path}/${session_id}: kustomize produced no objects (expected at least one namespaced resource)"
    continue
  fi

  while IFS=$'\t' read -r api kind name ns label_session ann_level ann_expires; do
    [[ -n "${kind}" ]] || continue

    case "${kind}" in
      Role|RoleBinding|NetworkPolicy) ;;
      *)
        fail "${org_id_path}/${session_id}: unsupported kind ${api}/${kind} (allowed: Role, RoleBinding, NetworkPolicy)"
        ;;
    esac

    if [[ -z "${ns}" ]]; then
      fail "${org_id_path}/${session_id}: ${kind}/${name} is cluster-scoped (support sessions must be namespaced)"
      continue
    fi

    if [[ "${ns}" != t-"${org_id_path}"-* ]]; then
      fail "${org_id_path}/${session_id}: ${kind}/${name} namespace='${ns}' (expected t-${org_id_path}-*)"
    fi

    if [[ "${label_session}" != "${session_id}" ]]; then
      fail "${org_id_path}/${session_id}: ${kind}/${name} darksite.cloud/support-session-id='${label_session}' (expected ${session_id})"
    fi

    if [[ "${kind}" == "RoleBinding" ]]; then
      if [[ "${ann_level}" != "${level}" ]]; then
        fail "${org_id_path}/${session_id}: RoleBinding/${name} support-session-level='${ann_level}' (expected ${level})"
      fi
      if [[ "${ann_expires}" != "${expires_at}" ]]; then
        fail "${org_id_path}/${session_id}: RoleBinding/${name} support-session-expires-at='${ann_expires}' (expected ${expires_at})"
      fi
    fi
  done <<<"${objects}"
done

echo ""
if [[ "${failures}" -ne 0 ]]; then
  echo "support session validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "support session validation PASSED"
