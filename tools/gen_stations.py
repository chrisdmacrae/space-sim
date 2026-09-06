#!/usr/bin/env python3
"""Orbital stations as fastart documents: the same brutalist, monochrome
language as the hulls in gen_ships.py -- slabs, stacked modules, panel lines,
no organic curves outside of tankage and the habitat ring.

One document per station kind, so the five read apart at a glance without
relying on colour:

* **hub** -- a trade exchange: a drum with four radial arms and a berth at
  the end of each, where the traffic ties up.
* **shipyard** -- an open gantry: two beams, cross-braced, with a part-built
  hull slung between them and two cranes hanging off the top beam.
* **refinery** -- tankage: one big cylinder, two small ones, a pipe spine and
  a flare boom with the burn at its tip.
* **depot** -- containers: a spine carrying stacked boxes in alternating
  shades, plus a docking mast and dish.
* **habitat** -- a spun ring on four spokes about a hub, windows around the
  rim.

Colours are the document's own tokens (station, station_dark, station_light,
station_line, station_accent). The game overrides `station_accent` per kind
from render.station_color, so every other token has to carry the silhouette on
its own.

Coordinates: document units, y-down as on screen. Stations are drawn without
rotation, so there is no facing convention to keep. **Every document fits
inside +/-12 units**, which is what core.STATION_DOC_HALF records and what
STATION_DOC_SCALE is tuned against -- the check at the bottom fails the build
rather than letting one drift wider and quietly change every station's size.

    python3 tools/gen_stations.py   # writes assets/stations/*.fart
"""
import json, math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "stations")

HALF = 12.0  # design envelope; mirrors core.STATION_DOC_HALF

PALETTE = [
    {"name": "station",        "rgb": [190, 196, 205, 255]},
    {"name": "station_dark",   "rgb": [104, 112, 126, 255]},
    {"name": "station_light",  "rgb": [226, 231, 238, 255]},
    {"name": "station_line",   "rgb": [68, 74, 86, 255]},
    {"name": "station_accent", "rgb": [232, 122, 58, 255]},
]


def rnd(p):
    return [round(p[0], 3), round(p[1], 3)]


def quad_tris(n):
    out = []
    for i in range(1, n - 1):
        out += [0, i, i + 1]
    return out


def poly(color, pts):
    pts = [rnd(p) for p in pts]
    return {"kind": "poly", "color": color, "points": pts, "tris": quad_tris(len(pts))}


def box(color, x0, y0, x1, y1):
    return poly(color, [(x0, y0), (x1, y0), (x1, y1), (x0, y1)])


def circle(color, at, r):
    return {"kind": "circle", "color": color, "at": rnd(at), "r": round(r, 3)}


def line(color, a, b, w):
    return {"kind": "line", "color": color, "a": rnd(a), "b": rnd(b), "w": round(w, 3)}


def chamfer_box(color, x0, y0, x1, y1, c):
    """A box with its +x corners cut at 45 degrees."""
    return poly(color, [(x0, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), (x0, y1)])


def ngon(color, at, r, n, phase=0.0):
    pts = [(at[0] + r * math.cos(phase + 2 * math.pi * i / n),
            at[1] + r * math.sin(phase + 2 * math.pi * i / n)) for i in range(n)]
    return poly(color, pts)


def ring(color, r, w, n=32, at=(0, 0)):
    """A torus as a closed polyline: the only way to get a hole, since the
    renderer fills every poly."""
    out = []
    for i in range(n):
        a0 = 2 * math.pi * i / n
        a1 = 2 * math.pi * (i + 1) / n
        out.append(line(color,
                        (at[0] + r * math.cos(a0), at[1] + r * math.sin(a0)),
                        (at[0] + r * math.cos(a1), at[1] + r * math.sin(a1)), w))
    return out


def spar(color, a, b, w, cap=None, cap_r=0.0):
    out = [line(color, a, b, w)]
    if cap:
        out.append(circle(cap, b, cap_r))
    return out


def part(name, shapes):
    # Pivot is always written, as in gen_ships.py: the preview rasteriser
    # requires it even though the game defaults it to the origin.
    return {"name": name, "pivot": [0, 0], "shapes": shapes}


def doc(name, parts):
    return {"version": 1, "name": name, "palette": PALETTE, "parts": parts, "states": []}


# ------------------------------------------------------------------ kinds

