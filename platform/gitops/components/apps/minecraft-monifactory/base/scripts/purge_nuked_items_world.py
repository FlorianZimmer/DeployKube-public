import gzip
import json
import os
import re
import struct
import sys
import time
import zlib
from pathlib import Path


# --- Minimal NBT reader/writer (enough for playerdata + chunk NBT) ---

TAG_END = 0
TAG_BYTE = 1
TAG_SHORT = 2
TAG_INT = 3
TAG_LONG = 4
TAG_FLOAT = 5
TAG_DOUBLE = 6
TAG_BYTE_ARRAY = 7
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10
TAG_INT_ARRAY = 11
TAG_LONG_ARRAY = 12


class NBTReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n):
        out = self.data[self.pos : self.pos + n]
        if len(out) != n:
            raise EOFError("unexpected eof")
        self.pos += n
        return out

    def read_u8(self):
        return self.read(1)[0]

    def read_i8(self):
        return struct.unpack(">b", self.read(1))[0]

    def read_i16(self):
        return struct.unpack(">h", self.read(2))[0]

    def read_u16(self):
        return struct.unpack(">H", self.read(2))[0]

    def read_i32(self):
        return struct.unpack(">i", self.read(4))[0]

    def read_i64(self):
        return struct.unpack(">q", self.read(8))[0]

    def read_f32(self):
        return struct.unpack(">f", self.read(4))[0]

    def read_f64(self):
        return struct.unpack(">d", self.read(8))[0]

    def read_string(self):
        n = self.read_u16()
        return self.read(n).decode("utf-8", errors="replace")


class NBTWriter:
    def __init__(self):
        self.parts = []

    def write(self, b):
        self.parts.append(b)

    def write_u8(self, v):
        self.write(bytes((v & 0xFF,)))

    def write_i8(self, v):
        self.write(struct.pack(">b", int(v)))

    def write_i16(self, v):
        self.write(struct.pack(">h", int(v)))

    def write_u16(self, v):
        self.write(struct.pack(">H", int(v)))

    def write_i32(self, v):
        self.write(struct.pack(">i", int(v)))

    def write_i64(self, v):
        self.write(struct.pack(">q", int(v)))

    def write_f32(self, v):
        self.write(struct.pack(">f", float(v)))

    def write_f64(self, v):
        self.write(struct.pack(">d", float(v)))

    def write_string(self, s):
        raw = s.encode("utf-8")
        self.write_u16(len(raw))
        self.write(raw)

    def to_bytes(self):
        return b"".join(self.parts)


def read_tag_payload(reader, tag_type):
    if tag_type == TAG_END:
        return None
    if tag_type == TAG_BYTE:
        return reader.read_i8()
    if tag_type == TAG_SHORT:
        return reader.read_i16()
    if tag_type == TAG_INT:
        return reader.read_i32()
    if tag_type == TAG_LONG:
        return reader.read_i64()
    if tag_type == TAG_FLOAT:
        return reader.read_f32()
    if tag_type == TAG_DOUBLE:
        return reader.read_f64()
    if tag_type == TAG_BYTE_ARRAY:
        n = reader.read_i32()
        return reader.read(n)
    if tag_type == TAG_STRING:
        return reader.read_string()
    if tag_type == TAG_LIST:
        elem_type = reader.read_u8()
        length = reader.read_i32()
        items = []
        for _ in range(length):
            items.append(read_tag_payload(reader, elem_type))
        return (elem_type, items)
    if tag_type == TAG_COMPOUND:
        obj = {}
        while True:
            t = reader.read_u8()
            if t == TAG_END:
                break
            name = reader.read_string()
            obj[name] = (t, read_tag_payload(reader, t))
        return obj
    if tag_type == TAG_INT_ARRAY:
        n = reader.read_i32()
        return list(struct.unpack(">" + "i" * n, reader.read(4 * n)))
    if tag_type == TAG_LONG_ARRAY:
        n = reader.read_i32()
        return list(struct.unpack(">" + "q" * n, reader.read(8 * n)))
    raise ValueError("unknown tag type: %r" % (tag_type,))


