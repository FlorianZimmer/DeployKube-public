#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

usage() {
  cat <<'EOF'
Usage: ./scripts/release/release-tag.sh --tag <tag> [options]

Strict release tagging:
- Runs the "Release E2E Gate" on the exact target commit.
- Refuses to create/push the tag unless the gate passes.
- Refuses to create/push the tag unless component-assessment release baselines match the target commit.

Tag naming policy:
- Tag must be SemVer with a leading `v`, for example: `v0.1.0`, `v1.2.3-rc.1`.
- Breakglass bypass: set `DK_ALLOW_NONSTANDARD_RELEASE_TAG=1`.

Options:
  --tag <tag>                Tag name to create (required)
  --ref <gitref>             Git ref to tag (default: HEAD)
  --message <msg>            Annotated tag message (default: auto)
  --auto-commit-baselines <v>
                             Auto-regenerate + commit component-assessment baselines if missing/stale yes|no (default: no)
  --kubeconfig-path <path>   Optional kubeconfig path on the self-hosted runner
  --cert-modes <csv>         Certificate mode CSV for release gate (default: subCa,acme,wildcard)
  --smoke-profile <v>        Runtime smoke profile quick|full (default: full)
  --include-restore-canary <v>
                             Also run backup restore canary yes|no (default: no)
  --run-upstream-sim <v>     auto|yes|no (default: auto)
  --allow-dirty <yes|no>     Allow dirty worktree (default: no)
  --push <yes|no>            Push tag to origin (default: yes)
  --timeout <dur>            Gate timeout (default: 180m)
  -h|--help                  Show this help

Prereqs:
- `gh` authenticated (used by scripts/release/release-gate.sh)
- `origin` remote configured

Baseline automation:
- If baselines are missing/stale, this script can auto-regenerate + commit them before tagging.
- To enable auto-commit, pass `--auto-commit-baselines yes` (or set `DK_RELEASE_TAG_AUTO_COMMIT_BASELINES=1`).
- If you're tagging from `main` and repo githooks enforce main protections, you may also need:
  - `DK_ALLOW_MAIN_COMMIT=1` (to allow the baseline commit)
  - `DK_ALLOW_MAIN_PUSH=1` (to push `main` before pushing the tag)

Dirty state (breakglass):
- Tagging from a dirty worktree is refused by default.
- To allow it, set `DK_ALLOW_DIRTY_RELEASE_TAG=1` and pass `--allow-dirty yes`.
- Note: a dirty worktree means the component-assessment baseline gate is skipped (unassessed state).
EOF
}

need() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing required binary: ${bin}" >&2
    exit 1
  fi
}

need_origin() {
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "error: missing required git remote: origin" >&2
    exit 1
  fi
}

tag=""
ref="HEAD"
message=""
auto_commit_baselines=""
kubeconfig_path=""
cert_modes="subCa,acme,wildcard"
smoke_profile="full"
include_restore_canary="no"
run_upstream_sim="auto"
allow_dirty="no"
push="yes"
timeout="180m"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --ref)
      ref="${2:-}"
      shift 2
      ;;
    --message)
      message="${2:-}"
      shift 2
      ;;
    --auto-commit-baselines)
      auto_commit_baselines="${2:-}"
      shift 2
      ;;
    --kubeconfig-path)
      kubeconfig_path="${2:-}"
      shift 2
      ;;
    --cert-modes)
      cert_modes="${2:-}"
      shift 2
      ;;
    --smoke-profile)
      smoke_profile="${2:-}"
      shift 2
      ;;
    --include-restore-canary)
      include_restore_canary="${2:-}"
      shift 2
      ;;
    --run-upstream-sim)
      run_upstream_sim="${2:-}"
      shift 2
      ;;
    --allow-dirty)
      allow_dirty="${2:-}"
      shift 2
      ;;
    --push)
      push="${2:-}"
      shift 2
      ;;
    --timeout)
      timeout="${2:-}"
      shift 2
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${tag}" ]]; then
  echo "error: --tag is required" >&2
  usage >&2
  exit 2
fi

if [[ "${DK_ALLOW_NONSTANDARD_RELEASE_TAG:-}" != "1" ]]; then
  semver_re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
  if ! [[ "${tag}" =~ ${semver_re} ]]; then
    echo "error: tag '${tag}' does not match required SemVer pattern (example: v0.1.0, v1.2.3-rc.1)" >&2
    echo "hint: breakglass bypass exists via DK_ALLOW_NONSTANDARD_RELEASE_TAG=1" >&2
    exit 2
  fi
fi

case "${allow_dirty}" in
  yes|no) ;;
  *) echo "error: --allow-dirty must be yes|no (got '${allow_dirty}')" >&2; exit 2 ;;
esac
case "${push}" in
  yes|no) ;;
  *) echo "error: --push must be yes|no (got '${push}')" >&2; exit 2 ;;
esac
case "${run_upstream_sim}" in
  auto|yes|no) ;;
  *) echo "error: --run-upstream-sim must be auto|yes|no (got '${run_upstream_sim}')" >&2; exit 2 ;;
esac
case "${smoke_profile}" in
  quick|full) ;;
  *) echo "error: --smoke-profile must be quick|full (got '${smoke_profile}')" >&2; exit 2 ;;
esac
case "${include_restore_canary}" in
  yes|no) ;;
  *) echo "error: --include-restore-canary must be yes|no (got '${include_restore_canary}')" >&2; exit 2 ;;
esac

case "${auto_commit_baselines}" in
  ""|yes|no) ;;
  *) echo "error: --auto-commit-baselines must be yes|no (got '${auto_commit_baselines}')" >&2; exit 2 ;;
esac

need git
need_origin

