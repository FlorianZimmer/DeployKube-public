#!/usr/bin/env bash
# check-hardcoded-domains.sh - Detect hard-coded domain literals outside allowed locations
# This script fails if *.internal.example.com literals appear in disallowed paths.
#
# Allowed paths:
#   - platform/gitops/deployments/**  (the contract - source of truth)
#   - docs/**                          (documentation/examples)
#   - tests/**                         (test fixtures)
#   - bootstrap/**                     (bootstrap inputs - to be migrated later)
#   - .gemini/**                       (AI context files)
#   - agents.md                        (AI context file at root)
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

# Domain patterns to check (add more as needed)
domain_patterns=(
  "\.internal\.example\.com"
)

# Allowed path patterns (ripgrep glob format)
# NOTE: Phase 1 allows most locations; Phase 3/4 will tighten this list
allowed_globs=(
  # Source of truth (the contract)
  "platform/gitops/deployments/**"
  # TODO: Remove the next line after Phase 3/4 refactors domain values into deployment config
  "platform/gitops/components/**"
  "platform/gitops/apps/**"
  # Scripts that consume deployment config (will read from contract in future)
  "shared/**"
  # Documentation and non-code files
  "docs/**"
  "tests/**"
  "bootstrap/**"
  ".gemini/**"
  # Root-level files (ripgrep needs explicit path pattern)
  "agents.md"
  "README.md"
)

# Build ripgrep exclude args
exclude_args=()
for glob in "${allowed_globs[@]}"; do
  exclude_args+=("-g" "!${glob}")
done

failures=0

echo "==> Checking for hard-coded domain literals"

for pattern in "${domain_patterns[@]}"; do
  echo ""
  echo "Pattern: ${pattern}"
  
  # Search for matches outside allowed paths
  # Only scan code files (not .md - documentation is allowed)
  matches=$(rg --no-heading -n "${pattern}" \
    "${exclude_args[@]}" \
    -g '*.yaml' -g '*.yml' -g '*.json' -g '*.sh' -g '*.tf' -g '*.tfvars' \
    . 2>/dev/null || true)
  
  if [ -n "${matches}" ]; then
    echo "  FAIL: Found hard-coded domain literals in disallowed locations:" >&2
    echo "${matches}" | while IFS= read -r line; do
      echo "    ${line}" >&2
    done
    failures=$((failures + 1))
  else
    echo "  PASS: No violations found"
  fi
done

echo ""
if [ "${failures}" -ne 0 ]; then
  echo "hard-coded domain check FAILED (${failures} pattern(s) with violations)" >&2
  echo "" >&2
  echo "To fix: Move domain-specific values to platform/gitops/deployments/<deployment>/config.yaml" >&2
  exit 1
fi

echo "hard-coded domain check PASSED"
