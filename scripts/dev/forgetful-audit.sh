#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/dev/forgetful-audit.sh [options]

Audits local Forgetful memory hygiene from the SQLite DB.
Default output is compact/token-efficient.

Options:
  --db <path>                     Forgetful DB path (default: ~/Library/Application Support/forgetful/forgetful.db)
  --project-id <id>               Project scope for checks (default: 1)
  --mode <compact|human|verbose>  Output mode (default: compact)
  --human                         Alias for --mode human
  --verbose                       Alias for --mode verbose
  --max-items <n>                 Max IDs/items in compact output (default: 20)
  --near-threshold <f>            Near-duplicate title threshold 0.0..1.0 (default: 0.92)
  --write-report <path>           Write markdown report to path
  --check                         Exit non-zero on structural issues (orphans/missing-project/duplicates)
  --fail-on-missing-tag           Include missing deploykube tag in --check failures
  --fail-on-missing-provenance    Include missing provenance in --check failures
  -h, --help                      Show this help

Examples:
  ./scripts/dev/forgetful-audit.sh
  ./scripts/dev/forgetful-audit.sh --human
  ./scripts/dev/forgetful-audit.sh --verbose
  ./scripts/dev/forgetful-audit.sh --check
  ./scripts/dev/forgetful-audit.sh --write-report tmp/forgetful-audit-report.md
EOF
}

check_dependency() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: missing dependency: ${bin}" >&2
    exit 1
  fi
}

check_dependency sqlite3
check_dependency python3

db_path="${HOME}/Library/Application Support/forgetful/forgetful.db"
project_id="1"
mode="compact"
max_items="20"
near_threshold="0.92"
write_report=""
check="false"
fail_on_missing_tag="false"
fail_on_missing_provenance="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      db_path="${2:-}"
      shift 2
      ;;
    --project-id)
      project_id="${2:-}"
      shift 2
      ;;
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --human)
      mode="human"
      shift
      ;;
    --verbose)
      mode="verbose"
      shift
      ;;
    --max-items)
      max_items="${2:-}"
      shift 2
      ;;
    --near-threshold)
      near_threshold="${2:-}"
      shift 2
      ;;
    --write-report)
      write_report="${2:-}"
      shift 2
      ;;
    --check)
      check="true"
      shift
      ;;
    --fail-on-missing-tag)
      fail_on_missing_tag="true"
      shift
      ;;
    --fail-on-missing-provenance)
      fail_on_missing_provenance="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "${mode}" in
  compact|human|verbose)
    ;;
  *)
    echo "error: --mode must be one of compact|human|verbose" >&2
    exit 2
    ;;
esac

if ! [[ "${project_id}" =~ ^[0-9]+$ ]]; then
  echo "error: --project-id must be an integer" >&2
  exit 2
