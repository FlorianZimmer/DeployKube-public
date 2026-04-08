#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FINDINGS_BEGIN = "<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:BEGIN -->"
FINDINGS_END = "<!-- DK:COMPONENT_ISSUES_FINDINGS_V1:END -->"

OPEN_RENDER_BEGIN = "<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:BEGIN -->"
OPEN_RENDER_END = "<!-- DK:COMPONENT_ISSUES_OPEN_RENDER_V1:END -->"


def today_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def slugify(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s or "general"


def strip_md(s: str) -> str:
    s = s.strip()
    s = re.sub(r"^\s*[-*]\s*", "", s)
    s = re.sub(r"^\s*[-*]\s*\[[ xX]\]\s*", "", s)
    s = re.sub(r"^\s*\d+\.\s*", "", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
    s = re.sub(r"_([^_]+)_", r"\1", s)
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def infer_severity(topic: str, title: str) -> str:
    t = (topic + " " + title).lower()
    if any(k in t for k in ["critical", "breakglass", "data loss", "root of trust"]):
        return "high"
    if any(k in t for k in ["security", "rbac", "auth", "oidc", "secrets", "tls", "pki"]):
        return "high"
    if any(k in t for k in ["ha", "high-availability", "pdb", "disruption", "outage"]):
        return "high"
    return "medium"


def extract_links(text: str) -> list[str]:
    # Keep links repo-relative and stable; primarily evidence/design paths.
    links = set()
    # Note: keep '-' last in the class to avoid range parsing issues.
    for m in re.finditer(r"\b(docs/(?:evidence|design|runbooks|guides|toils|apis)/[A-Za-z0-9_./-]+\.md)\b", text):
        links.add(m.group(1))
    return sorted(links)


@dataclass
class ParsedItem:
    status: str  # open|resolved
    topic: str
    legacy_id: str
    title: str
    details_md: str


OPEN_H2_RE = re.compile(r"^##\s+Open(?:\s+Items)?(?:\s*\\(.*\\))?\s*$", re.M)
RESOLVED_H2_RE = re.compile(r"^##\s+Resolved(?:\s+Items)?\s*$", re.M)
H2_RE = re.compile(r"^##\s+.+\s*$", re.M)
H3_RE = re.compile(r"^###\s+(.+?)\s*$", re.M)


def find_section_bounds(text: str, h2_pat: re.Pattern[str]) -> tuple[int, int] | None:
    m = h2_pat.search(text)
    if not m:
        return None
    start = m.start()
    # End at next H2 or EOF.
    m2 = H2_RE.search(text, m.end())
    end = m2.start() if m2 else len(text)
    return (start, end)


def parse_pipe_table(lines: list[str]) -> list[tuple[str, str, str]]:
    """
    Parse a simple markdown pipe table into rows.
    Returns list of (col1, col2, col3) strings for non-header rows.
    """
    # Find header and separator.
    if len(lines) < 2:
        return []
    hdr = lines[0]
    sep = lines[1]
    if not (hdr.startswith("|") and "|" in hdr and sep.startswith("|") and re.search(r"\|\s*-", sep)):
        return []

    def split_row(row: str) -> list[str]:
        row = row.strip()
        if row.startswith("|"):
            row = row[1:]
        if row.endswith("|"):
            row = row[:-1]
        return [c.strip() for c in row.split("|")]

    hdr_cols = split_row(hdr)
    # Expect at least Summary/Notes; accept arbitrary layout.
    idx_summary = None
    idx_notes = None
    idx_id = None
    for i, c in enumerate(hdr_cols):
        lc = c.lower()
        if lc == "summary":
            idx_summary = i
        if lc == "notes" or lc == "resolution":
            idx_notes = i
        if lc == "id" or lc == "date":
            idx_id = i

    rows: list[tuple[str, str, str]] = []
    for row in lines[2:]:
        if not row.strip().startswith("|"):
            break
        cols = split_row(row)
        if idx_summary is None or idx_summary >= len(cols):
            continue
        summary = cols[idx_summary].strip()
        notes = cols[idx_notes].strip() if idx_notes is not None and idx_notes < len(cols) else ""
        rid = cols[idx_id].strip() if idx_id is not None and idx_id < len(cols) else ""
        rows.append((rid, summary, notes))
    return rows


def parse_open_items(section_text: str, default_topic: str = "general") -> list[ParsedItem]:
    """
    Best-effort extraction of open items from legacy trackers.
    Handles:
    - bullet lists under optional H3 topic headings
    - checklists (- [ ] / - [x]) in Open section
    - simple pipe tables (e.g., Vault)
    """
    items: list[ParsedItem] = []
    topic = default_topic

    lines = section_text.splitlines()
    # Skip the first "## Open..." header line.
    if lines and lines[0].lstrip().startswith("## "):
        lines = lines[1:]

    # Table mode (common in vault.md).
    # Detect a table early in the section (after blank lines and optional blockquotes/hr).
    scan = [ln for ln in lines if ln.strip() and not ln.strip().startswith(">") and ln.strip() != "---"]
    if scan and scan[0].lstrip().startswith("|"):
        rows = parse_pipe_table(scan)
        for rid, summary, notes in rows:
            title = strip_md(summary)
            if not title or title.lower() in {"(none)", "none", "(none yet)"}:
                continue
            legacy_id = strip_md(rid)
            details = f"{summary}"
            if notes:
                details += "\n\n" + notes
            items.append(
                ParsedItem(
                    status="open",
                    topic=default_topic,
                    legacy_id=legacy_id,
                    title=title if not legacy_id else f"{legacy_id} {title}".strip(),
                    details_md=details.strip(),
                )
            )
        if items:
            return items

    # Bullet / heading mode.
    i = 0
    while i < len(lines):
        ln = lines[i]
        m3 = H3_RE.match(ln)
        if m3:
            topic = slugify(m3.group(1))
            i += 1
            continue

        # Identify a new *top-level* item (nested bullets belong to details of the parent).
        m_item = re.match(r"^[-*]\s+(\[[ xX]\]\s+)?(.+)$", ln)
        if not m_item:
            i += 1
            continue

        raw = ln.strip()
        checked = bool(m_item.group(1) and "x" in m_item.group(1).lower())
        status = "resolved" if checked else "open"
        title = strip_md(raw)
        if not title or title.lower() in {"(none)", "none", "(none yet)"}:
            i += 1
            continue

        details_lines = [raw]
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if H3_RE.match(nxt) or H2_RE.match(nxt):
                break
            if re.match(r"^[-*]\s+(\[[ xX]\]\s+)?", nxt):
                break
            # Keep nested content (indent, blank, paragraphs).
            details_lines.append(nxt.rstrip())
            i += 1

        details_md = "\n".join(details_lines).strip("\n")
        items.append(
            ParsedItem(
                status=status,
                topic=topic,
                legacy_id="",
                title=title,
                details_md=details_md,
            )
        )

    return items


def compute_legacy_finding_id(component_slug: str, template_id: str, item: ParsedItem) -> str:
    parts = [
        "dk.ca.finding.v1",
        component_slug,
        template_id,
        "actionable",
        infer_severity(item.topic, item.title),
        item.topic,
    ]
    if item.legacy_id:
        parts.append("legacy_id:" + item.legacy_id)
    else:
        parts.append("title:" + strip_md(item.title).lower())
    digest = sha256_hex("\n".join(parts))
    return f"dk.ca.finding.v1:{component_slug}:{digest}"


def build_findings(component_slug: str, items: list[ParsedItem], stamp: str) -> list[dict[str, Any]]:
    template_id = "legacy-component-issues.md"
    out: list[dict[str, Any]] = []
    for it in items:
        sev = infer_severity(it.topic, it.title)
        fid = compute_legacy_finding_id(component_slug, template_id, it)
        obj: dict[str, Any] = {
            "id": fid,
            "status": it.status,
            "class": "actionable",
            "severity": sev,
            "title": it.title,
            "topic": it.topic,
            "template_id": template_id,
            "recommendation": it.title,
            "first_seen_at": stamp,
            "last_seen_at": stamp,
            "details": it.details_md.strip(),
        }
        links = extract_links(it.details_md)
        if links:
            obj["links"] = links
        if it.legacy_id:
            obj["legacy_id"] = it.legacy_id
        out.append(obj)
    return out


def render_open_from_findings(findings: list[dict[str, Any]]) -> str:
    # Deterministic non-LLM summary: group open items by severity and topic.
    sev_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    open_items = [f for f in findings if str(f.get("status", "open")).lower() == "open"]
    open_items.sort(
        key=lambda f: (
            sev_rank.get(str(f.get("severity", "medium")).lower(), 9),
            str(f.get("topic", "")),
            str(f.get("title", "")),
            str(f.get("id", "")),
        )
    )
    if not open_items:
        return "- (none)\n"

    parts: list[str] = []
    cur_sev = None
    cur_topic = None
    for f in open_items:
        sev = str(f.get("severity", "medium")).lower()
        topic = str(f.get("topic", "general")) or "general"
        if sev != cur_sev:
            parts.append(f"### {sev.capitalize()}")
            parts.append("")
            cur_sev = sev
            cur_topic = None
        if topic != cur_topic:
            parts.append(f"#### {topic}")
            cur_topic = topic
        title = str(f.get("title", "")).strip()
        fid = str(f.get("id", "")).strip()
        if fid:
            parts.append(f"- {title} (ids: `{fid}`)")
        else:
            parts.append(f"- {title}")
        parts.append("")

    return "\n".join([p.rstrip() for p in parts]).rstrip() + "\n"


def ensure_open_section(text: str, open_body_md: str, notes_md: str | None = None) -> str:
    """
    Replace the first legacy Open section body with the standard Open render block
    and keep the rest of the file intact.
    If no Open section exists, insert one after a Design block (or after H1).
    """
    block = (
        "### Component Assessment Findings (Automated)\n\n"
        + OPEN_RENDER_BEGIN
        + "\n"
        + open_body_md.rstrip("\n")
        + "\n"
        + OPEN_RENDER_END
        + "\n"
    )
    if notes_md and notes_md.strip():
        block += "\n### Notes\n\n" + notes_md.strip() + "\n"

    bounds = find_section_bounds(text, OPEN_H2_RE)
    if bounds:
        start, end = bounds
        # Normalize header to "## Open".
        header_line = "## Open\n"
        after = text[end:]
        return text[:start] + header_line + "\n" + block + "\n" + after.lstrip("\n")

    # Insert near top.
    m_design = re.search(r"^Design:\s*$", text, flags=re.M)
    if m_design:
        after = text[m_design.end() :]
        m_links = re.match(r"(?:\n- .*\n)+\n*", after)
        if m_links:
            insert_at = m_design.end() + m_links.end()
            prefix = text[:insert_at].rstrip("\n")
            suffix = text[insert_at:].lstrip("\n")
            return prefix + "\n\n## Open\n\n" + block + "\n" + suffix

    m_h1 = re.search(r"^#\s+.*\s*$", text, flags=re.M)
    if m_h1:
        insert_at = m_h1.end()
        prefix = text[:insert_at].rstrip("\n")
        suffix = text[insert_at:].lstrip("\n")
        return prefix + "\n\n## Open\n\n" + block + "\n" + suffix

    return "## Open\n\n" + block + "\n" + text


def insert_findings_block(text: str, findings: list[dict[str, Any]]) -> str:
    if FINDINGS_BEGIN in text and FINDINGS_END in text:
        return text

    body = "\n".join(json.dumps(f, sort_keys=True) for f in findings).rstrip()
    fenced = "```jsonl\n" + body + ("\n" if body else "") + "```\n"

    section = (
        "## Component Assessment Findings (v1)\n\n"
        "Canonical, automatable issue list for this component (single tracker file).\n"
        "Schema: `docs/component-issues/SCHEMA.md`\n\n"
        + FINDINGS_BEGIN
        + "\n"
        + fenced
        + FINDINGS_END
        + "\n"
    )

    # Insert before "## Resolved" if present, otherwise append.
    m_res = RESOLVED_H2_RE.search(text)
    if m_res:
        return text[: m_res.start()].rstrip("\n") + "\n\n" + section + "\n" + text[m_res.start():].lstrip("\n")
    return text.rstrip("\n") + "\n\n" + section


def migrate_text(component_slug: str, base_text: str, stamp: str) -> str:
    # Parse OPEN items from the legacy base_text.
    # Many trackers keep follow-ups under "Deferred"/"Backlog"/"Future" instead of "Open", so we
    # treat those as open-ish sources as well.
    open_items: list[ParsedItem] = []
    open_notes: str | None = None

    def iter_h2_sections(text: str) -> list[tuple[str, str]]:
        ms = list(re.finditer(r"^##\s+(.+?)\s*$", text, flags=re.M))
        out: list[tuple[str, str]] = []
        for i, m in enumerate(ms):
            start = m.start()
            end = ms[i + 1].start() if i + 1 < len(ms) else len(text)
            out.append((m.group(1).strip(), text[start:end]))
        return out

    def is_openish_h2(title: str) -> bool:
        t = title.strip().lower()
        if t.startswith("resolved"):
            return False
        if t.startswith("evidence"):
            return False
        if t == "design":
            return False
        return bool(re.match(r"^(open(\s+items)?|deferred|backlog|follow-?ups?|future|milestones|roadmap)\b", t))

    def normalize_none_token(line: str) -> str:
        s = strip_md(line).strip()
        # Handle simple emphasis like *None.* and _None_.
        s = s.strip("*_").strip()
        s = s.lower()
        if s.startswith("(") and s.endswith(")"):
            s = s[1:-1].strip()
            s = s.strip("*_").strip()
        s = re.sub(r"[.]+$", "", s).strip()
        return s

    def is_empty_open_body(body_md: str) -> bool:
        keep: list[str] = []
        for ln in body_md.splitlines():
            if not ln.strip():
                continue
            if ln.strip() == "---":
                continue
            if re.match(r"^###\s+", ln):
                continue
            if ln.strip() in {"- (none)", "- (none yet)"}:
                continue
            tok = normalize_none_token(ln)
            if tok in {"none", "none yet", "none currently"}:
                continue
            keep.append(tok)
        return len(keep) == 0

    def is_none_with_notes(body_md: str) -> bool:
        for ln in body_md.splitlines():
            if not ln.strip():
                continue
            if ln.strip() in {"---", "- (none)", "- (none yet)"}:
                continue
            if re.match(r"^###\s+", ln):
                continue
            tok = normalize_none_token(ln)
            return tok.startswith("none")
        return False

    for title, sec in iter_h2_sections(base_text):
        if not is_openish_h2(title):
            continue
        dt = "general" if title.lower().startswith("open") else slugify(title)
        items = parse_open_items(sec, default_topic=dt)

        if title.lower().startswith("open") and not items:
            # Preserve "None. (...)" notes from the legacy Open section without turning it into a finding.
            lines = sec.splitlines()
            if lines and lines[0].lstrip().startswith("## "):
                lines = lines[1:]
            body = "\n".join(lines).strip()
            if is_none_with_notes(body):
                # Only keep notes if there's real content beyond a plain "(none)" placeholder.
                if not is_empty_open_body(body):
                    open_notes = body
            elif not is_empty_open_body(body):
                # If Open contains substantive content but we can't parse items, keep it as one finding.
                items = [
                    ParsedItem(
                        status="open",
                        topic="general",
                        legacy_id="",
                        title="Legacy open section (unparsed)",
                        details_md=body,
                    )
                ]

        open_items.extend(items)

    findings = build_findings(component_slug, open_items, stamp)
    open_render_md = render_open_from_findings(findings)

    out = base_text
    out = ensure_open_section(out, open_render_md, notes_md=open_notes)
    out = insert_findings_block(out, findings)
    return out


def migrate_file(path: Path, stamp: str) -> tuple[bool, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.name == "SCHEMA.md":
        return False, text
    if FINDINGS_BEGIN in text:
        return False, text

    component_slug = path.stem
    out = migrate_text(component_slug, text, stamp)
    return (out != text), out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--apply", action="store_true", help="Write changes to disk")
    ap.add_argument(
        "--force-from-head",
        action="store_true",
        help="Re-migrate legacy trackers from git HEAD, overwriting current working-tree versions (skips files that already had v1 findings in HEAD).",
    )
    ap.add_argument("--today", default=today_utc())
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    base = repo_root / "docs" / "component-issues"
    if not base.is_dir():
        raise SystemExit(f"missing dir: {base}")

    changed: list[Path] = []
    for p in sorted(base.glob("*.md")):
        if p.name == "SCHEMA.md":
            continue

        if args.force_from_head:
            rel = p.relative_to(repo_root)
            try:
                head_text = subprocess.check_output(["git", "show", f"HEAD:{rel}"], cwd=repo_root).decode(
                    "utf-8", errors="replace"
                )
            except Exception:
                # If file isn't in HEAD for some reason, fall back to on-disk.
                head_text = p.read_text(encoding="utf-8", errors="replace")

            # Skip files that already had v1 findings in HEAD (e.g., observability, certificates-smoke-tests).
            if FINDINGS_BEGIN in head_text:
                continue

            new_text = migrate_text(p.stem, head_text, args.today)
            did_change = new_text != p.read_text(encoding="utf-8", errors="replace")
        else:
            did_change, new_text = migrate_file(p, args.today)

        if not did_change:
            continue
        changed.append(p)
        if args.apply:
            p.write_text(new_text, encoding="utf-8")

    for p in changed:
        print(str(p.relative_to(repo_root)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
