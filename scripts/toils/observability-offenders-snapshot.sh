#!/usr/bin/env bash
set -euo pipefail

ns="${1:-observability}"
cm="${2:-observability-offenders-snapshot}"
kubeconfig="${3:-${KUBECONFIG:-}}"

kubectl_args=()
if [ -n "${kubeconfig}" ]; then
  kubectl_args+=(--kubeconfig "${kubeconfig}")
fi

kubectl "${kubectl_args[@]}" -n "${ns}" get configmap "${cm}" -o jsonpath='{.metadata.annotations.deploykube\.dev/generated-at}{"\n"}{.data.report\.txt}{"\n"}'
