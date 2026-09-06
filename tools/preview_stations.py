#!/usr/bin/env python3
"""Rasterise the stations without the game: one column per kind, each in the
accent the game gives it (render.station_color), and a courier and a freighter
alongside at the size they really are next to one.

The ships are drawn at SHIP_DOC_SCALE / STATION_DOC_SCALE of the station
scale, so the comparison column is the true world-space ratio rather than
whatever fits the page -- that ratio is the whole point of the sheet.

    python3 tools/preview_stations.py out.png
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import preview_avatars as pa

ROOT = os.path.join(os.path.dirname(__file__), "..")

# Mirrors core/units.odin. A ship document unit is worth this much less world
# than a station document unit.
SHIP_DOC_SCALE = 0.02
STATION_DOC_SCALE = 0.05
SHIP_REL = SHIP_DOC_SCALE / STATION_DOC_SCALE

# Mirrors render.station_color.
KINDS = [
    ("hub", (232, 122, 58)),
    ("shipyard", (122, 204, 240)),
    ("refinery", (200, 160, 80)),
    ("depot", (120, 220, 140)),
    ("habitat", (220, 140, 220)),
]

PX = 9          # pixels per station document unit
COL = 250
ROW = 250


def load(path):
    return json.load(open(os.path.join(ROOT, *path)))


def all_parts(doc):
    """The stations carry no states; the game draws every part in order."""
    return [{"part": p["name"]} for p in doc["parts"]]


def main():
    base = {t["name"]: tuple(t["rgb"]) for t in load(("assets", "palettes", "base.fart"))["palette"]}
    cv = pa.Canvas(COL * (len(KINDS) + 1), ROW)

    for i, (kind, accent) in enumerate(KINDS):
        doc = load(("assets", "stations", f"station_{kind}.fart"))
        pal = {t["name"]: tuple(t["rgb"]) for t in doc["palette"]}
        pal["station_accent"] = accent + (255,)
        pa.draw_doc(cv, doc, None, COL // 2 + i * COL, ROW // 2, PX, pal, poses=all_parts(doc))

    # Same page, same scale: what a hull actually looks like beside one.
    x = COL // 2 + len(KINDS) * COL
    for name, y in (("courier", ROW // 2 - 40), ("freighter", ROW // 2 + 40)):
        doc = load(("assets", "ships", name + ".fart"))
        pa.draw_doc(cv, doc, "idle", x, y, PX * SHIP_REL, base)

    out = sys.argv[1] if len(sys.argv) > 1 else "stations_preview.png"
    cv.png(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
