#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./tests/scripts/validate-component-assessment-release-baseline.sh [--ref <gitref>]

Validates that the committed release component-assessment fingerprint baselines match the current repo state.

Baselines (must exist):
  docs/evidence/component-assessment/release-baseline/fingerprints-code.tsv
  docs/evidence/component-assessment/release-baseline/fingerprints-docs.tsv

Rules:
  - This validator recomputes fingerprints for prompt-set code and docs and diffs them against the committed baselines.
  - It requires the repo to be checked out at the target commit (default: HEAD) because fingerprints are computed from the working tree.
EOF
}

root_dir="$(git rev-parse --show-toplevel)"
cd "${root_dir}"

ref="HEAD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      ref="${2:-}"
      shift 2
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

sha="$(git rev-parse "${ref}^{commit}" 2>/dev/null || true)"
if [[ -z "${sha}" ]]; then
  echo "error: could not resolve --ref to a commit: ${ref}" >&2
  exit 2
fi

if [[ "$(git rev-parse HEAD)" != "${sha}" ]]; then
  echo "error: --ref (${ref}) does not match current HEAD; checkout the target commit first" >&2
  echo "hint: git switch --detach ${sha}" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty; refuse to validate release baselines against dirty state" >&2
  exit 1
fi

baseline_dir="docs/evidence/component-assessment/release-baseline"
baseline_code="${baseline_dir}/fingerprints-code.tsv"
baseline_docs="${baseline_dir}/fingerprints-docs.tsv"

if [[ ! -f "${baseline_code}" ]]; then
  echo "error: missing baseline: ${baseline_code}" >&2
  exit 1
fi
if [[ ! -f "${baseline_docs}" ]]; then
  echo "error: missing baseline: ${baseline_docs}" >&2
  exit 1
fi

normalize_fingerprints() {
  # Normalize out non-deterministic headers.
  # We intentionally keep templates_sha256 + prompt_set because they should be stable.
  grep -vE '^(# run_id:|# git_commit:|# worktree_clean:)' "$1"
}

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "${tmp_root}"; }
trap cleanup EXIT

./scripts/dev/component-assessment-workpack.sh --all --prompt-set code --run-id validate-code --output-root "${tmp_root}" --no-incremental >/dev/null
./scripts/dev/component-assessment-workpack.sh --all --prompt-set docs --run-id validate-docs --output-root "${tmp_root}" --no-incremental >/dev/null

computed_code="${tmp_root}/validate-code/fingerprints.tsv"
computed_docs="${tmp_root}/validate-docs/fingerprints.tsv"

tmp_a="$(mktemp)"
tmp_b="$(mktemp)"
normalize_fingerprints "${baseline_code}" > "${tmp_a}"
normalize_fingerprints "${computed_code}" > "${tmp_b}"
if ! diff -u "${tmp_a}" "${tmp_b}" >/dev/null; then
  echo "FAIL: code baseline fingerprints do not match recomputed state" >&2
  diff -u "${tmp_a}" "${tmp_b}" | sed -n '1,200p' >&2
  exit 1
fi

normalize_fingerprints "${baseline_docs}" > "${tmp_a}"
normalize_fingerprints "${computed_docs}" > "${tmp_b}"
if ! diff -u "${tmp_a}" "${tmp_b}" >/dev/null; then
  echo "FAIL: docs baseline fingerprints do not match recomputed state" >&2
  diff -u "${tmp_a}" "${tmp_b}" | sed -n '1,200p' >&2
  exit 1
fi

echo "PASS: component-assessment release baselines match ${sha}"
