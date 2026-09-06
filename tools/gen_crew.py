#!/usr/bin/env python3
"""Generate the crew and deck documents (.fart) in assets/crew.

crew.fart is a person seen from above: shoulders, two arms that swing from
the shoulder, a head and a cap of hair. It faces +x. The `walk` clip swings
the arms and rocks the shoulders; `idle` breathes. Every colour is a token
from palettes/crew.fart (skin, hair, cloth, cloth2, accent, line) so the game
recolours each crew member from their avatar.

deck.fart holds the furniture of the ship's interior as one part per item,
with a state per item so the renderer draws `deck.fart` in state "console"
to get just a console. Items face +x where facing matters and sit centred
on the origin; sizes are in deck units (about half a metre).

Run: python3 tools/gen_crew.py
"""
import json, math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "crew")
PAL = os.path.join(os.path.dirname(__file__), "..", "assets", "palettes")


# ---------------------------------------------------------------- geometry
def _cross(o, a, b):
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def earclip(pts):
    n = len(pts)
    if n < 3:
        return []
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    idx = list(range(n)) if area > 0 else list(range(n))[::-1]
    out = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        clipped = False
        m = len(idx)
        for i in range(m):
            i0, i1, i2 = idx[(i - 1) % m], idx[i], idx[(i + 1) % m]
            a, b, c = pts[i0], pts[i1], pts[i2]
            if _cross(a, b, c) <= 1e-12:
                continue
            ear = True
            for k in idx:
                if k in (i0, i1, i2):
                    continue
                p = pts[k]
                if _cross(a, b, p) >= 0 and _cross(b, c, p) >= 0 and _cross(c, a, p) >= 0:
                    ear = False
                    break
            if not ear:
                continue
            out += [i0, i1, i2]
            del idx[i]
            clipped = True
            break
        if not clipped:
            for i in range(1, len(idx) - 1):
                out += [idx[0], idx[i], idx[i + 1]]
            idx = []
            break
    if len(idx) == 3:
        out += idx
    return out


def rnd(p):
    return [round(p[0], 3), round(p[1], 3)]


def poly(color, pts):
    pts = [rnd(p) for p in pts]
    return {"kind": "poly", "color": color, "points": pts, "tris": earclip(pts)}


def circle(color, at, r):
    return {"kind": "circle", "color": color, "at": rnd(at), "r": round(r, 3)}


def line(color, a, b, w):
    return {"kind": "line", "color": color, "a": rnd(a), "b": rnd(b), "w": round(w, 3)}


def rect(color, cx, cy, w, h):
    return poly(color, [(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2), (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2)])


def ellipse(color, cx, cy, rx, ry, n=20):
    return poly(color, [(cx + rx * math.cos(2 * math.pi * i / n), cy + ry * math.sin(2 * math.pi * i / n)) for i in range(n)])


def part(name, shapes, pivot=(0, 0), parent=""):
    p = {"name": name, "pivot": rnd(pivot), "shapes": shapes}
    if parent:
        p["parent"] = parent
    return p