def write_tag_payload(writer, tag_type, value):
    if tag_type == TAG_END:
        return
    if tag_type == TAG_BYTE:
        writer.write_i8(value)
        return
    if tag_type == TAG_SHORT:
        writer.write_i16(value)
        return
    if tag_type == TAG_INT:
        writer.write_i32(value)
        return
    if tag_type == TAG_LONG:
        writer.write_i64(value)
        return
    if tag_type == TAG_FLOAT:
        writer.write_f32(value)
        return
    if tag_type == TAG_DOUBLE:
        writer.write_f64(value)
        return
    if tag_type == TAG_BYTE_ARRAY:
        b = value if isinstance(value, (bytes, bytearray)) else bytes(value)
        writer.write_i32(len(b))
        writer.write(b)
        return
    if tag_type == TAG_STRING:
        writer.write_string(value)
        return
    if tag_type == TAG_LIST:
        elem_type, items = value
        writer.write_u8(elem_type)
        writer.write_i32(len(items))
        for item in items:
            write_tag_payload(writer, elem_type, item)
        return
    if tag_type == TAG_COMPOUND:
        for name, (t, v) in value.items():
            writer.write_u8(t)
            writer.write_string(name)
            write_tag_payload(writer, t, v)
        writer.write_u8(TAG_END)
        return
    if tag_type == TAG_INT_ARRAY:
        writer.write_i32(len(value))
        writer.write(struct.pack(">" + "i" * len(value), *value))
        return
    if tag_type == TAG_LONG_ARRAY:
        writer.write_i32(len(value))
        writer.write(struct.pack(">" + "q" * len(value), *value))
        return
    raise ValueError("unknown tag type: %r" % (tag_type,))


def nbt_load(raw):
    reader = NBTReader(raw)
    tag_type = reader.read_u8()
    if tag_type != TAG_COMPOUND:
        raise ValueError("root tag is not compound: %r" % tag_type)
    _name = reader.read_string()
    root = read_tag_payload(reader, TAG_COMPOUND)
    return root


def nbt_dump(root, name=""):
    writer = NBTWriter()
    writer.write_u8(TAG_COMPOUND)
    writer.write_string(name)
    write_tag_payload(writer, TAG_COMPOUND, root)
    return writer.to_bytes()


# --- Parse Monifactory nukelist semantics from KubeJS ---


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def parse_quoted_strings(js_text):
    # Keep this intentionally permissive; we only need to extract literal item IDs.
    # Hyphen must be last in a character class to avoid "bad character range" errors.
    return re.findall(r"['\\\"]([a-z0-9_.-]+:[a-z0-9_.-]+)['\\\"]", js_text, flags=re.I)


def parse_item_nuke_list(item_js_text):
    strings = set()
    regexes = []

    m = re.search(r"global\\.itemNukeList\\s*=\\s*\\[(.*?)]\\s*;", item_js_text, flags=re.S)
    body = m.group(1) if m else item_js_text

    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue
        line = re.sub(r"//.*$", "", line).strip()
        if line.endswith(","):
            line = line[:-1].strip()
        if not line:
            continue

        if (line.startswith('"') and line.endswith('"')) or (line.startswith("'") and line.endswith("'")):
            strings.add(line[1:-1])
            continue

        if line.startswith("/"):
            last = line.rfind("/")
            if last > 0:
                pattern = line[1:last]
                flags = line[last + 1 :]
                py_flags = 0
                if "i" in flags:
                    py_flags |= re.I
                if "m" in flags:
                    py_flags |= re.M
                try:
                    regexes.append(re.compile(pattern, py_flags))
                except re.error:
                    pass

    return strings, regexes


