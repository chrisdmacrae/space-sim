#!/usr/bin/env python3
"""Ship hulls as fastart documents: brutalist, monochrome, blocky. Slabs,
stacked modules, chamfered corners, panel lines, no fins or nose cones.

Each hull is drawn once and animated by pose (fastart clips, format 1.2):

* **Traversal.** The exhaust is three parts -- a glow at the mouth, the blue
  plume, the white-hot core -- parented to the engine bell, so a gimbal
  carries the fire with it. Clips `burn_min` and `burn` flicker the same
  parts at low and full throttle; the game blends the two by throttle and
  crossfades from `idle` when the engine lights.
* **Rotation.** Four attitude jets at the bow and stern corners. Turning
  fires the pair that produces the couple: the bow jet on the side *away*
  from the turn, the stern jet on the near side. Clips `turn_left` and
  `turn_right` flicker that pair and gimbal the bell a few degrees; the
  game layers them over whatever the engine is doing.

Tokens (palettes/base.fart): hull, hull_dark, hull_light, line, flame,
flame_core, flame_glow, rcs. The game overrides "hull" per trader with a grey.
Coordinates: document units, ship points +x. Document space is y-down (the
screen's), and the hulls are symmetric about y = 0, so only the attitude
jets care which side is which: +y is the side drawn below the ship.
Length: courier ~21, hauler ~31, clipper ~28, freighter ~44, sleeper ~30.

    python3 tools/gen_ships.py   # writes assets/ships/*.fart
"""
import json, math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "ships")


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


def chamfer_box(color, x0, y0, x1, y1, c):
    """A box with its front corners cut at 45 degrees."""
    return poly(color, [(x0, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), (x0, y1)])


def line(color, a, b, w):
    return {"kind": "line", "color": color, "a": rnd(a), "b": rnd(b), "w": round(w, 3)}


def part(name, shapes, pivot=(0, 0), anchors=None, parent=None):
    p = {"name": name, "pivot": [pivot[0], pivot[1]], "shapes": shapes}
    if parent:
        p["parent"] = parent
    if anchors:
        p["anchors"] = [{"name": n, "at": [a[0], a[1]], "angle": round(ang, 3)} for n, a, ang in anchors]
    return p


def panel_lines(x0, x1, y, n, color="line"):
    """Evenly spaced transverse seams across a slab."""
    out = []
    for i in range(1, n):
        x = x0 + (x1 - x0) * i / n
        out.append(line(color, (x, -y), (x, y), 0.35))
    return out


# ------------------------------------------------------------------ exhaust
def plume(px, half):
    """The exhaust behind the nozzle mouth at (px, 0): a soft glow, the blue
    plume in stepped blocks, and the white-hot core with its shock diamonds.
    Three parts so they can flicker out of step; all children of the engine,
    and all pivoted on the mouth so a pose's `scale` grows them backwards."""
    L = 3.0 * half + 2.6
    # The glow is a chain of faint circles marching down the plume, each a
    # little smaller: overlapping alpha makes the falloff, and following the
    # exhaust makes it light rather than a bubble around the bell.
    return [
        part("glow", [circle("flame_glow", (px - half * (0.15 + 0.75 * i), 0), half * (1.75 - 0.28 * i))
                      for i in range(5)],
             pivot=(px, 0), parent="engine"),
        part("flame", [
            box("flame", px - L * 0.42, -half, px, half),
            box("flame", px - L * 0.76, -half * 0.58, px - L * 0.42, half * 0.58),
            box("flame", px - L, -half * 0.26, px - L * 0.76, half * 0.26),
        ], pivot=(px, 0), parent="engine"),
        part("flame_hot", [
            box("flame_core", px - L * 0.34, -half * 0.44, px, half * 0.44),
            box("flame_core", px - L * 0.52, -half * 0.2, px - L * 0.44, half * 0.2),
            box("flame_core", px - L * 0.68, -half * 0.12, px - L * 0.62, half * 0.12),
        ], pivot=(px, 0), parent="engine"),
    ]


# --------------------------------------------------------------- attitude jets
def housing(x, y, s, w):
    """The thruster block on the hull side, always drawn (part of the hull)."""
    return [
        box("hull_dark", x - w, min(s * y, s * (y + 0.6)), x + w, max(s * y, s * (y + 0.6))),
        line("line", (x - w, s * (y + 0.6)), (x + w, s * (y + 0.6)), 0.3),
    ]


