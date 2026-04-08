#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[dns-sync] %s\n' "$*"
}

POWERDNS_API_READY=false

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "missing required env var: ${name}"
    exit 1
  fi
}

JOB_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)

POWERDNS_API="${POWERDNS_API:-}"
POWERDNS_API_KEY="${POWERDNS_API_KEY:-}"
DNS_DOMAIN="${DNS_DOMAIN:-}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-istio-system}"
INGRESS_SERVICE="${INGRESS_SERVICE:-istio-ingressgateway}"
DNS_SYNC_HOSTS="${DNS_SYNC_HOSTS:-@ forgejo argocd keycloak vault}"
DNS_SYNC_ENABLE_WILDCARD="${DNS_SYNC_ENABLE_WILDCARD:-true}"
DNS_SYNC_TENANT_WILDCARDS="${DNS_SYNC_TENANT_WILDCARDS:-auto}"
DNS_SYNC_TENANT_WILDCARD_SUFFIX="${DNS_SYNC_TENANT_WILDCARD_SUFFIX:-workloads}"
DNS_SYNC_TENANT_WILDCARDS_EXCLUDE="${DNS_SYNC_TENANT_WILDCARDS_EXCLUDE:-cloud-dns-auto}"
DNS_SYNC_NS_HOST="${DNS_SYNC_NS_HOST:-ns1}"
DNS_AUTH_NS_HOSTS="${DNS_AUTH_NS_HOSTS:-}"
DNS_AUTH_NS_IP="${DNS_AUTH_NS_IP:-}"
DNS_SYNC_STATUS_CONFIGMAP="${DNS_SYNC_STATUS_CONFIGMAP:-dns-sync-status}"
DNS_SYNC_STATUS_NAMESPACE="${DNS_SYNC_STATUS_NAMESPACE:-${JOB_NAMESPACE}}"
DNS_SYNC_PUBLISH_TTL="${DNS_SYNC_PUBLISH_TTL:-300}"
DNS_SYNC_HOST_TTL="${DNS_SYNC_HOST_TTL:-60}"
DNS_SYNC_RETRIES="${DNS_SYNC_RETRIES:-60}"
DNS_SYNC_SLEEP="${DNS_SYNC_SLEEP:-5}"

require_env POWERDNS_API
require_env POWERDNS_API_KEY
require_env DNS_DOMAIN

powerdns_curl() {
  curl -fsS -H "X-API-Key: ${POWERDNS_API_KEY}" "$@"
}

ensure_powerdns_api() {
  if [[ "${POWERDNS_API_READY}" == "true" ]]; then
    return 0
  fi

  log "ensuring PowerDNS API is reachable at ${POWERDNS_API}"
  for ((i=1; i<=DNS_SYNC_RETRIES; i++)); do
    if powerdns_curl "${POWERDNS_API}/servers/localhost" >/dev/null; then
      POWERDNS_API_READY=true
      return 0
    fi
    if [[ $i -eq DNS_SYNC_RETRIES ]]; then
      log "PowerDNS API never became reachable"
      exit 1
    fi
    sleep "${DNS_SYNC_SLEEP}"
  done
}