def build_nuked_matcher(kubejs_dir):
    kubejs = Path(kubejs_dir)
    unif_js = read_text(kubejs / "startup_scripts/nukeLists/unificationPatterns.js")
    item_js = read_text(kubejs / "startup_scripts/nukeLists/item.js")

    excluded_items = set(parse_quoted_strings(unif_js))
    item_nuke_strings, item_nuke_regexes = parse_item_nuke_list(item_js)

    excluded_re = "|".join(re.escape(x) for x in sorted(excluded_items)) or "a^"
    unif_pattern = re.compile(
        r"^(?!({})).*(nuclearcraft|thermal|enderio|ad_astra|extendedcrafting):((powdered_|raw_).*|.*(_block|_plate|_ingot|_nugget|_gear|_dust|_rod|_gem|_ore))".format(
            excluded_re
        ),
        flags=re.I,
    )

    fuel_keep = []
    m = re.search(r"global\\.nuclearCraftFuelsToKeep\\s*=\\s*\\[(.*?)]\\s*\\n\\]", unif_js, flags=re.S)
    if m:
        fuel_keep = parse_quoted_strings(m.group(1))

    fuel_keep_re = "|".join(re.escape(x) for x in fuel_keep)
    if fuel_keep_re:
        nc_fuel_pattern = re.compile(r"^(?!(?:{})$).*nuclearcraft:(fuel|depleted_fuel).*".format(fuel_keep_re), flags=re.I)
    else:
        nc_fuel_pattern = re.compile(r"^nuclearcraft:(fuel|depleted_fuel).*", flags=re.I)

    nc_isotope_pattern = re.compile(r"^nuclearcraft:.*(_ni|_za|_ox)$", flags=re.I)

    def is_nuked(item_id):
        if item_id in item_nuke_strings:
            return True
        for rx in item_nuke_regexes:
            if rx.search(item_id):
                return True
        if unif_pattern.search(item_id):
            return True
        if nc_fuel_pattern.search(item_id):
            return True
        if nc_isotope_pattern.search(item_id):
            return True
        return False

    return is_nuked


def looks_like_itemstack(compound):
    if not isinstance(compound, dict):
        return False
    id_tag = compound.get("id")
    if not id_tag or id_tag[0] != TAG_STRING:
        return False
    item_id = id_tag[1]
    if not isinstance(item_id, str) or ":" not in item_id:
        return False
    count_tag = compound.get("Count")
    if not count_tag or count_tag[0] not in (TAG_BYTE, TAG_SHORT, TAG_INT):
        return False
    return True


def set_empty_itemstack():
    # Minimal empty stack. Keep as compound to satisfy slot parsers.
    return {
        "id": (TAG_STRING, "minecraft:air"),
        "Count": (TAG_BYTE, 0),
    }


def purge_nuked_items_in_tag(tag_type, value, is_nuked, removed_counts):
    changed = False

    if tag_type == TAG_COMPOUND:
        comp = value

        # If this compound itself looks like an ItemStack and is nuked, rewrite it to empty.
        if looks_like_itemstack(comp):
            item_id = comp.get("id")[1]
            if is_nuked(item_id):
                removed_counts[item_id] = removed_counts.get(item_id, 0) + int(comp.get("Count", (TAG_BYTE, 1))[1] or 1)
                empty = set_empty_itemstack()
                comp.clear()
                comp.update(empty)
                return True

        for k, (t, v) in list(comp.items()):
            if t == TAG_LIST and isinstance(v, tuple) and len(v) == 2:
                elem_type, items = v
                if elem_type == TAG_COMPOUND and isinstance(items, list):
                    new_items = []
                    for child in items:
                        if isinstance(child, dict) and looks_like_itemstack(child):
                            item_id = child.get("id")[1]
                            if is_nuked(item_id):
                                removed_counts[item_id] = removed_counts.get(item_id, 0) + int(child.get("Count", (TAG_BYTE, 1))[1] or 1)
                                changed = True
                                continue
                        if isinstance(child, dict):
                            if purge_nuked_items_in_tag(TAG_COMPOUND, child, is_nuked, removed_counts):
                                changed = True
                        new_items.append(child)
                    if len(new_items) != len(items):
                        comp[k] = (TAG_LIST, (elem_type, new_items))
                        changed = True
                    continue

            if purge_nuked_items_in_tag(t, v, is_nuked, removed_counts):
                changed = True

        return changed

    if tag_type == TAG_LIST:
        elem_type, items = value
        if elem_type == TAG_COMPOUND:
            for child in items:
                if isinstance(child, dict):
                    if purge_nuked_items_in_tag(TAG_COMPOUND, child, is_nuked, removed_counts):
                        changed = True
        return changed

    return False