def hub():
    """Drum with four radial arms; a berth block across the end of each."""
    drum = [
        ngon("station_dark", (0, 0), 5.0, 8, math.pi / 8),
        ngon("station", (0, 0), 4.2, 8, math.pi / 8),
        ngon("station_light", (0, 0), 2.6, 8, math.pi / 8),
        circle("station_accent", (0, 0), 1.4),
    ]
    for i in range(8):
        a = math.pi / 8 + 2 * math.pi * i / 8
        drum.append(line("station_line", (2.6 * math.cos(a), 2.6 * math.sin(a)),
                         (4.2 * math.cos(a), 4.2 * math.sin(a)), 0.3))

    arms = []
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        # Spar out from the drum, then a berth laid across its tip.
        arms.append(line("station_dark", (4.0 * ca, 4.0 * sa), (10.0 * ca, 10.0 * sa), 1.7))
        arms.append(line("station", (4.4 * ca, 4.4 * sa), (9.6 * ca, 9.6 * sa), 0.8))
        tip = (10.4 * ca, 10.4 * sa)
        px, py = -sa, ca  # across the arm
        arms.append(poly("station_dark", [
            (tip[0] + px * 2.6 - ca * 1.1, tip[1] + py * 2.6 - sa * 1.1),
            (tip[0] + px * 2.6 + ca * 1.1, tip[1] + py * 2.6 + sa * 1.1),
            (tip[0] - px * 2.6 + ca * 1.1, tip[1] - py * 2.6 + sa * 1.1),
            (tip[0] - px * 2.6 - ca * 1.1, tip[1] - py * 2.6 - sa * 1.1),
        ]))
        arms.append(line("station_light", (tip[0] + px * 2.2, tip[1] + py * 2.2),
                         (tip[0] - px * 2.2, tip[1] - py * 2.2), 0.5))
    return doc("station_hub", [part("arms", arms), part("drum", drum)])


def shipyard():
    """Two gantry beams, cross-braced, around a hull under construction."""
    frame = [
        box("station_dark", -11.0, -8.4, 11.0, -6.4),
        box("station_dark", -11.0, 6.4, 11.0, 8.4),
        box("station", -11.0, -7.9, 11.0, -6.9),
        box("station", -11.0, 6.9, 11.0, 7.9),
    ]
    for x in (-9.2, -5.6, -2.0, 2.0, 5.6, 9.2):
        frame.append(line("station_line", (x, -6.4), (x, 6.4), 0.55))
    # Cranes off the top beam, reaching down to the work.
    for x, drop in ((-6.6, 3.4), (4.4, 4.2)):
        frame.append(line("station_dark", (x, -6.4), (x, -6.4 + drop), 0.9))
        frame.append(line("station_dark", (x, -6.4 + drop), (x + 2.4, -6.4 + drop), 0.7))
        frame.append(circle("station_accent", (x + 2.4, -6.4 + drop), 0.6))

    hull = [
        box("station", -6.4, -2.6, 4.0, 2.6),
        chamfer_box("station_light", 4.0, -2.0, 8.2, 2.0, 1.1),
        box("station_dark", -6.4, -2.6, -3.6, 2.6),
        line("station_line", (-2.0, -2.6), (-2.0, 2.6), 0.35),
        line("station_line", (1.0, -2.6), (1.0, 2.6), 0.35),
        line("station_accent", (-3.6, 0), (4.0, 0), 0.4),
    ]
    return doc("station_shipyard", [part("frame", frame), part("hull", hull)])


def refinery():
    """Tank farm on a pipe spine, with a flare boom."""
    spine = [
        box("station_dark", -10.4, -1.5, 9.0, 1.5),
        box("station", -10.4, -0.9, 9.0, 0.9),
        *[line("station_line", (x, -1.5), (x, 1.5), 0.3) for x in (-7.0, -1.0, 3.0, 6.6)],
    ]
    tanks = [
        # One big cylinder, banded, and two smaller ones stacked off the spine.
        circle("station_dark", (-5.2, 0), 5.2),
        circle("station", (-5.2, 0), 4.5),
        circle("station_light", (-6.6, -1.4), 2.0),
        *ring("station_line", 3.1, 0.3, 24, at=(-5.2, 0)),
        circle("station_dark", (3.4, -5.2), 3.3),
        circle("station", (3.4, -5.2), 2.7),
        circle("station_dark", (3.4, 5.2), 3.3),
        circle("station", (3.4, 5.2), 2.7),
        line("station_dark", (3.4, -2.4), (3.4, 2.4), 1.0),
    ]
    flare = [
        line("station_dark", (9.0, 0), (10.2, -2.6), 0.9),
        line("station", (9.2, -0.2), (10.0, -2.4), 0.4),
        circle("station_accent", (10.4, -3.0), 1.1),
    ]
    return doc("station_refinery", [part("spine", spine), part("tanks", tanks), part("flare", flare)])


