#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/component-assessment-promote.sh --run-dir <dir> [--run-dir <dir> ...] [--apply] [--today YYYY-MM-DD]

Promotes component-assessment outputs into the single canonical tracker per component:
- docs/component-issues/<issue_slug>.md

The tracker contains a machine-owned JSONL block delimited by:
  <!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->
  <!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->

This script is deterministic and does NOT require an LLM.
See docs/component-issues/SCHEMA.md
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
apply="false"
today="$(date -u +%Y-%m-%d)"
declare -a run_dirs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      run_dirs+=("$2")
      shift 2
      ;;
    --apply)
      apply="true"
      shift
      ;;
    --today)
      today="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ ${#run_dirs[@]} -eq 0 ]]; then
  echo "ERROR: at least one --run-dir is required" >&2
  exit 2
fi

REPO_ROOT="${repo_root}" \
TODAY="${today}" \
APPLY="${apply}" \
DK_PROMOTE_DEBUG="${DK_PROMOTE_DEBUG:-0}" \
RUN_DIRS_NL="$(printf '%s\n' "${run_dirs[@]}")" \
python3 - <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

FINDINGS_BEGIN = "<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->"
FINDINGS_END = "<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->"


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def normalize_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def compute_finding_id(component_slug: str, template_id: str, f: dict[str, Any]) -> str:
    # Stable id should not depend on prose. Prefer evidence anchors; fall back to title if necessary.
    parts: list[str] = [
        "dk.ca.finding.v1",
        component_slug,
        template_id,
        str(f.get("class", "")).lower(),
        str(f.get("severity", "")).lower(),
    ]

    evidence = f.get("evidence")
    ev_anchors: list[str] = []
    if isinstance(evidence, list):
        for ev in evidence:
            if isinstance(ev, dict):
                p = normalize_ws(str(ev.get("path", "")))
                r = normalize_ws(str(ev.get("resource", "")))
                k = normalize_ws(str(ev.get("key", "")))
                if p or r or k:
                    ev_anchors.append("|".join([p, r, k]))
            elif isinstance(ev, str):
                s = normalize_ws(ev)
                if s:
                    ev_anchors.append(s)
    ev_anchors = sorted(set([a for a in ev_anchors if a]))
    if ev_anchors:
        parts.extend(ev_anchors)
    else:
        parts.append("title:" + normalize_ws(str(f.get("title", ""))))

    digest = sha256_hex("\\n".join(parts))
    return f"dk.ca.finding.v1:{component_slug}:{digest}"


def parse_findings_new_schema(text: str) -> tuple[bool, list[dict[str, Any]], list[str]]:
    """
    Parse the v1 assessment result format.

    Important: workpacks may include a result skeleton header. Some LLM runs append the real output after the skeleton
    instead of overwriting the file. To keep promotion robust, we anchor parsing on the *selected* Relevance block and
    only consider the `Findings (JSONL):` section that follows it.
    """

    selected_rel = None
    selected_val = ""
    for m in re.finditer(r"^Relevance:\s*(.+)\s*$", text, flags=re.M):
        v = m.group(1).strip().lower()
        if v.startswith("na") or v.startswith("applicable"):
            selected_rel = m
            selected_val = v

    if not selected_rel:
        return False, [], ["missing Relevance:"]

    if selected_val.startswith("na"):
        return False, [], []

    if not selected_val.startswith("applicable"):
        return False, [], [f"unexpected Relevance: {selected_val}"]

    tail = text[selected_rel.end() :]
    m_find = re.search(r"^Findings \(JSONL\):\s*$", tail, flags=re.M)
    if not m_find:
        return True, [], ["missing Findings (JSONL):"]

    findings: list[dict[str, Any]] = []
    errors: list[str] = []
    after = tail[m_find.end() :]
    for line in after.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except Exception as e:
            errors.append(f"invalid JSONL line: {line[:160]} ({e})")
            continue
        if not isinstance(obj, dict):
            errors.append(f"JSONL line is not an object: {line[:160]}")
            continue
        findings.append(obj)
    return True, findings, errors


def _extract_repo_paths(s: str) -> list[str]:
    # Conservative: only keep repo-relative looking paths.
    # Examples in legacy outputs: platform/gitops/.../values.yaml, tools/.../main.go, docs/.../README.md
    paths = re.findall(r"\b(?:docs|platform|bootstrap|scripts|shared|tools)/[A-Za-z0-9_./-]+\.(?:md|yaml|yml|json|sh|bash|go|py|ts|tsx|js|jsx|toml)\b", s)
    return sorted(set(paths))