def read_maybe_compressed(path):
    raw = Path(path).read_bytes()
    if raw[:2] == b"\x1f\x8b":
        return gzip.decompress(raw), "gzip"
    # Fallback: assume uncompressed NBT
    return raw, "none"


def write_maybe_compressed(path, raw_nbt, kind):
    if kind == "gzip":
        out = gzip.compress(raw_nbt)
    else:
        out = raw_nbt
    Path(path).write_bytes(out)


def ensure_archived(src_path, world_dir, archive_dir):
    src_path = Path(src_path)
    rel = src_path.relative_to(world_dir)
    dst = Path(archive_dir) / rel
    if dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(src_path.read_bytes())


def purge_playerdata(world_dir, archive_dir, is_nuked, removed_counts):
    world = Path(world_dir)
    modified = 0
    scanned = 0

    for root in [world / "playerdata"]:
        if not root.exists():
            continue
        for path in sorted(root.glob("*.dat")):
            scanned += 1
            try:
                raw, kind = read_maybe_compressed(path)
                nbt = nbt_load(raw)
                changed = purge_nuked_items_in_tag(TAG_COMPOUND, nbt, is_nuked, removed_counts)
                if changed:
                    ensure_archived(path, world, archive_dir)
                    Path(path).write_bytes(gzip.compress(nbt_dump(nbt)))
                    modified += 1
            except Exception:
                continue

    return {"scanned": scanned, "modified": modified}


def mca_iter_dirs(world_dir):
    world = Path(world_dir)
    for p in world.rglob("*"):
        if not p.is_dir():
            continue
        if p.name in ("region", "entities"):
            yield p


def read_u24(b):
    return (b[0] << 16) | (b[1] << 8) | b[2]