authoritative_zone_matches_desired() {
  local zone_endpoint="$1"
  local zone_json
  zone_json="$(mktemp)"

  if ! powerdns_curl "${zone_endpoint}" >"${zone_json}"; then
    rm -f "${zone_json}"
    return 1
  fi

  if ! ZONE_JSON_PATH="${zone_json}" \
    ZONE_NAME="${ZONE_NAME}" \
    LB_IP="${LB_IP}" \
    DNS_SYNC_HOSTS="${DNS_SYNC_HOSTS}" \
    DNS_SYNC_ENABLE_WILDCARD="${DNS_SYNC_ENABLE_WILDCARD}" \
    DNS_SYNC_TENANT_WILDCARD_IPS="${DNS_SYNC_TENANT_WILDCARD_IPS}" \
    DNS_SYNC_TENANT_WILDCARD_SUFFIX="${DNS_SYNC_TENANT_WILDCARD_SUFFIX}" \
    DNS_AUTH_NS_HOSTS="${DNS_AUTH_NS_HOSTS}" \
    DNS_AUTH_NS_IP="${DNS_AUTH_NS_IP}" \
    python3 <<'PY'
import json
import os
import sys

def bool_env(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")

def ensure_fqdn(name):
    return name if name.endswith(".") else f"{name}."

zone = ensure_fqdn(os.environ["ZONE_NAME"])
ip = os.environ["LB_IP"].strip()
hosts = [h for h in os.environ["DNS_SYNC_HOSTS"].split() if h]
tenant_wildcard_ips = [p for p in os.environ.get("DNS_SYNC_TENANT_WILDCARD_IPS", "").split() if p]
tenant_wildcard_suffix = os.environ.get("DNS_SYNC_TENANT_WILDCARD_SUFFIX", "workloads")
ns_hosts = [h.rstrip(".") for h in os.environ.get("DNS_AUTH_NS_HOSTS", "").split() if h]
ns_ip = os.environ.get("DNS_AUTH_NS_IP", "").strip() or ip
if not ns_hosts:
    ns_hosts = [f"ns1.{zone.rstrip('.')}".rstrip(".")]
ns_host_fqdns = [ensure_fqdn(h) for h in ns_hosts]

with open(os.environ["ZONE_JSON_PATH"], "r", encoding="utf-8") as fh:
    zone_obj = json.load(fh)

actual = {}
for rrset in zone_obj.get("rrsets", []):
    key = (rrset.get("name"), rrset.get("type"))
    values = sorted(
        rec.get("content")
        for rec in rrset.get("records", [])
        if not rec.get("disabled", False)
    )
    actual[key] = values

desired = {}

def add(name, rrtype, values):
    desired[(ensure_fqdn(name), rrtype)] = sorted(values)

add(zone, "NS", ns_host_fqdns)
for ns_host_fqdn in ns_host_fqdns:
    add(ns_host_fqdn, "A", [ns_ip])

for host in hosts:
    if host == "@":
        name = zone
    else:
        name = f"{host}.{zone}"
    add(name, "A", [ip])

if bool_env("DNS_SYNC_ENABLE_WILDCARD", True):
    add(f"*.{zone}", "A", [ip])

for pair in tenant_wildcard_ips:
    tenant_id, tenant_ip = pair.split("=", 1)
    host = f"*.{tenant_id}.{tenant_wildcard_suffix}.{zone}"
    add(host, "A", [tenant_ip])

mismatches = []
for key, expected in desired.items():
    actual_values = actual.get(key, [])
    if actual_values != expected:
        mismatches.append(
            {
                "name": key[0],
                "type": key[1],
                "expected": expected,
                "actual": actual_values,
            }
        )

if mismatches:
    json.dump(mismatches, sys.stderr, separators=(",", ":"))
    sys.stderr.write("\n")
    sys.exit(1)
PY
  then
    rm -f "${zone_json}"
    return 1
  fi

  rm -f "${zone_json}"
  return 0
}

log "fetching ingress IP from ${INGRESS_NAMESPACE}/${INGRESS_SERVICE}"
LB_IP=""
for ((i=1; i<=DNS_SYNC_RETRIES; i++)); do
  LB_IP=$(kubectl -n "${INGRESS_NAMESPACE}" get svc "${INGRESS_SERVICE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${LB_IP}" ]]; then
    break
  fi
  sleep "${DNS_SYNC_SLEEP}"
done

if [[ -z "${LB_IP}" ]]; then
  log "could not determine LoadBalancer IP for ${INGRESS_NAMESPACE}/${INGRESS_SERVICE}"
  exit 1
fi

log "ingress LoadBalancer IP: ${LB_IP}"

if [[ -z "${DNS_AUTH_NS_HOSTS}" ]]; then
  DNS_AUTH_NS_HOSTS="${DNS_SYNC_NS_HOST}.${DNS_DOMAIN%.}"
fi

declare -a authority_ns_hosts=()
for raw_ns_host in ${DNS_AUTH_NS_HOSTS}; do
  ns_host="${raw_ns_host%.}"
  if [[ -n "${ns_host}" ]]; then
    authority_ns_hosts+=("${ns_host}")
  fi