def parse_findings_legacy_schema(text: str, default_track_in: str) -> tuple[bool, list[dict[str, Any]], list[str]]:
    """
    Parse legacy (pre-JSONL) assessment outputs:
    - Actionable Improvements / Architectural Problems sections with Evidence/Fix/Risk/Refactor direction/Track in lines.
    """

    selected_rel = None
    selected_val = ""
    for m in re.finditer(r"^Relevance:\s*(.+)\s*$", text, flags=re.M):
        v = m.group(1).strip().lower()
        if v.startswith("na") or v.startswith("applicable"):
            selected_rel = m
            selected_val = v

    if not selected_rel:
        return False, [], ["missing Relevance:"]
    if selected_val.startswith("na"):
        return False, [], []
    if not selected_val.startswith("applicable"):
        return False, [], [f"unexpected Relevance: {selected_val}"]

    tail = text[selected_rel.end() :]

    def section_body(name: str) -> str:
        # Capture from "<name>:" until next top-level section header or end.
        m = re.search(rf"^{re.escape(name)}:\s*$", tail, flags=re.M)
        if not m:
            return ""
        after = tail[m.end() :]
        # Stop at next "Architectural Problems:" or "Actionable Improvements:" or end.
        m_stop = re.search(r"^(Actionable Improvements|Architectural Problems):\s*$", after, flags=re.M)
        body = after[: m_stop.start()] if m_stop else after
        return body.strip("\n")

    findings: list[dict[str, Any]] = []
    errors: list[str] = []

    def parse_section(name: str, cls: str) -> None:
        body = section_body(name)
        if not body:
            return
        if body.strip().lower().startswith("none"):
            return
        if body.strip().lower().startswith("na"):
            return

        # Each item starts with "1. [Severity: X] Title"
        item_re = re.compile(r"^\s*(\d+)\.\s*\[Severity:\s*([^\]]+)\]\s*(.+?)\s*$", flags=re.M)
        matches = list(item_re.finditer(body))
        for idx, m in enumerate(matches):
            sev = m.group(2).strip().lower()
            title = m.group(3).strip()

            start = m.end()
            end = matches[idx + 1].start() if idx + 1 < len(matches) else len(body)
            chunk = body[start:end].strip("\n").strip()

            ev_text = ""
            fix_text = ""
            risk_text = ""
            track_in = default_track_in

            for line in chunk.splitlines():
                line = line.strip()
                if line.startswith("Evidence:"):
                    ev_text = line[len("Evidence:") :].strip()
                elif line.startswith("Fix:"):
                    fix_text = line[len("Fix:") :].strip()
                elif line.startswith("Refactor direction:"):
                    fix_text = line[len("Refactor direction:") :].strip()
                elif line.startswith("Risk:"):
                    risk_text = line[len("Risk:") :].strip()
                elif line.startswith("Track in:"):
                    track_in = line[len("Track in:") :].strip() or default_track_in

            # Collapse any arch-problems trackers into the single component tracker.
            if track_in.endswith("-arch-problems.md"):
                track_in = track_in.replace("-arch-problems.md", ".md")

            evidence: list[dict[str, str]] = []
            for p in _extract_repo_paths(ev_text):
                evidence.append({"path": p, "resource": "", "key": ""})

            findings.append(
                {
                    "class": cls,
                    "severity": sev,
                    "title": title,
                    "evidence": evidence,
                    "risk": risk_text if cls == "architectural" else "",
                    "recommendation": fix_text,
                    "track_in": track_in,
                    "details": "" if not chunk else chunk,
                }
            )

    parse_section("Actionable Improvements", "actionable")
    parse_section("Architectural Problems", "architectural")

    return True, findings, errors


def read_index_components(run_dir: Path) -> list[tuple[str, str, Path]]:
    idx = run_dir / "index.tsv"
    if not idx.is_file():
        raise FileNotFoundError(f"missing index.tsv: {idx}")
    out: list[tuple[str, str, Path]] = []
    raw_lines = idx.read_text(encoding="utf-8").splitlines()
    if os.environ.get("DK_PROMOTE_DEBUG", "0") == "1":
        print("debug_index_path=" + str(idx))
        print("debug_index_lines=" + str(len(raw_lines)))
        for preview in raw_lines[:3]:
            print("debug_index_line=" + preview)
    for i, line in enumerate(raw_lines):
        if i == 0:
            continue
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) < 4:
            continue
        component_id, issue_slug, _primary_path, workpack_dir = cols[:4]
        out.append((component_id, issue_slug, Path(workpack_dir)))
    return out