def write(name, doc):
    path = os.path.join(OUT, name + ".fart")
    with open(path, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    print("wrote", os.path.relpath(path))


def write_palette(name, toks):
    path = os.path.join(PAL, name + ".fart")
    with open(path, "w") as f:
        json.dump({"version": 1, "name": name, "palette": [{"name": k, "rgb": list(v)} for k, v in toks]}, f, indent=1)
    print("wrote", os.path.relpath(path))


# ---------------------------------------------------------------- crew sprite
def crew_doc():
    # Facing +x. Shoulders about 4 units across, head just over 2.
    shoulders = ellipse("cloth", 0, 0, 1.55, 2.05)
    stripe = rect("cloth2", -0.35, 0, 0.5, 3.6)
    collar = ellipse("cloth2", 0.15, 0, 0.95, 1.25, 14)
    badge = circle("accent", (0.55, -1.15), 0.3)
    body = part("body", [shoulders, stripe, collar, badge])
    # Arms hang beside the body and swing from the shoulder along x.
    def arm(side):
        y = -1.95 * side
        return part("arm_%s" % ("l" if side > 0 else "r"),
                    [line("cloth", (0, y), (0.55, y + 0.15 * side), 0.62), circle("skin", (0.75, y + 0.18 * side), 0.36)],
                    pivot=(0, y), parent="body")
    arm_l = arm(1)
    arm_r = arm(-1)
    head = part("head", [circle("skin", (0.35, 0), 1.12), circle("skin_shade", (0.05, 0), 1.12)], parent="body")
    # Hair as a cap that covers most of the head, leaving the brow clear at the front.
    cap = [(1.05 * math.cos(a) - 0.05, 1.05 * math.sin(a)) for a in [math.radians(d) for d in range(50, 311, 15)]]
    hair = part("hair", [poly("hair", cap), circle("hair_shade", (-0.45, 0), 0.5)], parent="body")
    parts = [arm_l, arm_r, body, head, hair]
    rest = [{"part": "arm_l"}, {"part": "arm_r"}, {"part": "body"}, {"part": "head"}, {"part": "hair"}]

    def pose(al, ar, bob=1.0, sway=0.0):
        return [{"part": "arm_l", "rotate": round(al, 3)}, {"part": "arm_r", "rotate": round(ar, 3)},
                {"part": "body", "rotate": round(sway, 3), "scale": round(bob, 3)}, {"part": "head"}, {"part": "hair"}]

    states = [{"name": "idle", "parts": rest}]
    clips = [
        {"name": "idle", "loop": True, "keys": [
            {"t": 0, "parts": pose(0.05, -0.05)},
            {"t": 1.6, "parts": pose(-0.05, 0.05, 1.03), "ease": "in-out"},
            {"t": 3.2, "parts": pose(0.05, -0.05), "ease": "in-out"},
        ]},
        {"name": "walk", "loop": True, "keys": [
            {"t": 0, "parts": pose(0.7, -0.7, 1.0, 0.06)},
            {"t": 0.3, "parts": pose(-0.7, 0.7, 1.0, -0.06), "ease": "in-out"},
            {"t": 0.6, "parts": pose(0.7, -0.7, 1.0, 0.06), "ease": "in-out"},
        ]},
    ]
    return {"version": 1, "name": "crew", "palette_refs": ["../palettes/crew.fart"], "parts": parts, "states": states, "clips": clips}


# ---------------------------------------------------------------- deck furniture
def deck_doc():
    items = {}
    # Console: a desk with a lit screen, facing +x (the screen at the far edge).
    items["console"] = [rect("metal_dark", 0, 0, 1.6, 2.4), rect("metal", -0.1, 0, 1.2, 2.1),
                        rect("screen", 0.55, 0, 0.35, 1.9), rect("screen_bright", 0.55, -0.45, 0.2, 0.5), rect("screen_bright", 0.55, 0.4, 0.2, 0.3)]
    # Seat: a chair seen from above, in front of a console.
    items["seat"] = [circle("metal_dark", (0, 0), 0.62), circle("seat", (0, 0), 0.5), rect("metal_dark", -0.5, 0, 0.18, 1.0)]
    # Bunk: a mattress with a pillow at the -x end and a blanket.
    items["bunk"] = [rect("metal_dark", 0, 0, 3.0, 1.6), rect("mattress", 0, 0, 2.75, 1.35), rect("blanket", 0.45, 0, 1.7, 1.2), rect("pillow", -0.95, 0, 0.6, 1.05)]
    # Table with a couple of seats at each long side.
    items["table"] = [ellipse("metal_dark", 0, 0, 2.3, 1.35), ellipse("table", 0, 0, 2.1, 1.15), circle("mug", (0.7, -0.3), 0.22), circle("mug", (-0.6, 0.35), 0.22)]
    # Crate: a strapped container.
    items["crate"] = [rect("crate_dark", 0, 0, 2.0, 2.0), rect("crate", 0, 0, 1.7, 1.7), rect("crate_dark", 0, 0, 0.3, 1.7), rect("crate_dark", 0, 0, 1.7, 0.3)]
    # Reactor: a ring with a hot core and coolant pipes.
    ring = [circle("metal_dark", (0, 0), 2.6), circle("metal", (0, 0), 2.25), circle("reactor_rim", (0, 0), 1.5), circle("reactor", (0, 0), 1.1), circle("reactor_core", (0, 0), 0.55)]
    for k in range(6):
        a = 2 * math.pi * k / 6
        ring.append(line("pipe", (1.7 * math.cos(a), 1.7 * math.sin(a)), (2.55 * math.cos(a), 2.55 * math.sin(a)), 0.34))
    items["reactor"] = ring
    # Tank: a propellant cylinder along x with a fill band.
    items["tank"] = [ellipse("metal_dark", 0, 0, 2.55, 1.05), ellipse("metal", 0, 0, 2.35, 0.85), rect("pipe", 0, 0, 4.2, 0.18), circle("metal_dark", (-2.35, 0), 0.5), circle("metal_dark", (2.35, 0), 0.5)]
    # Panel: a wall cabinet of switches (engineering).
    items["panel"] = [rect("metal_dark", 0, 0, 0.9, 2.6), rect("metal", 0, 0, 0.7, 2.4), circle("lamp_green", (0, -0.8), 0.14), circle("lamp_green", (0, -0.4), 0.14), circle("lamp_amber", (0, 0.2), 0.14), rect("screen", 0, 0.8, 0.45, 0.6)]
    # Antenna rack: comms gear with a dish.
    items["antenna"] = [rect("metal_dark", 0, 0, 2.2, 2.6), rect("metal", 0, 0, 2.0, 2.4), circle("metal_dark", (0.2, -0.3), 0.85), circle("dish", (0.2, -0.3), 0.7), circle("metal_dark", (0.2, -0.3), 0.15), rect("screen", -0.4, 0.75, 1.1, 0.5), circle("lamp_green", (0.6, 0.75), 0.14)]
    # Cryo pod: a long capsule with a frosted window.
    items["pod"] = [ellipse("metal_dark", 0, 0, 2.45, 1.15), ellipse("metal", 0, 0, 2.25, 0.95), ellipse("frost", 0.3, 0, 1.5, 0.6), circle("lamp_blue", (-1.75, 0), 0.16)]
    # Locker: suit storage by the airlock.
    items["locker"] = [rect("metal_dark", 0, 0, 1.0, 1.8), rect("metal", 0, 0, 0.8, 1.6), rect("metal_dark", 0, 0, 0.12, 1.4), circle("lamp_amber", (0.25, -0.5), 0.1)]
    # Hatch: the airlock door marking on the outer wall.
    items["hatch"] = [rect("hatch", 0, 0, 3.2, 0.8), rect("hatch_stripe", -1.0, 0, 0.5, 0.8), rect("hatch_stripe", 0, 0, 0.5, 0.8), rect("hatch_stripe", 1.0, 0, 0.5, 0.8), circle("metal_dark", (0, 0), 0.25)]
    parts = [part(k, v) for k, v in items.items()]
    states = [{"name": k, "parts": [{"part": k}]} for k in items]
    return {"version": 1, "name": "deck", "palette_refs": ["../palettes/deck.fart"], "parts": parts, "states": states, "clips": []}


def main():
    os.makedirs(OUT, exist_ok=True)
    write_palette("crew", [
        ("skin", (224, 180, 150, 255)), ("skin_shade", (196, 152, 122, 255)), ("hair", (70, 48, 36, 255)), ("hair_shade", (50, 34, 26, 255)),
        ("cloth", (86, 104, 138, 255)), ("cloth2", (54, 66, 92, 255)), ("accent", (232, 122, 58, 255)), ("line", (20, 22, 30, 255)),
    ])
    write_palette("deck", [
        ("metal", (96, 104, 120, 255)), ("metal_dark", (52, 58, 70, 255)), ("screen", (58, 120, 150, 255)), ("screen_bright", (150, 220, 240, 255)),
        ("seat", (110, 72, 58, 255)), ("mattress", (150, 150, 160, 255)), ("blanket", (78, 96, 140, 255)), ("pillow", (210, 210, 220, 255)),
        ("table", (130, 100, 74, 255)), ("mug", (220, 220, 230, 255)), ("crate", (156, 128, 82, 255)), ("crate_dark", (96, 76, 46, 255)),
        ("reactor_rim", (120, 60, 50, 255)), ("reactor", (220, 110, 70, 255)), ("reactor_core", (255, 220, 170, 255)), ("pipe", (140, 150, 170, 255)),
        ("lamp_green", (120, 230, 140, 255)), ("lamp_amber", (240, 190, 90, 255)), ("lamp_blue", (120, 180, 255, 255)),
        ("dish", (190, 200, 215, 255)), ("frost", (170, 210, 240, 200)), ("hatch", (170, 170, 60, 255)), ("hatch_stripe", (30, 30, 30, 255)),
    ])
    write("crew", crew_doc())
    write("deck", deck_doc())


if __name__ == "__main__":
    main()