def depot():
    """Containers racked either side of a spine, with a mast and dish."""
    spine = [
        box("station_dark", -11.2, -1.6, 11.2, 1.6),
        box("station", -10.6, -1.0, 10.6, 1.0),
    ]
    stack = []
    for i in range(4):
        for j in range(2):
            x0 = -10.4 + i * 5.3
            y0 = 1.9 + j * 3.6
            shade = "station_light" if (i + j) % 2 == 0 else "station"
            stack.append(box(shade, x0, y0, x0 + 4.7, y0 + 3.2))
            stack.append(box(shade, x0, -y0 - 3.2, x0 + 4.7, -y0))
            stack.append(line("station_line", (x0 + 2.35, y0), (x0 + 2.35, y0 + 3.2), 0.3))
            stack.append(line("station_line", (x0 + 2.35, -y0 - 3.2), (x0 + 2.35, -y0), 0.3))
    stack.append(box("station_accent", -10.4, -8.7, -5.7, -5.5))

    mast = [
        line("station_dark", (0, -8.7), (0, -10.1), 1.0),
        line("station_dark", (-2.2, -10.1), (2.2, -10.1), 0.7),
        circle("station_light", (0, -10.5), 1.0),
        circle("station_accent", (0, -10.5), 0.45),
    ]
    return doc("station_depot", [part("spine", spine), part("stack", stack), part("mast", mast)])


def habitat():
    """A spun ring on four spokes, windows around the rim."""
    rim = [
        *ring("station_dark", 9.6, 2.6),
        *ring("station", 9.6, 1.8),
    ]
    for i in range(24):
        a = 2 * math.pi * i / 24
        rim.append(circle("station_light", (9.6 * math.cos(a), 9.6 * math.sin(a)), 0.42))

    spokes = []
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        spokes.append(line("station_dark", (2.4 * ca, 2.4 * sa), (8.8 * ca, 8.8 * sa), 1.2))
        spokes.append(line("station", (2.8 * ca, 2.8 * sa), (8.4 * ca, 8.4 * sa), 0.5))

    core = [
        circle("station_dark", (0, 0), 3.0),
        circle("station", (0, 0), 2.3),
        circle("station_accent", (0, 0), 1.1),
    ]
    return doc("station_habitat", [part("spokes", spokes), part("rim", rim), part("core", core)])


# ------------------------------------------------------------------ writing

def bounds(d):
    lo = [1e9, 1e9]
    hi = [-1e9, -1e9]

    def grow(p, r=0.0):
        lo[0] = min(lo[0], p[0] - r); lo[1] = min(lo[1], p[1] - r)
        hi[0] = max(hi[0], p[0] + r); hi[1] = max(hi[1], p[1] + r)

    for p in d["parts"]:
        for s in p["shapes"]:
            if s["kind"] == "circle":
                grow(s["at"], s["r"])
            elif s["kind"] == "line":
                grow(s["a"], s["w"] / 2); grow(s["b"], s["w"] / 2)
            elif s["kind"] == "poly":
                for q in s["points"]:
                    grow(q)
    return lo, hi


def main():
    os.makedirs(OUT, exist_ok=True)
    worst = 0.0
    for maker in (hub, shipyard, refinery, depot, habitat):
        d = maker()
        lo, hi = bounds(d)
        reach = max(abs(lo[0]), abs(lo[1]), abs(hi[0]), abs(hi[1]))
        worst = max(worst, reach)
        print(f"{d['name']:20s} {hi[0] - lo[0]:5.1f} x {hi[1] - lo[1]:5.1f}   reach {reach:5.2f}")
        with open(os.path.join(OUT, d["name"] + ".fart"), "w") as f:
            json.dump(d, f, separators=(",", ":"))
    if worst > HALF:
        raise SystemExit(
            f"a station reaches {worst:.2f} units, past the {HALF} envelope: either pull it in "
            f"or raise both HALF here and core.STATION_DOC_HALF")
    print(f"wrote 5 stations, worst reach {worst:.2f} of {HALF}")


if __name__ == "__main__":
    main()