def ensure_tracker_has_block(tracker_text: str) -> str:
    if FINDINGS_BEGIN in tracker_text and FINDINGS_END in tracker_text:
        return tracker_text

    if not tracker_text.endswith("\n"):
        tracker_text += "\n"
    tracker_text += "\n## Component Assessment Findings (v1)\n\n"
    tracker_text += FINDINGS_BEGIN + "\n"
    tracker_text += "```jsonl\n"
    tracker_text += "```\n"
    tracker_text += FINDINGS_END + "\n"
    return tracker_text


def parse_tracker_findings(tracker_text: str) -> tuple[list[dict[str, Any]], list[str]]:
    if FINDINGS_BEGIN not in tracker_text or FINDINGS_END not in tracker_text:
        return [], []
    block = tracker_text.split(FINDINGS_BEGIN, 1)[1].split(FINDINGS_END, 1)[0]
    # Be tolerant: accept an empty JSONL fenced block and avoid brittle regex assumptions about newline placement.
    start = block.find("```jsonl")
    if start < 0:
        return [], ["missing ```jsonl fenced block inside findings markers"]
    start_nl = block.find("\n", start)
    if start_nl < 0:
        return [], ["malformed ```jsonl fence (missing newline)"]
    m_end = re.search(r"^```\s*$", block[start_nl + 1 :], flags=re.M)
    if not m_end:
        return [], ["malformed ```jsonl fence (missing closing ``` line)"]
    end_at = start_nl + 1 + m_end.start()
    body = block[start_nl + 1 : end_at]
    findings: list[dict[str, Any]] = []
    errors: list[str] = []
    for line in body.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except Exception as e:
            errors.append(f"invalid JSONL in tracker: {line[:160]} ({e})")
            continue
        if isinstance(obj, dict):
            findings.append(obj)
        else:
            errors.append(f"tracker JSONL line is not object: {line[:160]}")
    return findings, errors


def replace_tracker_block(tracker_text: str, findings: list[dict[str, Any]]) -> str:
    tracker_text = ensure_tracker_has_block(tracker_text)
    pre, rest = tracker_text.split(FINDINGS_BEGIN, 1)
    _old, post = rest.split(FINDINGS_END, 1)

    jsonl = "\n".join(json.dumps(f, sort_keys=True) for f in findings)
    new_block = "\n```jsonl\n" + (jsonl + "\n" if jsonl else "") + "```\n"
    return pre + FINDINGS_BEGIN + new_block + FINDINGS_END + post


