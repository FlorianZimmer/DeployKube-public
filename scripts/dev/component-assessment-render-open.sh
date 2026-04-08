#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/component-assessment-render-open.sh --run-dir <dir> [--run-dir <dir> ...] [--model <model>] [--parallel <n>] [--codex-arg <arg>]

Renders a human-friendly (LLM-deduped) "Open" backlog section for component issue trackers based on the
machine-owned findings JSONL block in `docs/component-issues/<issue_slug>.md`.

This script:
- runs Codex in READ-ONLY mode (cannot modify repo files)
- writes the rendered markdown into a small marker-delimited block under `## Open`

Markers:
  <!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->
  <!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
model=""
parallel="2"
declare -a run_dirs=()
declare -a codex_extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      run_dirs+=("$2")
      shift 2
      ;;
    --model)
      model="$2"
      shift 2
      ;;
    --parallel)
      parallel="$2"
      shift 2
      ;;
    --codex-arg)
      codex_extra_args+=("$2")
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

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex not found in PATH" >&2
  exit 1
fi

if [[ -n "${model}" ]]; then
  codex_extra_args+=("-m" "${model}")
fi

REPO_ROOT="${repo_root}" \
PARALLEL="${parallel}" \
RUN_DIRS_NL="$(printf '%s\n' "${run_dirs[@]}")" \
CODEX_ARGS_NL="$(printf '%s\n' "${codex_extra_args[@]}")" \
python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any

OPEN_RENDER_BEGIN = "<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->"
OPEN_RENDER_END = "<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->"

FINDINGS_BEGIN = "<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->"
FINDINGS_END = "<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->"

SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}


@dataclass(frozen=True)
class ComponentTask:
    issue_slug: str
    tracker_path: Path


def read_index_issue_slugs(run_dir: Path) -> list[str]:
    idx = run_dir / "index.tsv"
    if not idx.is_file():
        raise FileNotFoundError(f"missing index.tsv: {idx}")
    slugs: list[str] = []
    for i, line in enumerate(idx.read_text(encoding="utf-8", errors="replace").splitlines()):
        if i == 0:
            continue
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        issue_slug = cols[1].strip()
        if issue_slug:
            slugs.append(issue_slug)
    return slugs


def ensure_open_render_block(text: str) -> str:
    if OPEN_RENDER_BEGIN in text and OPEN_RENDER_END in text:
        return text

    block = (
        "### Component Assessment Findings (Automated)\n\n"
        + OPEN_RENDER_BEGIN
        + "\n"
        + OPEN_RENDER_END
        + "\n"
    )

    m_open = re.search(r"^##\s+Open\s*$", text, flags=re.M)
    if m_open:
        insert_at = m_open.end()
        # Keep a blank line after header.
        prefix = text[:insert_at] + "\n\n"
        suffix = text[insert_at:]
        return prefix + block + "\n" + suffix.lstrip("\n")

    # Prefer inserting after a top-of-file "Design:" link block if present.
    m_design = re.search(r"^Design:\s*$", text, flags=re.M)
    if m_design:
        # Insert after contiguous "- ..." lines following "Design:".
        after = text[m_design.end() :]
        m_links = re.match(r"(?:\n- .*\n)+\n*", after)
        if m_links:
            insert_at = m_design.end() + m_links.end()
            prefix = text[:insert_at]
            suffix = text[insert_at:]
            return prefix.rstrip("\n") + "\n\n## Open\n\n" + block + "\n" + suffix.lstrip("\n")

    # Fallback: insert after H1 (or at start).
    m_h1 = re.search(r"^#\s+.*\s*$", text, flags=re.M)
    if m_h1:
        insert_at = m_h1.end()
        prefix = text[:insert_at] + "\n\n"
        suffix = text[insert_at:]
        return prefix + "## Open\n\n" + block + "\n" + suffix.lstrip("\n")

    return "## Open\n\n" + block + "\n" + text


def replace_between_markers(text: str, begin: str, end: str, body: str) -> str:
    if begin not in text or end not in text:
        raise ValueError("missing markers")
    pre, rest = text.split(begin, 1)
    _old, post = rest.split(end, 1)
    body = body.strip("\n")
    if body:
        body = "\n" + body + "\n"
    else:
        body = "\n"
    return pre + begin + body + end + post


