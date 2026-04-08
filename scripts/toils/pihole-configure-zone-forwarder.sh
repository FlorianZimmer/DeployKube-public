#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

DEPLOYMENT_ID=""
PIHOLE_HOST=""
PIHOLE_PASSWORD_ENV="${PIHOLE_PASSWORD_ENV:-PIHOLE_PASSWORD}"
INSECURE_TLS="${INSECURE_TLS:-true}"

usage() {
  cat <<'USAGE'
Usage:
  PIHOLE_PASSWORD=... ./scripts/toils/pihole-configure-zone-forwarder.sh --deployment-id <id> [--pihole-host <ip-or-host>]

What it does:
  - Reads DeploymentConfig from platform/gitops/deployments/<id>/config.yaml
  - Ensures Pi-hole forwards the deployment DNS zone to the in-cluster PowerDNS VIP by adding a dnsmasq line:
      server=/<baseDomain>/<powerdnsIP>
  - Removes stale forwarders for the same zone (server=/<baseDomain>/...)
  - Restarts Pi-hole DNS (FTL)

Auth:
  - Uses Pi-hole API v6: POST /api/auth (password) -> session SID
  - Subsequent calls authenticate using header: X-FTL-SID: <sid>

Notes:
  - Password must be provided via env var (default: PIHOLE_PASSWORD). You can override the env var name via PIHOLE_PASSWORD_ENV.
  - By default uses TLS with curl -k (set INSECURE_TLS=false to require valid TLS).
USAGE
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --pihole-host) PIHOLE_HOST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" ]]; then
  echo "missing --deployment-id" >&2
  usage >&2
  exit 1
fi

require yq
require jq
require python3
require curl

CONFIG_FILE="platform/gitops/deployments/${DEPLOYMENT_ID}/config.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "deployment config missing: ${CONFIG_FILE}" >&2
  exit 1
fi

base_domain="$(yq -r '.spec.dns.baseDomain // ""' "${CONFIG_FILE}")"
powerdns_ip="$(yq -r '.spec.network.vip.powerdnsIP // ""' "${CONFIG_FILE}")"
if [[ -z "${base_domain}" || -z "${powerdns_ip}" ]]; then
  echo "missing .spec.dns.baseDomain or .spec.network.vip.powerdnsIP in ${CONFIG_FILE}" >&2
  exit 1
fi

if [[ -z "${PIHOLE_HOST}" ]]; then
  PIHOLE_HOST="$(yq -r '.spec.dns.operatorDnsServers[0] // ""' "${CONFIG_FILE}" 2>/dev/null || true)"
fi
if [[ -z "${PIHOLE_HOST}" ]]; then
  echo "missing --pihole-host and DeploymentConfig has no spec.dns.operatorDnsServers[0] (${CONFIG_FILE})" >&2
  exit 1
fi

password="${!PIHOLE_PASSWORD_ENV:-}"
if [[ -z "${password}" ]]; then
  echo "missing Pi-hole password env var: ${PIHOLE_PASSWORD_ENV}" >&2
  exit 1
fi

scheme="https"
curl_tls_flags=()
if [[ "${INSECURE_TLS}" == "true" ]]; then
  curl_tls_flags+=(-k)
fi

api_base="${scheme}://${PIHOLE_HOST}/api"
wanted_line="server=/${base_domain}/${powerdns_ip}"

urlencode() {
  python3 - <<'PY' "$1"
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

echo "[pihole-forwarder] deploymentId=${DEPLOYMENT_ID}"
echo "[pihole-forwarder] pihole=${PIHOLE_HOST}"
echo "[pihole-forwarder] zone=${base_domain}"
echo "[pihole-forwarder] target_powerdns_ip=${powerdns_ip}"
echo "[pihole-forwarder] wanted_dnsmasq_line=${wanted_line}"

login_json="$(
  curl -sS "${curl_tls_flags[@]}" \
    -H 'Content-Type: application/json' \
    -X POST "${api_base}/auth" \
    -d "$(jq -cn --arg p "${password}" '{password:$p}')"
)"

sid="$(printf '%s\n' "${login_json}" | jq -r '.session.sid // ""')"
valid="$(printf '%s\n' "${login_json}" | jq -r '.session.valid // false')"
if [[ "${valid}" != "true" || -z "${sid}" ]]; then
  msg="$(printf '%s\n' "${login_json}" | jq -r '.session.message // "login failed"')"
  echo "[pihole-forwarder] FAIL: login failed (${msg})" >&2
  exit 1
fi

auth_hdr=(-H "X-FTL-SID: ${sid}")

config_json="$(
  curl -sS "${curl_tls_flags[@]}" "${auth_hdr[@]}" \
    "${api_base}/config?detailed=false"
)"

mapfile -t existing_lines < <(
  printf '%s\n' "${config_json}" \
    | jq -r '.config.misc.dnsmasq_lines[]?'
)

stale=()
for l in "${existing_lines[@]:-}"; do
  [[ -n "${l}" ]] || continue
  if [[ "${l}" == "server=/${base_domain}/"* && "${l}" != "${wanted_line}" ]]; then
    stale+=("${l}")
  fi
done

restart_query="restart=false"

for l in "${stale[@]:-}"; do
  enc="$(urlencode "${l}")"
  echo "[pihole-forwarder] removing stale: ${l}"
  curl -sS "${curl_tls_flags[@]}" "${auth_hdr[@]}" \
    -X DELETE "${api_base}/config/misc/dnsmasq_lines/${enc}?${restart_query}" >/dev/null
done

present=0
for l in "${existing_lines[@]:-}"; do
  if [[ "${l}" == "${wanted_line}" ]]; then
    present=1
    break
  fi
done

if [[ "${present}" -eq 0 ]]; then
  enc="$(urlencode "${wanted_line}")"
  echo "[pihole-forwarder] adding: ${wanted_line}"
  curl -sS "${curl_tls_flags[@]}" "${auth_hdr[@]}" \
    -X PUT "${api_base}/config/misc/dnsmasq_lines/${enc}?${restart_query}" >/dev/null
else
  echo "[pihole-forwarder] wanted line already present"
fi

echo "[pihole-forwarder] restarting DNS (FTL)"
curl -sS "${curl_tls_flags[@]}" "${auth_hdr[@]}" \
  -X POST "${api_base}/action/restartdns" >/dev/null

if command -v dig >/dev/null 2>&1; then
  echo "[pihole-forwarder] validating resolution via Pi-hole (dig)"
  if ! dig +time=2 +tries=1 @"${PIHOLE_HOST}" "ns1.${base_domain}" A +short >/dev/null 2>&1; then
    echo "[pihole-forwarder] WARN: dig failed; check Pi-hole logs and dnsmasq_lines" >&2
  else
    echo "[pihole-forwarder] OK"
  fi
else
  echo "[pihole-forwarder] skipping validation (dig not found)"
fi

echo "[pihole-forwarder] done"