def write_u24(v):
    return bytes(((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF))


def purge_region_file(path, world_dir, archive_dir, is_nuked, removed_counts):
    src = Path(path)
    data = src.read_bytes()
    if len(data) < 8192:
        return False, 0

    locations = data[:4096]
    timestamps = data[4096:8192]

    changed_any = False
    chunks_touched = 0

    out_parts = [bytearray(8192)]  # placeholder for header
    out = out_parts[0]
    out[:4096] = locations
    out[4096:8192] = timestamps

    # New location table we will fill.
    new_locations = bytearray(4096)
    new_timestamps = bytearray(timestamps)

    # Start writing chunk sectors after header (sector 2).
    sector_size = 4096
    cur_sector = 2
    out_file = bytearray(sector_size * cur_sector)
    out_file[:8192] = out

    def append_chunk_bytes(chunk_bytes):
        nonlocal out_file, cur_sector
        # pad out_file to sector boundary
        if len(out_file) % sector_size != 0:
            pad = sector_size - (len(out_file) % sector_size)
            out_file.extend(b"\x00" * pad)
        start_sector = len(out_file) // sector_size
        out_file.extend(chunk_bytes)
        # pad chunk to sector boundary
        if len(out_file) % sector_size != 0:
            pad = sector_size - (len(out_file) % sector_size)
            out_file.extend(b"\x00" * pad)
        end_sector = len(out_file) // sector_size
        cur_sector = end_sector
        return start_sector, end_sector - start_sector

    for i in range(1024):
        entry = locations[i * 4 : (i + 1) * 4]
        offset = read_u24(entry[:3])
        sectors = entry[3]
        if offset == 0 or sectors == 0:
            continue

        chunk_start = offset * sector_size
        if chunk_start + 5 > len(data):
            continue
        length = struct.unpack(">I", data[chunk_start : chunk_start + 4])[0]
        if length < 1:
            continue
        ctype = data[chunk_start + 4]
        compressed = data[chunk_start + 5 : chunk_start + 4 + length]

        try:
            if ctype == 1:
                raw_nbt = gzip.decompress(compressed)
            elif ctype == 2:
                raw_nbt = zlib.decompress(compressed)
            elif ctype == 3:
                raw_nbt = compressed
            else:
                continue

            nbt = nbt_load(raw_nbt)
            changed = purge_nuked_items_in_tag(TAG_COMPOUND, nbt, is_nuked, removed_counts)
            if changed:
                changed_any = True
                chunks_touched += 1
                raw_new = nbt_dump(nbt)
                if ctype == 1:
                    comp_new = gzip.compress(raw_new)
                elif ctype == 2:
                    comp_new = zlib.compress(raw_new)
                else:
                    comp_new = raw_new
            else:
                # Keep original bytes.
                comp_new = compressed

            record = struct.pack(">I", len(comp_new) + 1) + bytes((ctype,)) + comp_new
            start_sector, sector_count = append_chunk_bytes(record)
            new_locations[i * 4 : i * 4 + 3] = write_u24(start_sector)
            new_locations[i * 4 + 3] = sector_count & 0xFF
        except Exception:
            continue

    if not changed_any:
        return False, 0

    # Write fixed header
    out_file[:4096] = new_locations
    out_file[4096:8192] = new_timestamps

    # Archive original then replace atomically.
    ensure_archived(src, Path(world_dir), Path(archive_dir))
    tmp = src.with_suffix(src.suffix + ".tmp")
    tmp.write_bytes(bytes(out_file))
    tmp.replace(src)
    return True, chunks_touched


def main(argv):
    if len(argv) != 5:
        print("usage: purge_nuked_items_world.py <world_dir> <kubejs_dir> <archive_dir> <report_path>", file=sys.stderr)
        return 2

    world_dir = Path(argv[1])
    kubejs_dir = Path(argv[2])
    archive_dir = Path(argv[3])
    report_path = Path(argv[4])

    is_nuked = build_nuked_matcher(kubejs_dir)
    removed_counts = {}

    started = time.time()
    archive_dir.mkdir(parents=True, exist_ok=True)

    report = {
        "started_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "world_dir": str(world_dir),
        "archive_dir": str(archive_dir),
        "removed_item_counts": {},
        "playerdata": {},
        "mca": {"scanned": 0, "modified": 0, "chunks_touched": 0},
    }

    report["playerdata"] = purge_playerdata(world_dir, archive_dir, is_nuked, removed_counts)

    mca_scanned = 0
    mca_modified = 0
    chunks_touched = 0

    for d in mca_iter_dirs(world_dir):
        for mca in sorted(d.glob("*.mca")):
            mca_scanned += 1
            changed, touched = purge_region_file(mca, world_dir, archive_dir, is_nuked, removed_counts)
            if changed:
                mca_modified += 1
                chunks_touched += touched
            if mca_scanned % 50 == 0:
                print("[purge-nuked-items] scanned %d mca files (modified=%d)..." % (mca_scanned, mca_modified))

    report["mca"]["scanned"] = mca_scanned
    report["mca"]["modified"] = mca_modified
    report["mca"]["chunks_touched"] = chunks_touched

    # sort removed counts desc
    report["removed_item_counts"] = dict(sorted(removed_counts.items(), key=lambda kv: -kv[1])[:2000])
    report["finished_at_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    report["duration_seconds"] = int(time.time() - started)

    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("[purge-nuked-items] done: playerdata modified=%d, mca modified=%d, duration=%ss" % (report["playerdata"]["modified"], mca_modified, report["duration_seconds"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
