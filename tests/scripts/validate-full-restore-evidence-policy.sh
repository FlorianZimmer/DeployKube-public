#!/usr/bin/env bash
# validate-full-restore-evidence-policy.sh
# Enforce monthly full-restore evidence freshness and marker-binding metadata.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

evidence_dir="docs/evidence"
max_age_seconds="${MAX_FULL_RESTORE_EVIDENCE_AGE_SECONDS:-2678400}"
required_deployments="${REQUIRED_FULL_RESTORE_EVIDENCE_DEPLOYMENTS:-proxmox-talos}"
strict_required="${REQUIRE_FULL_RESTORE_EVIDENCE_NOTES:-false}"

if ! [[ "${max_age_seconds}" =~ ^[0-9]+$ ]] || [[ "${max_age_seconds}" -le 0 ]]; then
  echo "error: MAX_FULL_RESTORE_EVIDENCE_AGE_SECONDS must be a positive integer (got '${max_age_seconds}')" >&2
  exit 1
fi

case "${strict_required}" in
  true|false) ;;
  *)
    echo "error: REQUIRE_FULL_RESTORE_EVIDENCE_NOTES must be true|false (got '${strict_required}')" >&2
    exit 1
    ;;
esac

python3 - "${evidence_dir}" "${max_age_seconds}" "${required_deployments}" "${strict_required}" <<'PY'
import datetime
import pathlib
import re
import sys

if len(sys.argv) != 5:
    print("internal error: expected 4 arguments", file=sys.stderr)
    sys.exit(1)

evidence_dir = pathlib.Path(sys.argv[1])
max_age_seconds = int(sys.argv[2])
required_deployments = [x.strip() for x in sys.argv[3].split(",") if x.strip()]
strict_required = sys.argv[4].strip().lower() == "true"

if not evidence_dir.is_dir():
    print(f"error: missing evidence directory: {evidence_dir}", file=sys.stderr)
    sys.exit(1)

required_fields = (
    "FullRestoreDeploymentId",
    "FullRestoreBackupSetId",
    "FullRestoreRestoredAt",
    "FullRestoreBackupSetManifestSha256",
)

sha_re = re.compile(r"^[0-9a-f]{64}$")
latest_by_deployment = {}
failures = []
checked = 0

for path in sorted(evidence_dir.glob("*.md")):
    if path.name == "README.md":
        continue
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    if "EvidenceFormat: v1" not in lines:
        continue
    if "EvidenceType: full-restore-drill-v1" not in lines:
        continue

    checked += 1
    fields = {}
    for line in lines:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        fields[key] = value

    missing = [k for k in required_fields if not fields.get(k)]
    if missing:
        failures.append(f"{path}: missing required field(s): {', '.join(missing)}")
        continue

    manifest_sha = fields["FullRestoreBackupSetManifestSha256"].strip().lower()
    if not sha_re.fullmatch(manifest_sha):
        failures.append(f"{path}: FullRestoreBackupSetManifestSha256 must be 64 lowercase hex characters")
        continue

    restored_raw = fields["FullRestoreRestoredAt"].strip()
    if restored_raw.endswith("Z"):
        restored_raw = restored_raw[:-1] + "+00:00"
    try:
        restored_at = datetime.datetime.fromisoformat(restored_raw)
    except Exception as exc:
        failures.append(f"{path}: invalid FullRestoreRestoredAt '{fields['FullRestoreRestoredAt']}': {exc}")
        continue
    if restored_at.tzinfo is None:
        restored_at = restored_at.replace(tzinfo=datetime.timezone.utc)

    deployment_id = fields["FullRestoreDeploymentId"].strip()
    backup_set_id = fields["FullRestoreBackupSetId"].strip()
    if not deployment_id:
        failures.append(f"{path}: FullRestoreDeploymentId must be non-empty")
        continue
    if not backup_set_id:
        failures.append(f"{path}: FullRestoreBackupSetId must be non-empty")
        continue

    current = latest_by_deployment.get(deployment_id)
    if current is None or restored_at > current["restored_at"]:
        latest_by_deployment[deployment_id] = {
            "path": str(path),
            "restored_at": restored_at,
            "backup_set_id": backup_set_id,
            "manifest_sha": manifest_sha,
        }

print("==> Full-restore evidence notes (v1)")
print(f"- Notes checked: {checked}")
print(f"- Required deployments: {', '.join(required_deployments) if required_deployments else '<none>'}")
print(f"- Max age (seconds): {max_age_seconds}")
print(f"- Strict required mode: {'true' if strict_required else 'false'}")

if checked == 0 and strict_required:
    failures.append("no full-restore evidence notes found (EvidenceType: full-restore-drill-v1)")
elif checked == 0:
    print("WARN: no typed full-restore evidence notes found yet; policy bootstrap mode permits this.")

now = datetime.datetime.now(datetime.timezone.utc)
for deployment_id in required_deployments:
    latest = latest_by_deployment.get(deployment_id)
    if latest is None:
        msg = f"missing full-restore evidence note for required deployment '{deployment_id}'"
        if strict_required:
            failures.append(msg)
        else:
            print(f"WARN: {msg}")
        continue

    age_seconds = int((now - latest["restored_at"]).total_seconds())
    if age_seconds < 0:
        failures.append(
            f"full-restore evidence for '{deployment_id}' is in the future: "
            f"{latest['restored_at'].isoformat()} ({latest['path']})"
        )
        continue
    if age_seconds > max_age_seconds:
        failures.append(
            f"stale full-restore evidence for '{deployment_id}': age={age_seconds}s "
            f"max={max_age_seconds}s file={latest['path']} "
            f"backupSetId={latest['backup_set_id']}"
        )
        continue

    print(
        f"PASS {deployment_id}: age={age_seconds}s "
        f"backupSetId={latest['backup_set_id']} file={latest['path']}"
    )

if failures:
    print("", file=sys.stderr)
    print("full-restore evidence policy FAILED", file=sys.stderr)
    for item in failures:
        print(f"- {item}", file=sys.stderr)
    sys.exit(1)

print("full-restore evidence policy PASSED")
PY
