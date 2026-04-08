import json
import os
import shutil
import struct
import sys
import time
from pathlib import Path


SECTOR_SIZE = 4096


def parse_keep_chunks(spec: str):
    out = set()
    for part in spec.split(";"):
        part = part.strip()
        if not part:
            continue
        bits = [b.strip() for b in part.split(",")]
        if len(bits) != 2:
            raise ValueError(f"bad chunk pair: {part!r} (expected 'chunkX,chunkZ')")
        cx = int(bits[0])
        cz = int(bits[1])
        out.add((cx, cz))
    if not out:
        raise ValueError("empty keep chunk list")
    return out


def region_coords_for_chunk(cx: int, cz: int):
    # floor division works for negative coords too.
    return (cx // 32, cz // 32)


def local_index_in_region(cx: int, cz: int, rx: int, rz: int):
    lx = cx - rx * 32
    lz = cz - rz * 32
    if not (0 <= lx < 32 and 0 <= lz < 32):
        raise ValueError("chunk not in region")
    return lx + lz * 32


def read_u24(b):
    return (b[0] << 16) | (b[1] << 8) | b[2]


def write_u24(v):
    return bytes(((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF))


def ensure_parent(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)


def archive_move(src: Path, world_dir: Path, archive_dir: Path):
    rel = src.relative_to(world_dir)
    dst = archive_dir / rel
    ensure_parent(dst)
    if dst.exists():
        # Avoid clobbering previous archives.
        raise RuntimeError(f"archive target already exists: {dst}")
    shutil.move(str(src), str(dst))
    return dst


def archive_copy(src: Path, world_dir: Path, archive_dir: Path):
    rel = src.relative_to(world_dir)
    dst = archive_dir / rel
    ensure_parent(dst)
    if dst.exists():
        return dst
    shutil.copy2(str(src), str(dst))
    return dst


def filter_mca_file(src: Path, world_dir: Path, archive_dir: Path, keep_indices: set):
    if not src.exists():
        return {"path": str(src), "action": "missing"}

    data = src.read_bytes()
    if len(data) < 8192:
        return {"path": str(src), "action": "invalid_too_small"}

    locations = data[:4096]
    timestamps = data[4096:8192]

    new_locations = bytearray(4096)
    new_timestamps = bytearray(4096)

    out_file = bytearray(SECTOR_SIZE * 2)
    out_file[:4096] = new_locations
    out_file[4096:8192] = new_timestamps

    def append_record(record_bytes):
        # record_bytes includes 4-byte len + 1-byte compression + payload
        if len(out_file) % SECTOR_SIZE != 0:
            out_file.extend(b"\x00" * (SECTOR_SIZE - (len(out_file) % SECTOR_SIZE)))
        start_sector = len(out_file) // SECTOR_SIZE
        out_file.extend(record_bytes)
        if len(out_file) % SECTOR_SIZE != 0:
            out_file.extend(b"\x00" * (SECTOR_SIZE - (len(out_file) % SECTOR_SIZE)))
        end_sector = len(out_file) // SECTOR_SIZE
        return start_sector, end_sector - start_sector

    kept = 0
    for i in sorted(keep_indices):
        entry = locations[i * 4 : i * 4 + 4]
        offset = read_u24(entry[:3])
        sectors = entry[3]
        if offset == 0 or sectors == 0:
            continue

        chunk_start = offset * SECTOR_SIZE
        if chunk_start + 5 > len(data):
            continue

        length = struct.unpack(">I", data[chunk_start : chunk_start + 4])[0]
        if length < 1:
            continue

        record = data[chunk_start : chunk_start + 4 + length]
        start_sector, sector_count = append_record(record)

        new_locations[i * 4 : i * 4 + 3] = write_u24(start_sector)
        new_locations[i * 4 + 3] = sector_count & 0xFF
        new_timestamps[i * 4 : i * 4 + 4] = timestamps[i * 4 : i * 4 + 4]
        kept += 1

    out_file[:4096] = new_locations
    out_file[4096:8192] = new_timestamps

    # Archive original (copy) then overwrite.
    archive_copy(src, world_dir, archive_dir)
    tmp = src.with_suffix(src.suffix + ".tmp")
    tmp.write_bytes(bytes(out_file))
    tmp.replace(src)

    return {"path": str(src), "action": "filtered", "kept_chunks_in_file": kept}


def trim_overworld(world_dir: Path, keep_chunks: set, archive_dir: Path):
    # We only support a keep-list that fits within a single region file set.
    regions = {region_coords_for_chunk(cx, cz) for (cx, cz) in keep_chunks}
    if len(regions) != 1:
        raise ValueError(f"keep chunks span multiple regions: {sorted(list(regions))} (expected 1 region)")
    (rx, rz) = next(iter(regions))

    keep_indices = set(local_index_in_region(cx, cz, rx, rz) for (cx, cz) in keep_chunks)
    region_name = f"r.{rx}.{rz}.mca"

    report = {
        "overworld": {
            "region": {"kept_region": region_name, "kept_indices": sorted(list(keep_indices))},
            "moved_region_files": 0,
            "moved_entity_files": 0,
            "moved_poi_files": 0,
            "filtered": [],
        }
    }

    def process_folder(folder_rel: str, counter_key: str):
        folder = world_dir / folder_rel
        if not folder.exists():
            return
        keep_file = folder / region_name
        # Move all other .mca files aside (archive move).
        for mca in sorted(folder.glob("*.mca")):
            if mca.name == region_name:
                continue
            archive_move(mca, world_dir, archive_dir)
            report["overworld"][counter_key] += 1

        # Filter the keep region to only the kept indices.
        if not keep_file.exists():
            raise RuntimeError(f"missing required keep region file: {keep_file}")
        report["overworld"]["filtered"].append(filter_mca_file(keep_file, world_dir, archive_dir, keep_indices))

    process_folder("region", "moved_region_files")
    process_folder("entities", "moved_entity_files")
    process_folder("poi", "moved_poi_files")

    return report


def trim_other_dimensions(world_dir: Path, archive_dir: Path):
    removed = []
    for rel in ["DIM-1", "DIM1", "dimensions"]:
        p = world_dir / rel
        if not p.exists():
            continue
        removed.append({"path": str(p), "archived_to": str(archive_move(p, world_dir, archive_dir))})
    return removed


def main(argv):
    if len(argv) != 5:
        print("usage: trim_world_keep_chunks.py <world_dir> <keep_chunks> <archive_dir> <report_path>", file=sys.stderr)
        return 2

    world_dir = Path(argv[1])
    keep_spec = argv[2]
    archive_dir = Path(argv[3])
    report_path = Path(argv[4])

    keep_chunks = parse_keep_chunks(keep_spec)

    archive_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()

    report = {
        "started_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "world_dir": str(world_dir),
        "archive_dir": str(archive_dir),
        "keep_chunks": sorted([{"chunkX": cx, "chunkZ": cz} for (cx, cz) in keep_chunks], key=lambda d: (d["chunkX"], d["chunkZ"])),
        "overworld": {},
        "other_dimensions_archived": [],
    }

    report.update(trim_overworld(world_dir, keep_chunks, archive_dir))
    report["other_dimensions_archived"] = trim_other_dimensions(world_dir, archive_dir)

    report["finished_at_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    report["duration_seconds"] = int(time.time() - started)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("[world-trim] done in %ss" % report["duration_seconds"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