done
if [[ ${#authority_ns_hosts[@]} -eq 0 ]]; then
  authority_ns_hosts=("ns1.${DNS_DOMAIN%.}")
fi
DNS_AUTH_NS_HOSTS="$(printf '%s ' "${authority_ns_hosts[@]}")"
DNS_AUTH_NS_HOSTS="${DNS_AUTH_NS_HOSTS% }"

if [[ -z "${DNS_AUTH_NS_IP}" ]]; then
  DNS_AUTH_NS_IP="${LB_IP}"
fi
log "authoritative nameservers: ${DNS_AUTH_NS_HOSTS} (A=${DNS_AUTH_NS_IP})"

if [[ "${DNS_SYNC_TENANT_WILDCARDS}" == "auto" ]]; then
  log "discovering tenant wildcards from Tenant API (tenancy.darksite.cloud/v1alpha1 Tenant)"
  discovered="$(
    kubectl get tenants.tenancy.darksite.cloud -o jsonpath='{range .items[*]}{.spec.orgId}{"\n"}{end}' 2>/dev/null \
      | awk 'NF' | sort -u | tr '\n' ' '
  )"
  discovered="${discovered% }"
  DNS_SYNC_TENANT_WILDCARDS="${discovered}"
  if [[ -z "${DNS_SYNC_TENANT_WILDCARDS}" ]]; then
    log "no tenants discovered; skipping tenant wildcard records"
  else
    log "discovered tenants: ${DNS_SYNC_TENANT_WILDCARDS}"
  fi
elif [[ "${DNS_SYNC_TENANT_WILDCARDS}" == "none" ]]; then
  DNS_SYNC_TENANT_WILDCARDS=""
fi

if [[ -n "${DNS_SYNC_TENANT_WILDCARDS}" ]]; then
  exclude_list="${DNS_SYNC_TENANT_WILDCARDS_EXCLUDE}"
  if [[ "${exclude_list}" == "cloud-dns-auto" ]]; then
    exclude_list="$(
      kubectl get dnszones.dns.darksite.cloud -o jsonpath='{range .items[*]}{.metadata.labels.darksite\.cloud/tenant-id}{"\n"}{end}' 2>/dev/null \
        | awk 'NF' | sort -u | tr '\n' ' '
    )"
    exclude_list="${exclude_list% }"
  fi

  if [[ -n "${exclude_list}" && "${exclude_list}" != "none" ]]; then
    log "excluding tenant wildcards managed by Cloud DNS: ${exclude_list}"
    filtered=""
    for tenant_id in ${DNS_SYNC_TENANT_WILDCARDS}; do
      skip=false
      for excluded in ${exclude_list}; do
        if [[ "${tenant_id}" == "${excluded}" ]]; then
          skip=true
          break
        fi
      done
      if [[ "${skip}" != "true" ]]; then
        filtered="${filtered} ${tenant_id}"
      fi
    done
    DNS_SYNC_TENANT_WILDCARDS="$(echo "${filtered}" | xargs || true)"
  fi
fi

DNS_SYNC_TENANT_WILDCARD_IPS=""
DNS_SYNC_TENANT_WILDCARD_MISSING=""
if [[ -n "${DNS_SYNC_TENANT_WILDCARDS}" ]]; then
  declare -a tenant_ip_pairs=()
  declare -a tenant_missing=()

  for tenant_id in ${DNS_SYNC_TENANT_WILDCARDS}; do
    svc="tenant-${tenant_id}-gateway-istio"

    log "fetching tenant gateway IP for ${tenant_id} from ${INGRESS_NAMESPACE}/${svc}"
    tenant_ip=""
    for ((i=1; i<=DNS_SYNC_RETRIES; i++)); do
      tenant_ip="$(kubectl -n "${INGRESS_NAMESPACE}" get svc "${svc}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      if [[ -n "${tenant_ip}" ]]; then
        break
      fi
      sleep "${DNS_SYNC_SLEEP}"
    done

    if [[ -z "${tenant_ip}" ]]; then
      log "warning: could not determine LoadBalancer IP for tenant gateway service ${INGRESS_NAMESPACE}/${svc} (tenantId=${tenant_id}); skipping tenant wildcard record"
      tenant_missing+=("${tenant_id}")
      continue
    fi

    tenant_ip_pairs+=("${tenant_id}=${tenant_ip}")
  done

  DNS_SYNC_TENANT_WILDCARD_IPS="$(printf '%s ' "${tenant_ip_pairs[@]:-}")"
  DNS_SYNC_TENANT_WILDCARD_IPS="${DNS_SYNC_TENANT_WILDCARD_IPS% }"

  DNS_SYNC_TENANT_WILDCARD_MISSING="$(printf '%s ' "${tenant_missing[@]:-}")"
  DNS_SYNC_TENANT_WILDCARD_MISSING="${DNS_SYNC_TENANT_WILDCARD_MISSING% }"
fi

PREVIOUS_IP="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.lastPublishedIP}' 2>/dev/null || true)"
PREVIOUS_RECORDS="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.lastRecords}' 2>/dev/null || true)"
PREVIOUS_WILDCARD_ENABLED="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.wildcardEnabled}' 2>/dev/null || true)"
PREVIOUS_TENANT_IPS="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.tenantWildcardIPs}' 2>/dev/null || true)"
PREVIOUS_TENANT_SUFFIX="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.tenantWildcardSuffix}' 2>/dev/null || true)"
PREVIOUS_TENANT_MISSING="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.tenantWildcardMissing}' 2>/dev/null || true)"
PREVIOUS_AUTH_NS_HOSTS="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.authorityNSHosts}' 2>/dev/null || true)"
PREVIOUS_AUTH_NS_IP="$(kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" get configmap "${DNS_SYNC_STATUS_CONFIGMAP}" -o jsonpath='{.data.authorityNSIP}' 2>/dev/null || true)"