def main() -> int:
    repo_root = Path(os.environ["REPO_ROOT"])
    today = os.environ["TODAY"]
    apply = os.environ.get("APPLY", "false").lower() == "true"
    debug = os.environ.get("DK_PROMOTE_DEBUG", "0") == "1"
    run_dirs = [Path(p) for p in os.environ.get("RUN_DIRS_NL", "").splitlines() if p.strip()]

    # Make relative paths in index.tsv/workpack_dir resolve deterministically.
    os.chdir(repo_root)
    if debug:
        print("debug_run_dirs=" + repr([str(p) for p in run_dirs]))
        print("debug_cwd=" + os.getcwd())

    per_component: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    parse_errors_total = 0

    for run_dir in run_dirs:
        parse_errors: list[str] = []
        if not run_dir.is_absolute():
            run_dir = (repo_root / run_dir).resolve()
        promotion_dir = run_dir / "promotion"
        promotion_dir.mkdir(parents=True, exist_ok=True)
        if debug:
            print("debug_run_dir_resolved=" + str(run_dir))

        for _component_id, issue_slug, workpack_dir in read_index_components(run_dir):
            if not workpack_dir.is_absolute():
                workpack_dir = (repo_root / workpack_dir).resolve()
            results_dir = workpack_dir / "outputs" / "category-results"
            if debug:
                print(f"debug component={issue_slug} results_dir={results_dir} is_dir={results_dir.is_dir()}")
            if not results_dir.is_dir():
                continue

            for result_file in sorted(results_dir.glob("*.md")):
                template_id = result_file.name
                text = result_file.read_text(encoding="utf-8", errors="replace")
                applicable, findings, errs = parse_findings_new_schema(text)
                if applicable and ("missing Findings (JSONL):" in errs):
                    # Fallback for older workpacks/results that used Actionable Improvements / Architectural Problems.
                    applicable, findings, legacy_errs = parse_findings_legacy_schema(
                        text, default_track_in=f"docs/component-issues/{issue_slug}.md"
                    )
                    errs = legacy_errs
                for e in errs:
                    parse_errors.append(f"{result_file}: {e}")
                if not applicable:
                    continue

                topic = ""
                m_topic = re.search(r"^Topic:\s*(.+)\s*$", text, flags=re.M)
                if m_topic:
                    topic = m_topic.group(1).strip()
                topic_slug = normalize_ws(topic).lower().replace(" ", "-")

                for f in findings:
                    f.setdefault("topic", topic_slug)
                    f.setdefault("template_id", template_id)
                    f.setdefault("evidence", [])
                    f.setdefault("recommendation", f.get("recommendation", ""))
                    f.setdefault("track_in", f.get("track_in") or f"docs/component-issues/{issue_slug}.md")

                    fid = compute_finding_id(issue_slug, template_id, f)
                    f["id"] = fid
                    per_component.setdefault(issue_slug, []).append((template_id, f))

        if parse_errors:
            parse_errors_total += len(parse_errors)
            (promotion_dir / "parse-errors.txt").write_text("\n".join(parse_errors) + "\n", encoding="utf-8")

    candidates_root = repo_root / "tmp" / "component-assessment" / "promotion-candidates"
    candidates_root.mkdir(parents=True, exist_ok=True)

    updated = 0
    sev_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3}

    for issue_slug, items in sorted(per_component.items()):
        tracker_path = repo_root / "docs" / "component-issues" / f"{issue_slug}.md"
        tracker_text = tracker_path.read_text(encoding="utf-8", errors="replace") if tracker_path.exists() else f"# {issue_slug} Component Issues\\n"
        tracker_text = ensure_tracker_has_block(tracker_text)

        existing, existing_errs = parse_tracker_findings(tracker_text)
        if existing_errs:
            preview = ""
            if FINDINGS_BEGIN in tracker_text and FINDINGS_END in tracker_text:
                block = tracker_text.split(FINDINGS_BEGIN, 1)[1].split(FINDINGS_END, 1)[0]
                preview = block.replace("\n", "\\n")[:200]
            raise SystemExit(
                f"Tracker {tracker_path} has malformed findings block: {existing_errs}"
                + (f" (block_preview={preview})" if preview else "")
            )

        by_id: dict[str, dict[str, Any]] = {}
        for f in existing:
            fid = str(f.get("id", "")).strip()
            if fid:
                by_id[fid] = f

        new_findings: list[dict[str, Any]] = []
        for _template_id, f in items:
            fid = str(f.get("id", "")).strip()
            if not fid:
                continue
            if fid in by_id:
                by_id[fid]["last_seen_at"] = today
                continue

            rec: dict[str, Any] = {
                "id": fid,
                "status": "open",
                "class": str(f.get("class", "actionable")).lower(),
                "severity": str(f.get("severity", "medium")).lower(),
                "title": str(f.get("title", "")).strip(),
                "topic": str(f.get("topic", "")).strip(),
                "template_id": str(f.get("template_id", "")).strip(),
                "evidence": f.get("evidence", []),
                "details": str(f.get("details", "")).strip(),
                "risk": str(f.get("risk", "")).strip(),
                "recommendation": str(f.get("recommendation", "")).strip(),
                "track_in": str(f.get("track_in", f"docs/component-issues/{issue_slug}.md")).strip(),
                "first_seen_at": today,
                "last_seen_at": today,
            }
            new_findings.append(rec)
            by_id[fid] = rec

        if new_findings:
            (candidates_root / f"{issue_slug}.new.jsonl").write_text(
                "\n".join(json.dumps(c, sort_keys=True) for c in new_findings) + "\n",
                encoding="utf-8",
            )
            md_lines = [f"# {issue_slug}: New Findings", ""]
            for c in new_findings:
                md_lines.append(f"- [{c.get('severity','')}] ({c.get('class','')}) {c.get('title','').strip()}")
                md_lines.append(f"  id: `{c.get('id','')}`")
                md_lines.append(f"  template_id: `{c.get('template_id','')}`")
            (candidates_root / f"{issue_slug}.new.md").write_text("\n".join(md_lines) + "\n", encoding="utf-8")

        def sort_key(o: dict[str, Any]):
            return (
                str(o.get("status", "open")),
                sev_rank.get(str(o.get("severity", "medium")).lower(), 9),
                str(o.get("title", "")),
                str(o.get("id", "")),
            )

        merged = sorted(by_id.values(), key=sort_key)

        if apply:
            tracker_out = replace_tracker_block(tracker_text, merged)
            if tracker_out != tracker_text:
                tracker_path.write_text(tracker_out, encoding="utf-8")
                updated += 1

    print(f"apply={apply} updated_trackers={updated}")
    print("candidates_dir=" + str(candidates_root))
    print("components_with_findings=" + str(len(per_component)))
    if parse_errors_total:
        print(
            f"WARNING: parse_errors={parse_errors_total} (see each <run-dir>/promotion/parse-errors.txt)",
            file=sys.stderr,
        )
    if debug:
        print("debug_enabled=true")
    return 0


raise SystemExit(main())
PY

echo "Promotion done. Candidates under: tmp/component-assessment/promotion-candidates/"