def jet(name, x, y, s, w, length):
    """A cold-gas plume venting away from the hull at (x, s*y): two blocks
    tapering outward with a hot slug at the mouth. Pivoted at the port, so a
    pose's `scale` is how hard the jet is firing."""
    y0 = y + 0.6
    mid = y0 + length * 0.5
    return part(name, [
        poly("rcs", [(x - w, s * y0), (x + w, s * y0),
                     (x + w * 0.85, s * mid), (x - w * 0.85, s * mid)]),
        poly("rcs", [(x - w * 0.7, s * mid), (x + w * 0.7, s * mid),
                     (x + w * 0.5, s * (y0 + length)), (x - w * 0.5, s * (y0 + length))]),
        poly("flame_core", [(x - w * 0.45, s * y0), (x + w * 0.45, s * y0),
                            (x + w * 0.35, s * (y0 + length * 0.3)), (x - w * 0.35, s * (y0 + length * 0.3))]),
    ], pivot=(x, s * y0), parent="hull")


# ------------------------------------------------------------------ assembly
BELL = 0.09  # radians the engine bell gimbals into a turn


def burn_state(name, glow, flame, core):
    return {"name": name, "parts": [
        {"part": "glow", "scale": glow},
        {"part": "flame", "scale": flame},
        {"part": "flame_hot", "scale": core},
        {"part": "hull"},
        {"part": "engine"},
    ]}


def turn_state(name, side, scale, bell):
    """Hull and bell, plus the pair of jets that turn the ship this way. The
    game layers this over the base pose, so the parts it leaves out (the
    exhaust) keep whatever the engine is doing."""
    return {"name": name, "parts": [
        {"part": "hull"},
        {"part": "engine", "rotate": round(bell, 3)},
        {"part": "rcs_%s_bow" % side, "scale": scale},
        {"part": "rcs_%s_stern" % side, "scale": round(scale * 0.8, 3)},
    ]}


def flicker(name, lo, hi, period):
    """A two-pose loop: out to `hi` and back, eased both ways."""
    return {"name": name, "loop": True, "keys": [
        {"t": 0, "state": lo},
        {"t": round(period * 0.45, 3), "state": hi, "ease": "in-out"},
        {"t": period, "state": lo, "ease": "in-out"},
    ]}


def doc(name, hull, engine, nozzle, bow, stern, length, height):
    """One hull: the drawn parts, the poses the game puts them in, and the
    clips over those poses. `nozzle` is (x, half-width) of the engine mouth;
    `bow` and `stern` are (x, hull half-height) where the jets sit."""
    px, half = nozzle
    bx, bh = bow
    sx, sh = stern
    w = round(max(0.6, height * 0.09), 3)     # port half-width
    jl = round(max(1.8, height * 0.22), 3)    # jet length

    # +y is the side drawn below the ship. Turning left swings the nose to
    # -y, so the bow jet on the +y side fires (the side away from the turn)
    # with the stern jet on -y: a couple, not a shove.
    jets = [
        jet("rcs_l_bow", bx, bh, 1, w, jl),
        jet("rcs_l_stern", sx, sh, -1, w * 0.9, jl * 0.8),
        jet("rcs_r_bow", bx, bh, -1, w, jl),
        jet("rcs_r_stern", sx, sh, 1, w * 0.9, jl * 0.8),
    ]
    for x, y in ((bx, bh), (sx, sh)):
        for s in (1, -1):
            hull["shapes"] += housing(x, y, s, w)
    hull.setdefault("anchors", []).extend([
        {"name": "rcs_bow", "at": [bx, bh + 0.6], "angle": round(math.pi / 2, 3)},
        {"name": "rcs_stern", "at": [sx, -(sh + 0.6)], "angle": round(-math.pi / 2, 3)},
    ])

    return {
        "version": 1, "name": name, "palette_refs": ["../palettes/base.fart"],
        "parts": plume(px, half) + [hull, engine] + jets,
        "states": [
            {"name": "idle", "parts": [{"part": "hull"}, {"part": "engine"}]},
            burn_state("burn", 1, 1, 1),
            {"name": "docked", "parts": [{"part": "hull"}, {"part": "engine"}]},
            burn_state("burn_off", 0.02, 0.02, 0.02),
            burn_state("min_lo", 0.48, 0.40, 0.38),
            burn_state("min_hi", 0.60, 0.54, 0.50),
            burn_state("burn_lo", 0.92, 0.90, 0.86),
            burn_state("burn_hi", 1.14, 1.12, 1.04),
            turn_state("turn_l_lo", "l", 0.75, BELL),
            turn_state("turn_l_hi", "l", 1.10, BELL),
            turn_state("turn_r_lo", "r", 0.75, -BELL),
            turn_state("turn_r_hi", "r", 1.10, -BELL),
        ],
        "clips": [
            {"name": "idle", "loop": True, "keys": [{"t": 0, "state": "idle"}]},
            flicker("burn_min", "min_lo", "min_hi", 0.26),
            flicker("burn", "burn_lo", "burn_hi", 0.16),
            flicker("turn_left", "turn_l_lo", "turn_l_hi", 0.13),
            flicker("turn_right", "turn_r_lo", "turn_r_hi", 0.13),
        ],
        "collision": [{"kind": "line", "a": [-length / 2, 0], "b": [length / 2, 0], "w": height}],
    }


