# Runbook: centralized CI security-scanning alerts

These alerts cover the published centralized Trivy CI inventories (`platform-core`, `platform-services`, and `platform-foundations` as of March 11, 2026).

## What is covered

- The repo-owned scan runner: `tests/scripts/scan-trivy-ci.sh`
- Metrics publication into Mimir: `tests/scripts/publish-trivy-ci-metrics.sh`
- The scheduled/self-hosted workflow: `.github/workflows/security-scanning.yml`
- The Grafana dashboard fed by these metrics

## Alerts

- `SecurityScanningCIScanStale`
  - No successful metrics publish has updated a tracked inventory inside the expected window.
- `SecurityScanningCILastRunFailed`
  - The most recent published run for a tracked inventory reported `run_success=0`.

## Immediate triage checklist

1. Confirm the last published metrics:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n mimir port-forward svc/mimir-querier 19092:8080
curl -sS -G 'http://127.0.0.1:19092/prometheus/api/v1/query' \
  -H 'X-Scope-OrgID: platform' \
  --data-urlencode 'query=deploykube_security_ci_scan_last_run_timestamp_seconds' | jq.
curl -sS -G 'http://127.0.0.1:19092/prometheus/api/v1/query' \
  -H 'X-Scope-OrgID: platform' \
  --data-urlencode 'query=deploykube_security_ci_scan_run_success' | jq.
```

2. Inspect the latest workflow run and scan artefacts:

```bash
gh run list --workflow 'Security Scanning' --limit 10
gh run view <run-id> --log
```

3. If the scan itself failed, rerun it locally against the same profile:

```bash./tests/scripts/scan-trivy-ci.sh --profile platform-foundations --output-dir tmp/trivy-ci-scan-manual
jq '.totals' tmp/trivy-ci-scan-manual/summary.json
```

4. If the scan succeeded but publishing failed, rerun the publish step against Proxmox:

```bash
KUBECONFIG=tmp/kubeconfig-prod \./tests/scripts/publish-trivy-ci-metrics.sh \
  --summary tmp/trivy-ci-scan-manual/summary.json \
  --run-success 1
```

## Common causes

- The self-hosted runner lost access to the internal registry refs in the scan inventory.
- Trivy DB refresh or network access failed on the runner.
- The publish step could not port-forward or reach Mimir.
- The scan inventory now points at a moved/renamed repo-truth source path.

## Operator expectations

- Findings counts are informational in phase 1; freshness/failure is the actionable alert surface.
- A red `run_success` means the workflow or publish path failed, not necessarily that Trivy found critical issues.