ZONE_NAME="${DNS_DOMAIN%.}."
ADMIN_FQDN="admin.${ZONE_NAME}"
ZONE_ENDPOINT="${POWERDNS_API}/servers/localhost/zones/${ZONE_NAME}"

if [[ -n "${PREVIOUS_IP}" &&
  "${PREVIOUS_IP}" == "${LB_IP}" &&
  "${PREVIOUS_RECORDS}" == "${DNS_SYNC_HOSTS}" &&
  "${PREVIOUS_WILDCARD_ENABLED}" == "${DNS_SYNC_ENABLE_WILDCARD}" &&
  "${PREVIOUS_TENANT_IPS}" == "${DNS_SYNC_TENANT_WILDCARD_IPS}" &&
  "${PREVIOUS_TENANT_SUFFIX}" == "${DNS_SYNC_TENANT_WILDCARD_SUFFIX}" &&
  "${PREVIOUS_TENANT_MISSING}" == "${DNS_SYNC_TENANT_WILDCARD_MISSING}" &&
  "${PREVIOUS_AUTH_NS_HOSTS}" == "${DNS_AUTH_NS_HOSTS}" &&
  "${PREVIOUS_AUTH_NS_IP}" == "${DNS_AUTH_NS_IP}"
]]; then
  ensure_powerdns_api
  log "status configmap matches desired inputs; verifying authoritative records before skipping"
  if authoritative_zone_matches_desired "${ZONE_ENDPOINT}"; then
    log "PowerDNS already converged (desired records present); skipping"
    exit 0
  fi
  log "authoritative zone drift detected despite matching status config; republishing desired records"
fi

ensure_powerdns_api
SERIAL=$(date -u +%Y%m%d%H)

ZONE_NAME="${ZONE_NAME}" \
LB_IP="${LB_IP}" \
SERIAL="${SERIAL}" \
ADMIN_FQDN="${ADMIN_FQDN}" \
DNS_SYNC_HOST_TTL="${DNS_SYNC_HOST_TTL}" \
DNS_SYNC_PUBLISH_TTL="${DNS_SYNC_PUBLISH_TTL}" \
DNS_SYNC_HOSTS="${DNS_SYNC_HOSTS}" \
DNS_SYNC_ENABLE_WILDCARD="${DNS_SYNC_ENABLE_WILDCARD}" \
DNS_SYNC_TENANT_WILDCARD_IPS="${DNS_SYNC_TENANT_WILDCARD_IPS}" \
DNS_SYNC_TENANT_WILDCARD_SUFFIX="${DNS_SYNC_TENANT_WILDCARD_SUFFIX}" \
DNS_AUTH_NS_HOSTS="${DNS_AUTH_NS_HOSTS}" \
DNS_AUTH_NS_IP="${DNS_AUTH_NS_IP}" \
python3 <<'PY' > /tmp/dns-sync-payload.json
import json
import os
import sys

