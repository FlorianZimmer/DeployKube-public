#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

python3 - <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

design_root = pathlib.Path("docs/design")
issues_root = pathlib.Path("docs/component-issues")

design_docs = sorted([p for p in design_root.glob("*.md") if p.name != "README.md"])

errors: list[str] = []

tracking_re = re.compile(
    r"^## Tracking\s*\n(?:\s*\n)?\s*-\s+Canonical tracker:\s+`?([^`\n]+)`?\s*$",
    re.M,
)

for doc in design_docs:
    txt = doc.read_text()

    if re.search(r"^\s*##\s+Implementation Checklist\b", txt, re.M):
        errors.append(f"{doc}: contains an Implementation Checklist (move to component issues tracker)")

    if re.search(r"^\s*-\s+\[( |x)\]\s+", txt, re.M):
        errors.append(f"{doc}: contains checklist items (move to component issues tracker)")

    m = tracking_re.search(txt)
    if not m:
        errors.append(f"{doc}: missing Tracking block")
        continue

    tracker_path = pathlib.Path(m.group(1).strip())
    if not tracker_path.exists():
        errors.append(f"{doc}: tracker does not exist: {tracker_path}")
        continue

    tracker_txt = tracker_path.read_text()
    if str(doc) not in tracker_txt:
        errors.append(f"{tracker_path}: missing backlink to {doc}")

if errors:
    print("validate-design-doc-tracking: FAIL", file=sys.stderr)
    for e in errors:
        print(f"- {e}", file=sys.stderr)
    sys.exit(1)

print(f"validate-design-doc-tracking: OK ({len(design_docs)} design docs)")
PY