# ---------------------------------------------------------------- hulls
def courier():
    hull = part("hull", [
        chamfer_box("hull", -7, -3.2, 10.5, 3.2, 1.6),
        box("hull_dark", -4, 3.2, 3, 4.6),
        box("hull_dark", -4, -4.6, 3, -3.2),
        box("hull_light", -2, -1.6, 4.5, 1.6),
        *panel_lines(-7, 8, 3.2, 4),
        line("line", (-2, -1.6), (4.5, -1.6), 0.3),
        line("line", (-2, 1.6), (4.5, 1.6), 0.3),
        box("hull_light", 7.6, -0.6, 8.8, 0.6),
    ], anchors=[("dock", (0, -4.6), -math.pi / 2)])
    engine = part("engine", [
        box("hull_dark", -10.5, -2.6, -7, 2.6),
        line("line", (-10.5, -2.6), (-10.5, 2.6), 0.6),
        box("hull", -9.5, -1.0, -8, 1.0),
    ], pivot=(-8.5, 0), anchors=[("thrust", (-10.5, 0), math.pi)])
    return doc("courier", hull, engine, (-10.5, 2.0), (6.2, 3.2), (-5.6, 3.2), 21, 9)


def hauler():
    frames = []
    for i in range(3):
        x0 = -9 + i * 7
        frames += [
            box("hull_dark", x0, -6.2, x0 + 5.4, 6.2),
            box("hull", x0 + 0.8, -5.4, x0 + 4.6, 5.4),
            line("line", (x0 + 2.7, -5.4), (x0 + 2.7, 5.4), 0.35),
            line("line", (x0 + 0.8, 0), (x0 + 4.6, 0), 0.35),
        ]
    hull = part("hull", [
        box("hull", -11, -3, 12, 3),
        *frames,
        chamfer_box("hull_light", 12, -3.8, 16.5, 3.8, 1.2),
        line("line", (13, -3.8), (13, 3.8), 0.4),
        box("hull_light", 15.2, -0.5, 16, 0.5),
    ], anchors=[("dock", (0, -6.2), -math.pi / 2)])
    engine = part("engine", [
        box("hull_dark", -14.5, 1.8, -11, 5.6),
        box("hull_dark", -14.5, -5.6, -11, -1.8),
        box("hull", -13, -1.2, -11, 1.2),
        line("line", (-14.5, 1.8), (-14.5, 5.6), 0.6),
        line("line", (-14.5, -5.6), (-14.5, -1.8), 0.6),
    ], pivot=(-12, 0), anchors=[("thrust", (-14.5, 0), math.pi)])
    return doc("hauler", hull, engine, (-14.5, 3.6), (14.2, 3.2), (-10.2, 3), 31, 13)


