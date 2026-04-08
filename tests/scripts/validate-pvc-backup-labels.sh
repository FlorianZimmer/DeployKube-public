#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

if ! command -v yq >/dev/null 2>&1; then
  echo "error: yq not found (needed to parse YAML)" >&2
  exit 1
fi

valid_backup_values=("restic" "native" "skip")
failures=0

is_valid_backup_value() {
  local value="$1"
  local v
  for v in "${valid_backup_values[@]}"; do
    if [ "${value}" = "${v}" ]; then
      return 0
    fi
  done
  return 1
}

validate_backup_labels() {
  local file="$1"
  local ref="$2"
  local backup_label="$3"
  local skip_reason="$4"

  if [ -z "${backup_label}" ]; then
    echo "FAIL: ${file}: ${ref} missing metadata.labels[darksite.cloud/backup]" >&2
    failures=$((failures + 1))
    return 0
  fi

  if ! is_valid_backup_value "${backup_label}"; then
    echo "FAIL: ${file}: ${ref} invalid darksite.cloud/backup value '${backup_label}' (expected: restic|native|skip)" >&2
    failures=$((failures + 1))
    return 0
  fi

  if [ "${backup_label}" = "skip" ] && [ -z "${skip_reason}" ]; then
    echo "FAIL: ${file}: ${ref} darksite.cloud/backup=skip requires metadata.labels[darksite.cloud/backup-skip-reason]" >&2
    failures=$((failures + 1))
    return 0
  fi

  return 0
}

mapfile -t yaml_files < <(
  find platform/gitops/components -type f -name '*.yaml' \
    -not -path '*/charts/*' \
    -not -path '*/helm/charts/*' \
    -not -path '*/templates/*' \
    | sort
)

if [ "${#yaml_files[@]}" -eq 0 ]; then
  echo "no YAML files found under platform/gitops/components (unexpected)" >&2
  exit 1
fi

for file in "${yaml_files[@]}"; do
  # 1) PersistentVolumeClaim objects
  pvc_lines="$(
    yq eval-all -r '
      select(has("apiVersion") and has("kind") and .apiVersion == "v1" and .kind == "PersistentVolumeClaim") |
      [
        (.metadata.name // ""),
        (.metadata.labels."darksite.cloud/backup" // ""),
        (.metadata.labels."darksite.cloud/backup-skip-reason" // "")
      ] | @tsv
    ' "${file}"
  )" || {
    echo "FAIL: ${file}: yq parse failed" >&2
    failures=$((failures + 1))
    continue
  }

  while IFS=$'\t' read -r name backup_label skip_reason; do
    [ -n "${name}" ] || continue
    validate_backup_labels "${file}" "PersistentVolumeClaim/${name}" "${backup_label}" "${skip_reason}"
  done <<<"${pvc_lines}"

  # 2) StatefulSet volumeClaimTemplates
  sts_lines="$(
    yq eval-all -r '
      select(has("apiVersion") and has("kind") and .apiVersion == "apps/v1" and .kind == "StatefulSet") |
      .metadata.name as $sts |
      (.spec.volumeClaimTemplates // [])[] |
      [
        ($sts // ""),
        (.metadata.name // ""),
        (.metadata.labels."darksite.cloud/backup" // ""),
        (.metadata.labels."darksite.cloud/backup-skip-reason" // "")
      ] | @tsv
    ' "${file}"
  )" || {
    echo "FAIL: ${file}: yq parse failed" >&2
    failures=$((failures + 1))
    continue
  }

  while IFS=$'\t' read -r sts_name pvc_template_name backup_label skip_reason; do
    [ -n "${sts_name}" ] || continue
    [ -n "${pvc_template_name}" ] || continue
    validate_backup_labels "${file}" "StatefulSet/${sts_name} volumeClaimTemplates/${pvc_template_name}" "${backup_label}" "${skip_reason}"
  done <<<"${sts_lines}"

  # 3) CloudNativePG clusters: ensure generated PVCs are labeled via pvcTemplate
  cnpg_lines="$(
    yq eval-all -r '
      select(has("apiVersion") and has("kind") and (.apiVersion // "") | test("^postgresql\\.cnpg\\.io/") and .kind == "Cluster") |
      .metadata.name as $cluster |
      (
        (select(.spec.storage != null) | {
          "surface":"storage",
          "backup": (.spec.inheritedMetadata.labels."darksite.cloud/backup" // ""),
          "reason": (.spec.inheritedMetadata.labels."darksite.cloud/backup-skip-reason" // "")
        }) ,
        (select(.spec.walStorage != null) | {
          "surface":"walStorage",
          "backup": (.spec.inheritedMetadata.labels."darksite.cloud/backup" // ""),
          "reason": (.spec.inheritedMetadata.labels."darksite.cloud/backup-skip-reason" // "")
        })
      ) |
      [
        ($cluster // ""),
        (.surface // ""),
        (.backup // ""),
        (.reason // "")
      ] | @tsv
    ' "${file}"
  )" || {
    echo "FAIL: ${file}: yq parse failed" >&2
    failures=$((failures + 1))
    continue
  }

  while IFS=$'\t' read -r cluster_name surface backup_label skip_reason; do
    [ -n "${cluster_name}" ] || continue
    [ -n "${surface}" ] || continue
    validate_backup_labels "${file}" "Cluster/${cluster_name} ${surface} (spec.inheritedMetadata.labels)" "${backup_label}" "${skip_reason}"
  done <<<"${cnpg_lines}"
done

if [ "${failures}" -ne 0 ]; then
  echo "" >&2
  echo "pvc backup label lint FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "pvc backup label lint PASSED"
