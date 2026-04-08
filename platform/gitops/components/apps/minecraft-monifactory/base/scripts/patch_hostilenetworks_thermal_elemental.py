import json
from pathlib import Path


def main() -> int:
    path = Path("/data/kubejs/data/hostilenetworks/data_models/thermal/thermal_elemental.json")
    if not path.exists():
        print("[deploykube-ban-nuked-items] hostilenetworks thermal_elemental model missing; skipping")
        return 0

    data = json.loads(path.read_text(encoding="utf-8"))
    drops = data.get("fabricator_drops")
    if not isinstance(drops, list):
        print("[deploykube-ban-nuked-items] hostilenetworks thermal_elemental fabricator_drops missing/invalid; skipping")
        return 0

    nuked = {"thermal:blitz_rod", "thermal:basalz_rod", "thermal:blizz_rod"}
    new_drops = [d for d in drops if not (isinstance(d, dict) and d.get("item") in nuked)]
    if new_drops == drops:
        print("[deploykube-ban-nuked-items] hostilenetworks thermal_elemental model already clean")
        return 0

    data["fabricator_drops"] = new_drops
    path.write_text(json.dumps(data, indent=4) + "\n", encoding="utf-8")
    print("[deploykube-ban-nuked-items] removed thermal rods from hostilenetworks thermal_elemental model")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