def clipper():
    hull = part("hull", [
        box("hull", -9, -2.2, 11, 2.2),
        poly("hull_light", [(11, -2.2), (15.5, -0.9), (15.5, 0.9), (11, 2.2)]),
        box("hull_dark", -8, 2.6, 3.5, 5.2),
        box("hull_dark", -8, -5.2, 3.5, -2.6),
        line("line", (-8, 3.9), (3.5, 3.9), 0.35),
        line("line", (-8, -3.9), (3.5, -3.9), 0.35),
        box("hull_light", -6, -0.8, 8.5, 0.8),
        *panel_lines(-9, 11, 2.2, 5),
    ], anchors=[("dock", (0, -5.2), -math.pi / 2)])
    engine = part("engine", [
        box("hull_dark", -13, -3.2, -9, 3.2),
        box("hull", -12, -1.4, -9, 1.4),
        line("line", (-13, -3.2), (-13, 3.2), 0.6),
    ], pivot=(-10.5, 0), anchors=[("thrust", (-13, 0), math.pi)])
    return doc("clipper", hull, engine, (-13, 2.6), (9.2, 2.2), (-8.5, 2.2), 28, 10)


def freighter():
    grid = []
    for i in range(4):
        for j in range(2):
            x0 = -14 + i * 8
            y0 = -5.4 + j * 5.6
            shade = "hull_dark" if (i + j) % 2 == 0 else "hull_light"
            grid.append(box(shade, x0, y0, x0 + 6.8, y0 + 5.2))
            grid.append(line("line", (x0, y0 + 2.6), (x0 + 6.8, y0 + 2.6), 0.3))
    hull = part("hull", [
        box("hull", -16, -6.2, 18, 6.2),
        *grid,
        chamfer_box("hull_light", 18, -3.6, 22.5, 3.6, 1.2),
        line("line", (19.5, -3.6), (19.5, 3.6), 0.4),
        box("hull_dark", 20.5, -1.2, 21.8, 1.2),
    ], anchors=[("dock", (0, -6.2), -math.pi / 2)])
    engine = part("engine", [
        box("hull_dark", -20.5, 3.4, -16, 6.4),
        box("hull_dark", -20.5, 0.6, -16, 2.6),
        box("hull_dark", -20.5, -2.6, -16, -0.6),
        box("hull_dark", -20.5, -6.4, -16, -3.4),
        line("line", (-20.5, -6.4), (-20.5, 6.4), 0.6),
    ], pivot=(-18, 0), anchors=[("thrust", (-20.5, 0), math.pi)])
    return doc("freighter", hull, engine, (-20.5, 4.2), (17, 6.2), (-15, 6.2), 44, 13)


def sleeper():
    hull = part("hull", [
        box("hull", -10, -3.6, 10, 3.6),
        box("hull_light", -4.5, -6.2, 6.5, 6.2),
        line("line", (-4.5, -6.2), (-4.5, 6.2), 0.45),
        line("line", (6.5, -6.2), (6.5, 6.2), 0.45),
        *[line("line", (x, -6.2), (x, 6.2), 0.3) for x in (-1.8, 1.0, 3.8)],
        box("hull_dark", -1.2, -1.4, 3.2, 1.4),
        chamfer_box("hull", 10, -2.6, 14.5, 2.6, 1.0),
        box("hull_light", 13.2, -0.6, 14, 0.6),
        line("line", (-10, 0), (-4.5, 0), 0.3),
    ], anchors=[("dock", (0, -6.2), -math.pi / 2)])
    engine = part("engine", [
        box("hull_dark", -14.5, -4.6, -10, 4.6),
        box("hull", -13.2, -2.0, -10, 2.0),
        line("line", (-14.5, -4.6), (-14.5, 4.6), 0.6),
        line("line", (-12.2, -4.6), (-12.2, 4.6), 0.3),
    ], pivot=(-12, 0), anchors=[("thrust", (-14.5, 0), math.pi)])
    return doc("sleeper", hull, engine, (-14.5, 3.2), (8.4, 3.6), (-8.4, 3.6), 30, 13)


def main():
    os.makedirs(OUT, exist_ok=True)
    for maker in (courier, hauler, clipper, freighter, sleeper):
        d = maker()
        with open(os.path.join(OUT, d["name"] + ".fart"), "w") as f:
            json.dump(d, f, separators=(",", ":"))
    print("wrote 5 hulls")


if __name__ == "__main__":
    main()