def parse_tracker_findings_jsonl(text: str) -> list[dict[str, Any]]:
    if FINDINGS_BEGIN not in text or FINDINGS_END not in text:
        return []
    block = text.split(FINDINGS_BEGIN, 1)[1].split(FINDINGS_END, 1)[0]
    m = re.search(r"```jsonl\s*\n(.*?)\n```", block, flags=re.S)
    if not m:
        return []
    body = m.group(1)
    findings: list[dict[str, Any]] = []
    for line in body.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            findings.append(obj)
    return findings


def normalize_finding(f: dict[str, Any]) -> dict[str, Any]:
    out = dict(f)
    out["status"] = str(out.get("status", "open")).lower()
    out["severity"] = str(out.get("severity", "medium")).lower()
    out["class"] = str(out.get("class", "actionable")).lower()
    out["topic"] = str(out.get("topic", "")).strip()
    out["title"] = str(out.get("title", "")).strip()
    out["id"] = str(out.get("id", "")).strip()
    out["template_id"] = str(out.get("template_id", "")).strip()
    out["recommendation"] = str(out.get("recommendation", "")).strip()
    ev = out.get("evidence", [])
    if not isinstance(ev, list):
        ev = []
    out["evidence"] = ev
    return out


def sort_key(f: dict[str, Any]) -> tuple[Any, ...]:
    return (
        SEV_RANK.get(str(f.get("severity", "medium")).lower(), 9),
        str(f.get("topic", "")),
        str(f.get("class", "")),
        str(f.get("title", "")),
        str(f.get("id", "")),
    )


def build_llm_payload(findings: list[dict[str, Any]]) -> dict[str, Any]:
    norm = [normalize_finding(f) for f in findings]
    open_items = [f for f in norm if f.get("status") == "open"]
    suppressed = [f for f in norm if f.get("status") == "suppressed"]
    resolved = [f for f in norm if f.get("status") == "resolved"]
    open_items = sorted(open_items, key=sort_key)
    suppressed = sorted(suppressed, key=sort_key)
    resolved = sorted(resolved, key=sort_key)
    return {"open": open_items, "suppressed": suppressed, "resolved": resolved}