fi
if ! [[ "${max_items}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --max-items must be a positive integer" >&2
  exit 2
fi
if [[ ! -f "${db_path}" ]]; then
  echo "error: forgetful db not found: ${db_path}" >&2
  exit 1
fi

python3 - "${db_path}" "${project_id}" "${mode}" "${max_items}" "${near_threshold}" "${write_report}" "${check}" "${fail_on_missing_tag}" "${fail_on_missing_provenance}" <<'PY'
import datetime
import difflib
import json
import os
import re
import sqlite3
import sys
from itertools import combinations

db_path = sys.argv[1]
project_id = int(sys.argv[2])
mode = sys.argv[3]
max_items = int(sys.argv[4])
near_threshold = float(sys.argv[5])
write_report = sys.argv[6]
check = sys.argv[7] == "true"
fail_on_missing_tag = sys.argv[8] == "true"
fail_on_missing_provenance = sys.argv[9] == "true"

if near_threshold < 0.0 or near_threshold > 1.0:
    print("error: --near-threshold must be in range [0.0, 1.0]", file=sys.stderr)
    sys.exit(2)

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

project_name = f"project-{project_id}"
row = cur.execute("SELECT name FROM projects WHERE id = ?", (project_id,)).fetchone()
if row is not None:
    project_name = row["name"]

rows = cur.execute(
    """
    SELECT
      m.id,
      m.title,
      m.content,
      m.tags,
      m.importance,
      m.is_obsolete,
      m.superseded_by,
      m.source_repo,
      m.source_files,
      m.source_url,
      m.created_at,
      m.updated_at,
      GROUP_CONCAT(mpa.project_id) AS project_ids
    FROM memories m
    LEFT JOIN memory_project_association mpa ON m.id = mpa.memory_id
    GROUP BY m.id
    ORDER BY m.id DESC
    """
).fetchall()


def parse_json_list(raw):
    if raw is None:
        return []
    try:
        val = json.loads(raw)
    except Exception:
        return []
    if isinstance(val, list):
        return val
    return []


def parse_project_ids(raw):
    if not raw:
        return []
    out = []
    for part in str(raw).split(","):
        part = part.strip()
        if not part:
            continue
        try:
            out.append(int(part))
        except ValueError:
            pass
    return sorted(set(out))


def normalize_title(title):
    return re.sub(r"[^a-z0-9]+", " ", (title or "").lower()).strip()


def token_set(title):
    return {t for t in normalize_title(title).split() if t}


def jaccard(a, b):
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


memories = []
for r in rows:
    tags = parse_json_list(r["tags"])
    source_files = parse_json_list(r["source_files"])
    project_ids = parse_project_ids(r["project_ids"])
    title = r["title"] or ""
    content = r["content"] or ""
    memories.append(
        {
            "id": int(r["id"]),
            "title": title,
            "content_len": len(content),
            "importance": int(r["importance"]),
            "is_obsolete": bool(r["is_obsolete"]),
            "superseded_by": r["superseded_by"],
            "tags": tags,
            "source_repo": r["source_repo"] or "",
            "source_files": source_files,
            "source_url": r["source_url"] or "",
            "project_ids": project_ids,
            "created_at": r["created_at"],
            "updated_at": r["updated_at"],
        }
    )

total = len(memories)
active = [m for m in memories if not m["is_obsolete"]]
obsolete = [m for m in memories if m["is_obsolete"]]
in_project = [m for m in memories if project_id in m["project_ids"]]
project_active = [m for m in active if project_id in m["project_ids"]]

orphans = [m for m in active if len(m["project_ids"]) == 0]
missing_project_link = [m for m in active if project_id not in m["project_ids"]]
missing_tag = [m for m in project_active if "deploykube" not in [str(t).lower() for t in m["tags"]]]
missing_provenance = [
    m
    for m in project_active
    if not m["source_repo"] and not m["source_url"] and len(m["source_files"]) == 0
]
obsolete_without_superseded = [m for m in obsolete if m["superseded_by"] in (None, "", 0)]
doc_overlap_candidates = [m for m in project_active if m["content_len"] >= 850]

# Exact duplicate groups by normalized title among active memories.
by_norm = {}
for m in project_active:
    norm = normalize_title(m["title"])
    if norm:
        by_norm.setdefault(norm, []).append(m)
exact_duplicate_groups = []
for norm, group in by_norm.items():
    if len(group) > 1:
        exact_duplicate_groups.append(
            {
                "normalized_title": norm,
                "ids": sorted([g["id"] for g in group]),
                "titles": [g["title"] for g in sorted(group, key=lambda x: x["id"])],
            }
        )
exact_duplicate_groups = sorted(exact_duplicate_groups, key=lambda g: (len(g["ids"]) * -1, g["ids"][0]))

# Near duplicate pairs by title similarity among active memories.
near_duplicate_pairs = []
for a, b in combinations(project_active, 2):
    norm_a = normalize_title(a["title"])
    norm_b = normalize_title(b["title"])
    if not norm_a or not norm_b or norm_a == norm_b:
        continue
    ratio = difflib.SequenceMatcher(None, norm_a, norm_b).ratio()
    if ratio < near_threshold:
        continue
    jac = jaccard(token_set(a["title"]), token_set(b["title"]))
    if jac < 0.6:
        continue
    near_duplicate_pairs.append(
        {
            "id_a": a["id"],
            "id_b": b["id"],
            "ratio": round(ratio, 3),
            "jaccard": round(jac, 3),
            "title_a": a["title"],
            "title_b": b["title"],
        }
    )
near_duplicate_pairs = sorted(near_duplicate_pairs, key=lambda p: (-p["ratio"], p["id_a"], p["id_b"]))

summary = {
    "db_path": db_path,
    "project_id": project_id,
    "project_name": project_name,
    "memories_total": total,
    "active": len(active),
    "obsolete": len(obsolete),
    "in_project": len(in_project),
    "project_active": len(project_active),
    "orphans": len(orphans),
    "missing_project_link": len(missing_project_link),
    "missing_deploykube_tag": len(missing_tag),
    "missing_provenance": len(missing_provenance),
    "obsolete_without_superseded": len(obsolete_without_superseded),
    "exact_duplicate_groups": len(exact_duplicate_groups),
    "near_duplicate_pairs": len(near_duplicate_pairs),
    "doc_overlap_candidates": len(doc_overlap_candidates),
}

report = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "summary": summary,
    "findings": {
        "orphans": [{"id": m["id"], "title": m["title"]} for m in orphans],
        "missing_project_link": [{"id": m["id"], "title": m["title"]} for m in missing_project_link],
        "missing_deploykube_tag": [{"id": m["id"], "title": m["title"]} for m in missing_tag],
        "missing_provenance": [{"id": m["id"], "title": m["title"]} for m in missing_provenance],
        "obsolete_without_superseded": [{"id": m["id"], "title": m["title"]} for m in obsolete_without_superseded],
        "doc_overlap_candidates": [
            {"id": m["id"], "title": m["title"], "content_len": m["content_len"]} for m in doc_overlap_candidates
        ],
        "exact_duplicate_groups": exact_duplicate_groups,
        "near_duplicate_pairs": near_duplicate_pairs,
    },
}


def limit_ids(items, max_n):
    ids = [str(i["id"]) for i in items]
    if len(ids) <= max_n:
        return ",".join(ids) if ids else "-"
    head = ",".join(ids[:max_n])
    return f"{head},+{len(ids) - max_n}more"


def limit_pairs(items, max_n):
    if not items:
        return "-"
    out = []
    for p in items[:max_n]:
        out.append(f"{p['id_a']}-{p['id_b']}@{p['ratio']}")
    if len(items) > max_n:
        out.append(f"+{len(items) - max_n}more")
    return ",".join(out)


def print_compact():
    s = summary
    print(
        "SUMMARY "
        + " ".join(
            [
                f"memories_total={s['memories_total']}",
                f"active={s['active']}",
                f"obsolete={s['obsolete']}",
                f"in_project={s['in_project']}",
                f"orphans={s['orphans']}",
                f"missing_project_link={s['missing_project_link']}",
                f"missing_tag={s['missing_deploykube_tag']}",
                f"missing_provenance={s['missing_provenance']}",
                f"exact_dupe_groups={s['exact_duplicate_groups']}",
                f"near_dupe_pairs={s['near_duplicate_pairs']}",
                f"doc_overlap_candidates={s['doc_overlap_candidates']}",
                f"project={s['project_id']}",
            ]
        )
    )
    if orphans:
        print(f"ORPHAN_IDS {limit_ids(orphans, max_items)}")
    if missing_project_link:
        print(f"MISSING_PROJECT_LINK_IDS {limit_ids(missing_project_link, max_items)}")
    if missing_tag:
        print(f"MISSING_TAG_IDS {limit_ids(missing_tag, max_items)}")
    if missing_provenance:
        print(f"MISSING_PROVENANCE_IDS {limit_ids(missing_provenance, max_items)}")
    if exact_duplicate_groups:
        chunks = []
        for g in exact_duplicate_groups[:max_items]:
            chunks.append("+".join([str(i) for i in g["ids"]]))
        if len(exact_duplicate_groups) > max_items:
            chunks.append(f"+{len(exact_duplicate_groups) - max_items}more")
        print(f"EXACT_DUPE_GROUPS {','.join(chunks)}")
    if near_duplicate_pairs:
        print(f"NEAR_DUPE_PAIRS {limit_pairs(near_duplicate_pairs, max_items)}")


def print_human():
    s = summary
    print("Forgetful Audit")
    print(f"Generated: {report['generated_at']}")
    print(f"DB: {db_path}")
    print(f"Project: {project_name} (id={project_id})")
    print("")
    print(
        "Counts: "
        f"total={s['memories_total']} active={s['active']} obsolete={s['obsolete']} "
        f"in_project={s['in_project']} orphans={s['orphans']} missing_project_link={s['missing_project_link']} "
        f"missing_tag={s['missing_deploykube_tag']} missing_provenance={s['missing_provenance']} "
        f"exact_dupe_groups={s['exact_duplicate_groups']} near_dupe_pairs={s['near_duplicate_pairs']}"
    )

    def section(name, items, show_extra=False):
        print("")
        print(f"{name}: {len(items)}")
        for item in items:
            if show_extra:
                print(f"  - {item['id']}: {item['title']} (len={item['content_len']})")
            else:
                print(f"  - {item['id']}: {item['title']}")

    section("Orphan memories (active with no project link)", orphans)
    section(f"Active memories missing project {project_id}", missing_project_link)
    section("Project memories missing deploykube tag", missing_tag)
    section("Project memories missing provenance", missing_provenance)
    section("Obsolete memories missing superseded_by", obsolete_without_superseded)
    section("Doc-overlap candidates (possible redundancy)", doc_overlap_candidates, show_extra=True)

    print("")
    print(f"Exact duplicate title groups: {len(exact_duplicate_groups)}")
    for g in exact_duplicate_groups:
        print(f"  - IDs {g['ids']}: {g['titles'][0]}")
    print(f"Near duplicate title pairs: {len(near_duplicate_pairs)}")
    for p in near_duplicate_pairs:
        print(f"  - {p['id_a']} <-> {p['id_b']} ratio={p['ratio']} jaccard={p['jaccard']}")


def print_verbose():
    print(json.dumps(report, indent=2, ensure_ascii=True))


def write_markdown(path):
    dir_path = os.path.dirname(path)
    if dir_path:
        os.makedirs(dir_path, exist_ok=True)
    s = summary
    with open(path, "w", encoding="utf-8") as f:
        f.write("# Forgetful Audit Report\n\n")
        f.write(f"- Generated: {report['generated_at']}\n")
        f.write(f"- DB: `{db_path}`\n")
        f.write(f"- Project: `{project_name}` (id={project_id})\n\n")
        f.write("## Summary\n\n")
        f.write("| metric | value |\n|---|---:|\n")
        for key in [
            "memories_total",
            "active",
            "obsolete",
            "in_project",
            "project_active",
            "orphans",
            "missing_project_link",
            "missing_deploykube_tag",
            "missing_provenance",
            "obsolete_without_superseded",
            "exact_duplicate_groups",
            "near_duplicate_pairs",
            "doc_overlap_candidates",
        ]:
            f.write(f"| {key} | {s[key]} |\n")

        def write_list_section(title, items):
            f.write(f"\n## {title}\n\n")
            if not items:
                f.write("_None._\n")
                return
            for item in items:
                f.write(f"- `{item['id']}` {item['title']}\n")

        write_list_section("Orphan Memories", [{"id": m["id"], "title": m["title"]} for m in orphans])
        write_list_section(
            f"Memories Missing Project {project_id}",
            [{"id": m["id"], "title": m["title"]} for m in missing_project_link],
        )
        write_list_section(
            "Memories Missing deploykube Tag",
            [{"id": m["id"], "title": m["title"]} for m in missing_tag],
        )
        write_list_section(
            "Memories Missing Provenance",
            [{"id": m["id"], "title": m["title"]} for m in missing_provenance],
        )

        f.write("\n## Duplicate Candidates\n\n")
        if not exact_duplicate_groups and not near_duplicate_pairs:
            f.write("_None._\n")
        else:
            if exact_duplicate_groups:
                f.write("### Exact title groups\n")
                for g in exact_duplicate_groups:
                    f.write(f"- IDs `{g['ids']}` title `{g['titles'][0]}`\n")
            if near_duplicate_pairs:
                f.write("\n### Near title pairs\n")
                for p in near_duplicate_pairs:
                    f.write(
                        f"- `{p['id_a']}` <-> `{p['id_b']}` ratio={p['ratio']} jaccard={p['jaccard']}\n"
                    )


if mode == "compact":
    print_compact()
elif mode == "human":
    print_human()
else:
    print_verbose()

if write_report:
    write_markdown(write_report)

fail_reasons = []
if check:
    if len(orphans) > 0:
        fail_reasons.append(f"orphans={len(orphans)}")
    if len(missing_project_link) > 0:
        fail_reasons.append(f"missing_project_link={len(missing_project_link)}")
    if len(exact_duplicate_groups) > 0:
        fail_reasons.append(f"exact_duplicate_groups={len(exact_duplicate_groups)}")
    if len(near_duplicate_pairs) > 0:
        fail_reasons.append(f"near_duplicate_pairs={len(near_duplicate_pairs)}")
    if fail_on_missing_tag and len(missing_tag) > 0:
        fail_reasons.append(f"missing_tag={len(missing_tag)}")
    if fail_on_missing_provenance and len(missing_provenance) > 0:
        fail_reasons.append(f"missing_provenance={len(missing_provenance)}")

if fail_reasons:
    print("CHECK_FAILED " + " ".join(fail_reasons), file=sys.stderr)
    sys.exit(1)
PY
