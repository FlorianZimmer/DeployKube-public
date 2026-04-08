#!/usr/bin/env bash
# publish-trivy-ci-metrics.sh
# Push centralized Trivy CI summary metrics into Mimir and verify they are queryable.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

summary_file=""
run_success=1
inventory_label=""
tenant="${MIMIR_TENANT:-platform}"
port_forward_mode="auto"
distributor_port="${MIMIR_DISTRIBUTOR_PORT:-19091}"
querier_port="${MIMIR_QUERIER_PORT:-19092}"
metrics_port="${TRIVY_CI_METRICS_PORT:-19093}"
remote_write_url="${MIMIR_REMOTE_WRITE_URL:-}"
query_url="${MIMIR_QUERY_URL:-}"
output_metrics_file=""

usage() {
  cat <<'EOF'
Usage: ./tests/scripts/publish-trivy-ci-metrics.sh --run-success <0|1> [options]

Options:
  --summary PATH             Summary JSON from scan-trivy-ci.sh
  --run-success 0|1         Whether the most recent run succeeded
  --inventory-label LABEL   Override the inventory/profile label used in metrics
  --tenant NAME             Mimir tenant header (default platform)
  --port-forward MODE       auto|always|never (default auto)
  --output-metrics PATH     Also write the rendered Prometheus metrics textfile
  --help                    Show this message

If MIMIR_REMOTE_WRITE_URL and MIMIR_QUERY_URL are unset and port-forward mode is
auto/always, the script port-forwards the proxied Mimir distributor and querier.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: missing dependency '${cmd}'" >&2
    exit 1
  fi
}

start_port_forward() {
  local service="$1"
  local local_port="$2"
  local log_file="$3"

  kubectl -n mimir port-forward "svc/${service}" "${local_port}:8080" >"${log_file}" 2>&1 &
  printf '%s\n' "$!"
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-30}"
  local delay="${3:-2}"
  local i

  for i in $(seq 1 "${attempts}"); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary)
      summary_file="$2"
      shift 2
      ;;
    --run-success)
      run_success="$2"
      shift 2
      ;;
    --inventory-label)
      inventory_label="$2"
      shift 2
      ;;
    --tenant)
      tenant="$2"
      shift 2
      ;;
    --port-forward)
      port_forward_mode="$2"
      shift 2
      ;;
    --output-metrics)
      output_metrics_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd curl
require_cmd docker
require_cmd jq
require_cmd python3

if [[ "${run_success}" != "0" && "${run_success}" != "1" ]]; then
  echo "error: --run-success must be 0 or 1" >&2
  exit 1
fi

if [[ -n "${summary_file}" && ! -f "${summary_file}" ]]; then
  echo "error: missing summary file '${summary_file}'" >&2
  exit 1
fi

if [[ -z "${inventory_label}" ]]; then
  if [[ -n "${summary_file}" ]]; then
    inventory_label="$(jq -r '.profile' "${summary_file}")"
  else
    echo "error: --inventory-label is required when --summary is not provided" >&2
    exit 1
  fi
fi

tmpdir="$(mktemp -d "${root_dir}/tmp/trivy-ci-metrics.XXXXXX")"
cleanup() {
  if [[ -n "${metrics_server_pid:-}" ]]; then
    kill "${metrics_server_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${pf_distributor_pid:-}" ]]; then
    kill "${pf_distributor_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${pf_querier_pid:-}" ]]; then
    kill "${pf_querier_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmpdir}"
}
trap cleanup EXIT INT TERM

if [[ -z "${remote_write_url}" || -z "${query_url}" ]]; then
  case "${port_forward_mode}" in
    auto|always)
      require_cmd kubectl
      pf_distributor_pid="$(start_port_forward "mimir-distributor" "${distributor_port}" "${tmpdir}/port-forward-distributor.log")"
      pf_querier_pid="$(start_port_forward "mimir-querier" "${querier_port}" "${tmpdir}/port-forward-querier.log")"
      remote_write_url="${remote_write_url:-http://127.0.0.1:${distributor_port}/api/v1/push}"
      query_url="${query_url:-http://127.0.0.1:${querier_port}/prometheus/api/v1/query}"
      if ! wait_for_http "http://127.0.0.1:${querier_port}/prometheus/api/v1/status/buildinfo" 30 2; then
        echo "error: mimir querier did not become reachable via port-forward" >&2
        exit 1
      fi
      ;;
    never)
      echo "error: MIMIR_REMOTE_WRITE_URL and MIMIR_QUERY_URL must be set when port-forward is disabled" >&2
      exit 1
      ;;
    *)
      echo "error: invalid --port-forward mode '${port_forward_mode}'" >&2
      exit 1
      ;;
  esac
fi

remote_write_url_for_container="${remote_write_url}"
remote_write_url_for_container="${remote_write_url_for_container/http:\/\/127.0.0.1/http:\/\/host.docker.internal}"
remote_write_url_for_container="${remote_write_url_for_container/http:\/\/localhost/http:\/\/host.docker.internal}"

