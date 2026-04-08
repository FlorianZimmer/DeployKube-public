#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/release/component-assessment-release-baseline.sh [--ref <gitref>]

Generates and writes the release component-assessment fingerprint baselines into:
  docs/evidence/component-assessment/release-baseline/

This is intended to be run before creating a release tag so tagging can enforce:
  - the full component-assessment baseline corresponds to the commit being tagged
  - no drift exists between baseline and current repo state

Notes:
  - Requires a clean worktree.
  - Does NOT run any LLM evaluation; it only snapshots fingerprints.
  - Baselines are normalized (strip non-deterministic headers like run_id/git_commit) so they can be committed
    without creating self-referential drift.
EOF
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty; commit/stash first" >&2
  exit 1
fi

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

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dk-component-assessment-release-baseline.XXXXXX")"
cleanup() { rm -rf "${tmp_root}"; }
trap cleanup EXIT

run_id="release-baseline-$(date -u +%Y%m%dT%H%M%SZ)"

./scripts/dev/component-assessment-workpack.sh --all --prompt-set code --run-id "${run_id}-code" --output-root "${tmp_root}" --no-incremental >/dev/null
./scripts/dev/component-assessment-workpack.sh --all --prompt-set docs --run-id "${run_id}-docs" --output-root "${tmp_root}" --no-incremental >/dev/null

out_dir="docs/evidence/component-assessment/release-baseline"
mkdir -p "${out_dir}"

normalize_fingerprints() {
  # Strip non-deterministic headers. Keep templates_sha256 + prompt_set (they should be stable).
  grep -vE '^(# run_id:|# git_commit:|# worktree_clean:)' "$1"
}

raw_code_fp="${tmp_root}/${run_id}-code/fingerprints.tsv"
raw_docs_fp="${tmp_root}/${run_id}-docs/fingerprints.tsv"

normalize_fingerprints "${raw_code_fp}" > "${out_dir}/fingerprints-code.tsv"
normalize_fingerprints "${raw_docs_fp}" > "${out_dir}/fingerprints-docs.tsv"

get_header() {
  local f="$1"
  local key="$2"
  grep -E "^# ${key}:" "${f}" | head -n 1 | sed -E "s/^# ${key}:\\s*//"
}

generated_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
git_branch="$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "DETACHED")"
git_user_name="$(git config user.name 2>/dev/null || true)"
git_user_email="$(git config user.email 2>/dev/null || true)"
templates_code="$(get_header "${raw_code_fp}" "templates_sha256" || true)"
templates_docs="$(get_header "${raw_docs_fp}" "templates_sha256" || true)"

cat > "${out_dir}/metadata.md" <<EOF
# Component-Assessment Release Baseline Metadata

This file is informational only. It is NOT used by the release gate validation.

- generated_at_utc: ${generated_at_utc}
- git_commit: ${sha}
- git_branch: ${git_branch}
- generated_by: ${git_user_name} <${git_user_email}>
- templates_sha256_code: ${templates_code}
- templates_sha256_docs: ${templates_docs}
EOF

cat <<EOF
Wrote release component-assessment baselines for:
  commit: ${sha}

Files:
  ${out_dir}/fingerprints-code.tsv
  ${out_dir}/fingerprints-docs.tsv
  ${out_dir}/metadata.md

Next:
  ./tests/scripts/validate-component-assessment-release-baseline.sh --ref ${sha}
EOF