def bool_env(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")

zone = os.environ["ZONE_NAME"]
ip = os.environ["LB_IP"]
soa_serial = os.environ["SERIAL"]
admin_host = os.environ["ADMIN_FQDN"]
host_ttl = int(os.environ["DNS_SYNC_HOST_TTL"])
publish_ttl = int(os.environ["DNS_SYNC_PUBLISH_TTL"])
hosts = [h for h in os.environ["DNS_SYNC_HOSTS"].split() if h]
tenant_wildcard_ips = [p for p in os.environ.get("DNS_SYNC_TENANT_WILDCARD_IPS", "").split() if p]
tenant_wildcard_suffix = os.environ.get("DNS_SYNC_TENANT_WILDCARD_SUFFIX", "workloads")
ns_hosts = [h.rstrip(".") for h in os.environ.get("DNS_AUTH_NS_HOSTS", "").split() if h]
ns_ip = os.environ.get("DNS_AUTH_NS_IP", "").strip() or ip
if not ns_hosts:
    ns_hosts = [f"ns1.{zone.rstrip('.')}".rstrip(".")]
ns_host_fqdns = [f"{h}." for h in ns_hosts]
records = []

soa_content = f"{ns_host_fqdns[0]} {admin_host} {soa_serial} 3600 600 604800 300"
records.append({
    "name": zone,
    "type": "SOA",
    "ttl": publish_ttl,
    "changetype": "REPLACE",
    "records": [{"content": soa_content, "disabled": False}]
})
records.append({
    "name": zone,
    "type": "NS",
    "ttl": publish_ttl,
    "changetype": "REPLACE",
    "records": [{"content": ns_host_fqdn, "disabled": False} for ns_host_fqdn in ns_host_fqdns]
})
for ns_host_fqdn in ns_host_fqdns:
    records.append({
        "name": ns_host_fqdn,
        "type": "A",
        "ttl": publish_ttl,
        "changetype": "REPLACE",
        "records": [{"content": ns_ip, "disabled": False}]
    })

for host in hosts:
    if host == "@":
        name = zone
    else:
        name = f"{host}.{zone}"
    records.append({
        "name": name,
        "type": "A",
        "ttl": host_ttl,
        "changetype": "REPLACE",
        "records": [{"content": ip, "disabled": False}]
    })

if bool_env("DNS_SYNC_ENABLE_WILDCARD", True):
    records.append({
        "name": f"*.{zone}",
        "type": "A",
        "ttl": host_ttl,
        "changetype": "REPLACE",
        "records": [{"content": ip, "disabled": False}]
    })

for pair in tenant_wildcard_ips:
    tenant_id, tenant_ip = pair.split("=", 1)
    host = f"*.{tenant_id}.{tenant_wildcard_suffix}"
    records.append({
        "name": f"{host}.{zone}",
        "type": "A",
        "ttl": host_ttl,
        "changetype": "REPLACE",
        "records": [{"content": tenant_ip, "disabled": False}]
    })

payload = {"rrsets": records}
json.dump(payload, sys.stdout)
PY

log "patching zone ${ZONE_NAME} with updated records"
HTTP_STATUS=$(curl -w '%{http_code}' -o /tmp/dns-sync-response.json -sS -H "X-API-Key: ${POWERDNS_API_KEY}" \
  -H 'Content-Type: application/json' -X PATCH "${ZONE_ENDPOINT}" --data-binary @/tmp/dns-sync-payload.json)

if [[ "${HTTP_STATUS}" -ge 400 || -z "${HTTP_STATUS}" ]]; then
  log "PowerDNS API responded with status ${HTTP_STATUS}"
  cat /tmp/dns-sync-response.json >&2 || true
  exit 1
fi

log "zone update accepted (HTTP ${HTTP_STATUS})"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl -n "${DNS_SYNC_STATUS_NAMESPACE}" apply -f - <<CONFIGMAP
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${DNS_SYNC_STATUS_CONFIGMAP}
data:
  lastPublishedIP: "${LB_IP}"
  lastUpdateTimestamp: "${TIMESTAMP}"
  lastService: "${INGRESS_NAMESPACE}/${INGRESS_SERVICE}"
  lastRecords: "${DNS_SYNC_HOSTS}"
  wildcardEnabled: "${DNS_SYNC_ENABLE_WILDCARD}"
  tenantWildcardIPs: "${DNS_SYNC_TENANT_WILDCARD_IPS}"
  tenantWildcardSuffix: "${DNS_SYNC_TENANT_WILDCARD_SUFFIX}"
  tenantWildcardMissing: "${DNS_SYNC_TENANT_WILDCARD_MISSING}"
  authorityNSHosts: "${DNS_AUTH_NS_HOSTS}"
  authorityNSIP: "${DNS_AUTH_NS_IP}"
CONFIGMAP

log "recorded published IP ${LB_IP} in ${DNS_SYNC_STATUS_NAMESPACE}/${DNS_SYNC_STATUS_CONFIGMAP}"
