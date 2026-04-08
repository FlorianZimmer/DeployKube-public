#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

pattern='\btemp-[A-Za-z0-9_-]+\b'

echo "==> Checking runtime identity surfaces for forbidden temp-* markers"

runtime_matches="$(
  rg --no-heading -n "${pattern}" \
    platform/gitops \
    shared/scripts \
    -g '*.yaml' -g '*.yml' -g '*.sh' 2>/dev/null || true
)"

toil_matches="$(
  rg --no-heading -n "${pattern}" \
    docs/toils \
    -g '*.md' -g '*.sh' 2>/dev/null || true
)"

matches="$(printf '%s\n%s\n' "${runtime_matches}" "${toil_matches}" | sed '/^$/d')"

# Allowed legacy cleanup path:
# - keycloak bootstrap removes the historical temp-admin account if it exists.
filtered_matches="$(
  printf '%s\n' "${matches}" \
    | grep -Ev '^platform/gitops/components/platform/keycloak/bootstrap-job/base/scripts/bootstrap\.sh:[0-9]+:.*temp-admin' \
    || true
)"

if [[ -n "${filtered_matches}" ]]; then
  echo "FAIL: found forbidden temp-* identity markers:" >&2
  printf '%s\n' "${filtered_matches}" >&2
  exit 1
fi

echo "PASS"
