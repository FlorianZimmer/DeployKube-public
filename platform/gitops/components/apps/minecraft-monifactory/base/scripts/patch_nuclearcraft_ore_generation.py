import re
import sys
from pathlib import Path


REGISTER_RE = re.compile(r"^(\s*)register(\s*=\s*)(true|false)(\s*)$", re.IGNORECASE)


def main(argv):
    if len(argv) != 2:
        print("usage: patch_nuclearcraft_ore_generation.py <path>", file=sys.stderr)
        return 2

    path = Path(argv[1])
    if not path.exists():
        print(f"[nuclearcraft-disable-ore-worldgen] missing {path}; skipping", file=sys.stderr)
        return 0

    lines_in = path.read_text(encoding="utf-8", errors="replace").splitlines(True)
    lines_out = []

    changed = False
    for line in lines_in:
        stripped = line.strip()

        # Repair a previously-corrupted line: literal "\1false"
        if stripped == r"\1false":
            # Preserve the original file's indentation style (tabs are common here).
            lines_out.append("\tregister = false\n")
            changed = True
            continue

        m = REGISTER_RE.match(line.rstrip("\n"))
        if m:
            indent, eq, _value, trailing = m.groups()
            lines_out.append(f"{indent}register{eq}false{trailing}\n")
            if _value.lower() != "false":
                changed = True
            continue

        lines_out.append(line)

    if changed:
        path.write_text("".join(lines_out), encoding="utf-8")
        print(f"[nuclearcraft-disable-ore-worldgen] patched {path}")
    else:
        print(f"[nuclearcraft-disable-ore-worldgen] no changes needed for {path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