worktree_dirty="false"
if [[ -n "$(git status --porcelain)" ]]; then
  worktree_dirty="true"
fi

if [[ "${allow_dirty}" != "yes" && "${worktree_dirty}" == "true" ]]; then
  echo "error: working tree is dirty; commit/stash first or pass --allow-dirty yes (breakglass requires DK_ALLOW_DIRTY_RELEASE_TAG=1)" >&2
  exit 1
fi

if [[ "${allow_dirty}" == "yes" && "${worktree_dirty}" == "true" ]]; then
  if [[ "${DK_ALLOW_DIRTY_RELEASE_TAG:-}" != "1" ]]; then
    echo "error: refusing to tag from dirty worktree without explicit breakglass (set DK_ALLOW_DIRTY_RELEASE_TAG=1)" >&2
    exit 1
  fi
  echo "WARNING: tagging from a dirty worktree (DK_ALLOW_DIRTY_RELEASE_TAG=1). Baseline validation is skipped; this is an unassessed state." >&2
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

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
  echo "error: tag already exists locally: ${tag}" >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
  echo "error: tag already exists on origin: ${tag}" >&2
  exit 1
fi

auto_commit_enabled="false"
if [[ "${auto_commit_baselines}" == "yes" ]]; then
  auto_commit_enabled="true"
elif [[ "${auto_commit_baselines}" == "" && "${DK_RELEASE_TAG_AUTO_COMMIT_BASELINES:-}" == "1" ]]; then
  auto_commit_enabled="true"
fi

skip_baseline_validation="false"
if [[ "${worktree_dirty}" == "true" && "${allow_dirty}" == "yes" ]]; then
  skip_baseline_validation="true"
fi
if [[ "${DK_ALLOW_RELEASE_TAG_WITHOUT_COMPONENT_ASSESSMENT_BASELINE:-}" == "1" ]]; then
  skip_baseline_validation="true"
  echo "WARNING: bypassing component-assessment baseline validation (DK_ALLOW_RELEASE_TAG_WITHOUT_COMPONENT_ASSESSMENT_BASELINE=1)" >&2
fi

if [[ "${skip_baseline_validation}" != "true" ]]; then
  echo "==> Validating component-assessment release baselines for SHA ${sha}"
  if ! ./tests/scripts/validate-component-assessment-release-baseline.sh --ref "${sha}"; then
    if [[ "${auto_commit_enabled}" != "true" ]]; then
      echo "error: component-assessment baselines are missing/stale." >&2
      echo "hint: regenerate baselines via:" >&2
      echo "  ./scripts/release/component-assessment-release-baseline.sh --ref ${sha}" >&2
      echo "hint: or rerun with --auto-commit-baselines yes (or DK_RELEASE_TAG_AUTO_COMMIT_BASELINES=1) to auto-commit baseline updates." >&2
      exit 1
    fi

    echo "==> Baselines missing/stale; regenerating release baselines for SHA ${sha}"
    ./scripts/release/component-assessment-release-baseline.sh --ref "${sha}"

    echo "==> Committing regenerated baselines"
    git add \
      docs/evidence/component-assessment/release-baseline/fingerprints-code.tsv \
      docs/evidence/component-assessment/release-baseline/fingerprints-docs.tsv \
      docs/evidence/component-assessment/release-baseline/metadata.md
    git commit -m "release: update component-assessment release baselines"

    sha="$(git rev-parse HEAD)"
    echo "==> Re-validating component-assessment release baselines for new HEAD ${sha}"
    ./tests/scripts/validate-component-assessment-release-baseline.sh --ref "${sha}"
  fi
else
  echo "WARNING: component-assessment baseline validation skipped (unassessed state)" >&2
fi

commit_is_reachable_on_origin() {
  # Requires a recent fetch of origin remote-tracking refs.
  git branch -r --contains "${sha}" 2>/dev/null | grep -q .
}

echo "==> Ensuring target commit is available on origin (required for Release E2E Gate dispatch)"
git fetch -q origin --tags
if ! commit_is_reachable_on_origin; then
  if [[ "${push}" == "yes" ]]; then
    branch="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [[ -z "${branch}" ]]; then
      echo "error: detached HEAD and commit ${sha} is not reachable on origin; cannot push. Push a branch containing ${sha} first." >&2
      exit 1
    fi
    echo "==> Pushing branch to origin: ${branch} (to make SHA ${sha} reachable for GitHub Actions)"
    git push origin "HEAD:refs/heads/${branch}"
    git fetch -q origin --tags
    if ! commit_is_reachable_on_origin; then
      echo "error: commit ${sha} still not reachable on origin after push (unexpected)" >&2
      exit 1
    fi
  else
    echo "error: commit ${sha} is not reachable on origin; rerun with --push yes or push the branch first" >&2
    exit 1
  fi
fi

echo "==> Running strict Release E2E Gate for SHA ${sha}"
gate_args=(--ref "${sha}" --cert-modes "${cert_modes}" --smoke-profile "${smoke_profile}" --include-restore-canary "${include_restore_canary}" --run-upstream-sim "${run_upstream_sim}" --timeout "${timeout}")
if [[ -n "${kubeconfig_path}" ]]; then
  gate_args+=(--kubeconfig-path "${kubeconfig_path}")
fi

./scripts/release/release-gate.sh "${gate_args[@]}"

if [[ -z "${message}" ]]; then
  message="Release ${tag} (${sha})"
fi

echo "==> Creating annotated tag: ${tag} -> ${sha}"
git tag -a "${tag}" -m "${message}" "${sha}"

if [[ "${push}" == "yes" ]]; then
  echo "==> Pushing tag to origin: ${tag}"
  git push origin "refs/tags/${tag}"
fi

echo "Release tag created: ${tag}"