run_timestamp="$(date +%s)"
metrics_file="${tmpdir}/metrics"
{
  echo "# HELP deploykube_security_ci_scan_last_run_timestamp_seconds Unix timestamp of the most recent centralized CI Trivy run."
  echo "# TYPE deploykube_security_ci_scan_last_run_timestamp_seconds gauge"
  printf 'deploykube_security_ci_scan_last_run_timestamp_seconds{inventory="%s"} %s\n' "${inventory_label}" "${run_timestamp}"
  echo "# HELP deploykube_security_ci_scan_run_success Whether the most recent centralized CI Trivy run succeeded."
  echo "# TYPE deploykube_security_ci_scan_run_success gauge"
  printf 'deploykube_security_ci_scan_run_success{inventory="%s"} %s\n' "${inventory_label}" "${run_success}"

  if [[ "${run_success}" == "1" ]]; then
    echo "# HELP deploykube_security_ci_scan_last_success_timestamp_seconds Unix timestamp of the most recent successful centralized CI Trivy run."
    echo "# TYPE deploykube_security_ci_scan_last_success_timestamp_seconds gauge"
    printf 'deploykube_security_ci_scan_last_success_timestamp_seconds{inventory="%s"} %s\n' "${inventory_label}" "${run_timestamp}"

    image_targets="$(jq -r '.totals.image_targets' "${summary_file}")"
    config_targets="$(jq -r '.totals.config_targets' "${summary_file}")"
    image_critical="$(jq -r '.totals.image_critical_total' "${summary_file}")"
    image_high="$(jq -r '.totals.image_high_total' "${summary_file}")"
    config_critical="$(jq -r '.totals.config_critical_total' "${summary_file}")"
    config_high="$(jq -r '.totals.config_high_total' "${summary_file}")"

    echo "# HELP deploykube_security_ci_scan_targets_total Number of targets scanned by type."
    echo "# TYPE deploykube_security_ci_scan_targets_total gauge"
    printf 'deploykube_security_ci_scan_targets_total{inventory="%s",target_type="image"} %s\n' "${inventory_label}" "${image_targets}"
    printf 'deploykube_security_ci_scan_targets_total{inventory="%s",target_type="config"} %s\n' "${inventory_label}" "${config_targets}"

    echo "# HELP deploykube_security_ci_scan_findings_total High and critical findings by target type."
    echo "# TYPE deploykube_security_ci_scan_findings_total gauge"
    printf 'deploykube_security_ci_scan_findings_total{inventory="%s",target_type="image",severity="critical"} %s\n' "${inventory_label}" "${image_critical}"
    printf 'deploykube_security_ci_scan_findings_total{inventory="%s",target_type="image",severity="high"} %s\n' "${inventory_label}" "${image_high}"
    printf 'deploykube_security_ci_scan_findings_total{inventory="%s",target_type="config",severity="critical"} %s\n' "${inventory_label}" "${config_critical}"
    printf 'deploykube_security_ci_scan_findings_total{inventory="%s",target_type="config",severity="high"} %s\n' "${inventory_label}" "${config_high}"
  fi
} > "${metrics_file}"

if [[ -n "${output_metrics_file}" ]]; then
  cp "${metrics_file}" "${output_metrics_file}"
fi

pushd "${tmpdir}" >/dev/null
python3 -m http.server "${metrics_port}" --bind 127.0.0.1 >/dev/null 2>&1 &
metrics_server_pid="$!"
popd >/dev/null

if ! wait_for_http "http://127.0.0.1:${metrics_port}/metrics" 15 1; then
  echo "error: local metrics server did not become ready" >&2
  exit 1
fi

prom_config="${tmpdir}/prometheus.yml"
cat > "${prom_config}" <<EOF
global:
  scrape_interval: 5s
  external_labels:
    inventory: "${inventory_label}"
scrape_configs:
  - job_name: deploykube-security-ci
    static_configs:
      - targets: ["host.docker.internal:${metrics_port}"]
remote_write:
  - url: ${remote_write_url_for_container}
    headers:
      X-Scope-OrgID: ${tenant}
EOF

docker_host_args=()
if [[ "$(uname -s)" == "Linux" ]]; then
  docker_host_args+=(--add-host host.docker.internal:host-gateway)
fi

docker run --rm \
  "${docker_host_args[@]}" \
  --entrypoint /bin/sh \
  -v "${prom_config}:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v2.52.0 \
  -lc '/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/tmp/tsdb --web.listen-address=0.0.0.0:9090 >/tmp/prom.log 2>&1 & sleep 20'

found=0
for _ in $(seq 1 20); do
  response="$(curl -sfS -G "${query_url}" \
    -H "X-Scope-OrgID: ${tenant}" \
    --data-urlencode "query=deploykube_security_ci_scan_last_run_timestamp_seconds{inventory=\"${inventory_label}\"}")"
  if printf '%s' "${response}" | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
    found=1
    break
  fi
  sleep 2
done

if [[ "${found}" -ne 1 ]]; then
  echo "error: published security scanning metric not queryable from Mimir" >&2
  exit 1
fi

echo "published centralized CI scanning metrics for inventory '${inventory_label}'"