def run_codex_render(repo_root: Path, issue_slug: str, payload: dict[str, Any], codex_args: list[str]) -> str:
    tmp_dir = repo_root / "tmp" / "component-assessment" / "_render-open"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    schema_path = tmp_dir / f"{issue_slug}.schema.json"
    schema_path.write_text(
        json.dumps(
            {
                "type": "object",
                "additionalProperties": False,
                "required": ["markdown"],
                "properties": {"markdown": {"type": "string"}},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    prompt_path = tmp_dir / f"{issue_slug}.prompt.txt"
    prompt_path.write_text(
        (
            "You are generating a human-friendly backlog summary for a DeployKube component.\n"
            "\n"
            "Input is the machine-owned findings list grouped by status.\n"
            "\n"
            "Task:\n"
            "- Produce Markdown suitable to be placed inside a marker-delimited block under the component tracker `## Open`.\n"
            "- ONLY summarize `status=open` items (ignore suppressed/resolved in the output).\n"
            "- Deduplicate semantically: if multiple open findings describe the same underlying issue, merge into one bullet.\n"
            "  - When merging, include all relevant ids in one place, e.g. `(ids: `id1`, `id2`)`.\n"
            "- Keep it concise and actionable; preserve important qualifiers.\n"
            "- Use stable ordering: critical/high/medium/low first, then topic, then title.\n"
            "- Do not invent evidence. If evidence is empty, don't pretend it's present.\n"
            "- Do not include secret values; assume inputs are already redacted.\n"
            "\n"
            "Output format:\n"
            "- Return a JSON object that matches the provided output schema.\n"
            "- The `markdown` field MUST be a Markdown snippet (no outer code fences).\n"
            "- Use bullet lists. Prefer grouping by `topic` via `#### <topic>` headings when helpful.\n"
            "\n"
            "Findings payload (JSON):\n"
            + json.dumps(payload, sort_keys=True)
            + "\n"
        ),
        encoding="utf-8",
    )

    last_msg = tmp_dir / f"{issue_slug}.last-message.json"
    if last_msg.exists():
        last_msg.unlink()

    cmd = [
        "codex",
        "exec",
        "--cd",
        str(repo_root),
        "--sandbox",
        "read-only",
        "--ephemeral",
        "--output-schema",
        str(schema_path),
        "--output-last-message",
        str(last_msg),
        *codex_args,
        "-",
    ]
    env = os.environ.copy()
    env["OTEL_LOGS_EXPORTER"] = "none"
    env["OTEL_TRACES_EXPORTER"] = "none"
    env["OTEL_METRICS_EXPORTER"] = "none"
    env["OTEL_EXPORTER_OTLP_ENDPOINT"] = ""
    env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] = ""
    env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = ""
    env["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] = ""
    proc = subprocess.run(
        cmd,
        stdin=prompt_path.open("rb"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"codex exec failed for {issue_slug} (rc={proc.returncode})\n"
            + proc.stdout.decode("utf-8", errors="replace")
            + "\n"
            + proc.stderr.decode("utf-8", errors="replace")
        )

    if not last_msg.is_file():
        raise RuntimeError(f"missing --output-last-message file for {issue_slug}: {last_msg}")
    raw = last_msg.read_text(encoding="utf-8", errors="replace").strip()
    try:
        obj = json.loads(raw)
    except Exception as e:
        raise RuntimeError(f"invalid JSON from codex for {issue_slug}: {e}\n{raw[:400]}")
    md = obj.get("markdown", "")
    if not isinstance(md, str):
        raise RuntimeError(f"codex output markdown is not a string for {issue_slug}")
    return md


def update_tracker(tracker_path: Path, rendered_md: str) -> None:
    text = tracker_path.read_text(encoding="utf-8", errors="replace")
    text = ensure_open_render_block(text)
    out = replace_between_markers(text, OPEN_RENDER_BEGIN, OPEN_RENDER_END, rendered_md)

    # If the tracker used an "Open" placeholder (`- (none)`), drop it once we have an automated Open render block.
    # Keep any real human-authored Open items intact.
    m_open = re.search(r"^##\s+Open\s*$", out, flags=re.M)
    if m_open:
        start = m_open.start()
        m_next = re.search(r"^##\s+", out[m_open.end() :], flags=re.M)
        end = (m_open.end() + m_next.start()) if m_next else len(out)
        open_section = out[start:end]
        if OPEN_RENDER_BEGIN in open_section and OPEN_RENDER_END in open_section:
            open_section_clean = re.sub(r"^\s*-\s*\(none(?:\s+yet)?\)\s*$\n?", "", open_section, flags=re.M)
            out = out[:start] + open_section_clean + out[end:]

    if out != text:
        tracker_path.write_text(out, encoding="utf-8")


def main() -> int:
    repo_root = Path(os.environ["REPO_ROOT"])
    parallel = int(os.environ.get("PARALLEL", "2"))
    run_dirs = [Path(p) for p in os.environ.get("RUN_DIRS_NL", "").splitlines() if p.strip()]
    codex_args = [a for a in os.environ.get("CODEX_ARGS_NL", "").splitlines() if a.strip()]

    os.chdir(repo_root)

    issue_slugs: set[str] = set()
    for rd in run_dirs:
        if not rd.is_absolute():
            rd = (repo_root / rd).resolve()
        for slug in read_index_issue_slugs(rd):
            issue_slugs.add(slug)

    tasks: list[ComponentTask] = []
    for slug in sorted(issue_slugs):
        tracker = repo_root / "docs" / "component-issues" / f"{slug}.md"
        if not tracker.exists():
            print(f"WARNING: missing tracker: {tracker}", file=sys.stderr)
            continue
        tasks.append(ComponentTask(issue_slug=slug, tracker_path=tracker))

    if not tasks:
        print("No trackers to render (no issue_slugs found).")
        return 0

    def one(t: ComponentTask) -> str:
        text = t.tracker_path.read_text(encoding="utf-8", errors="replace")
        findings = parse_tracker_findings_jsonl(text)
        payload = build_llm_payload(findings)
        rendered = run_codex_render(repo_root, t.issue_slug, payload, codex_args)
        update_tracker(t.tracker_path, rendered)
        return t.issue_slug

    failures = 0
    with ThreadPoolExecutor(max_workers=max(1, parallel)) as ex:
        futs = {ex.submit(one, t): t for t in tasks}
        for fut in as_completed(futs):
            t = futs[fut]
            try:
                slug = fut.result()
                print(f"OK {slug}")
            except Exception as e:
                failures += 1
                print(f"ERROR {t.issue_slug}: {e}", file=sys.stderr)

    return 1 if failures else 0


raise SystemExit(main())
PY
