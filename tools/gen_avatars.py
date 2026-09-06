#!/usr/bin/env python3
"""Generate the NPC avatar feature documents (.fart) in assets/avatars.

A face is composed at draw time from one document per feature, drawn in
layers: hair back, head, collar, eyes, brows, nose, mouth, facial hair,
hair front, extra. Every document uses the tokens in palettes/avatar.fart
(skin, skin_shade, hair, hair_shade, eye, sclera, cloth, cloth2, accent,
line, mouth, teeth) so the game recolours each person.

Coordinates: document units, y down, the face fits a 32 x 32 box centred
on the origin. Eyes sit at y = -3, the mouth at y = 6, ears at x = +-11.

Run: python3 tools/gen_avatars.py
"""
import json, math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "avatars")


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


def ellipse(cx, cy, rx, ry, n=28, a0=0.0, a1=2 * math.pi, close=None):
    pts = []
    for i in range(n + 1):
        t = a0 + (a1 - a0) * i / n
        pts.append((cx + math.cos(t) * rx, cy + math.sin(t) * ry))
    if close:
        pts += close
    return pts


def mirror(pts):
    return [(-x, y) for x, y in pts]


def doc(name, parts, states=None):
    if states is None:
        states = [{"name": "idle", "parts": [{"part": p["name"]} for p in parts]}]
    return {"version": 1, "name": name, "palette_refs": ["../palettes/avatar.fart"], "parts": parts, "states": states}


def part(name, shapes):
    return {"name": name, "pivot": [0, 0], "shapes": shapes}


def write(name, d):
    with open(os.path.join(OUT, name + ".fart"), "w") as f:
        json.dump(d, f, separators=(",", ":"))


# ---------------------------------------------------------------- heads
def head(kind):
    shapes = []
    # neck first so the head overlaps it
    shapes.append(poly("skin_shade", [(-4.5, 6), (4.5, 6), (4.2, 17), (-4.2, 17)]))
    # ears
    for sx in (-1, 1):
        shapes.append(circle("skin", (sx * 11, -1), 2.6))
        shapes.append(circle("skin_shade", (sx * 11.2, -1), 1.3))
    if kind == 0:  # round
        outline = ellipse(0, -1, 11, 13)
    elif kind == 1:  # long oval
        outline = ellipse(0, -1, 9.6, 14)
    elif kind == 2:  # square jaw
        outline = ellipse(0, -3, 10.8, 11, n=20, a0=math.pi, a1=2 * math.pi) + [(10.8, 6), (7.5, 12), (-7.5, 12), (-10.8, 6)]
    else:  # heart: wide brow, pointed chin
        top = ellipse(0, -3, 11.4, 10.5, n=20, a0=math.pi, a1=2 * math.pi)
        outline = top + [(11.4, -2), (6, 9), (0, 13.2), (-6, 9), (-11.4, -2)]
    shapes.append(poly("skin", outline))
    # shading: under the chin and along the left side
    shapes.append(poly("skin_shade", [(-6, 8.5), (6, 8.5), (3, 11.4), (-3, 11.4)]))
    shapes.append(line("skin_shade", (-9.5, -4), (-7.5, 7.5), 1.2))
    return doc("head", [part("head", shapes)])


# ---------------------------------------------------------------- hair
def cap(rx=11.3, ry=13.5, cy=-1.2, depth=0.35, n=22):
    """The top of the head from ear to ear, as a filled polygon."""
    a0 = math.pi + depth
    a1 = 2 * math.pi - depth
    return ellipse(0, cy, rx, ry, n=n, a0=a0, a1=a1)


def hair(kind):
    back, front = [], []
    if kind == 0:  # bald: a faint stubble arc
        front.append(poly("hair_shade", cap(rx=10.9, ry=13.1, depth=0.9) + [(8.5, -9), (-8.5, -9)]))
    elif kind == 1:  # buzz cut
        front.append(poly("hair", cap(depth=0.55) + [(9.8, -5.5), (-9.8, -5.5)]))
    elif kind == 2:  # side part with a swoop
        front.append(poly("hair", cap(depth=0.3) + [(11.2, -5), (8, -7.5), (2, -8.4), (-5, -7.2), (-9, -7.8), (-11.2, -5)]))
        front.append(poly("hair_shade", [(-4, -9.5), (3, -10.6), (6, -8), (-1, -7.6)]))
    elif kind == 3:  # long straight
        back.append(poly("hair", [(-12, -6), (12, -6), (13, 14), (-13, 14)]))
        front.append(poly("hair", cap(depth=0.3) + [(11.5, -5), (9, -8), (0, -9.4), (-9, -8), (-11.5, -5)]))
        front.append(poly("hair", [(-12, -6), (-8.5, -6), (-9.5, 12), (-13, 12)]))
        front.append(poly("hair", [(8.5, -6), (12, -6), (13, 12), (9.5, 12)]))
    elif kind == 4:  # curls
        for i in range(9):
            a = math.pi + (i + 0.5) * math.pi / 9
            back.append(circle("hair", (math.cos(a) * 12.5, -1 + math.sin(a) * 13.5), 3.6))
        for i in range(6):
            a = math.pi + (i + 0.5) * math.pi / 6
            front.append(circle("hair", (math.cos(a) * 10.4, -1.5 + math.sin(a) * 12.4), 3.2))
        front.append(circle("hair_shade", (-3, -11), 1.6))
        front.append(circle("hair_shade", (4, -10.4), 1.4))
    elif kind == 5:  # bun
        back.append(circle("hair", (0, -14.5), 4.2))
        back.append(circle("hair_shade", (1, -15.2), 1.6))
        front.append(poly("hair", cap(depth=0.5) + [(10.2, -6), (-10.2, -6)]))
        front.append(line("hair_shade", (-7, -8.5), (7, -8.5), 0.7))
    elif kind == 6:  # crest
        spikes = [(-6, -10)]
        for i in range(5):
            x = -5 + i * 2.5
            spikes += [(x, -16.5 - (i % 2) * 1.5), (x + 1.25, -11)]
        spikes += [(6, -10)]
        front.append(poly("hair", spikes))
        front.append(poly("hair_shade", cap(rx=10.6, ry=12.8, depth=0.95) + [(7.5, -8.5), (-7.5, -8.5)]))
    else:  # wavy to the shoulders
        wave = []
        for i in range(11):
            x = -13 + i * 2.6
            wave.append((x, 13 + (1.5 if i % 2 else -1.5)))
        back.append(poly("hair", [(-12.5, -6), (12.5, -6)] + wave[::-1]))
        front.append(poly("hair", cap(depth=0.3) + [(11.5, -5), (7, -9), (-2, -8.2), (-8, -9.2), (-11.5, -5)]))
        front.append(poly("hair", [(-12.5, -6), (-9, -6), (-9.6, 4), (-11.5, 9), (-13.5, 8)]))
        front.append(poly("hair", [(9, -6), (12.5, -6), (13.5, 8), (11.5, 9), (9.6, 4)]))
    parts = [part("back", back or [circle("hair", (0, -40), 0.01)]), part("front", front or [circle("hair", (0, -40), 0.01)])]
    states = [{"name": "back", "parts": [{"part": "back"}]}, {"name": "front", "parts": [{"part": "front"}]}]
    return doc("hair", parts, states)


# ---------------------------------------------------------------- eyes, brows
def eyes(kind):
    shapes = []
    for sx in (-1, 1):
        cx = sx * 4.6
        if kind == 0:  # almond
            shapes.append(poly("sclera", [(cx - 2.6, -3), (cx - 1.2, -4.3), (cx + 1.2, -4.3), (cx + 2.6, -3), (cx + 1.2, -1.8), (cx - 1.2, -1.8)]))
            iris = 1.15
        elif kind == 1:  # round
            shapes.append(circle("sclera", (cx, -3), 2.1))
            iris = 1.3
        elif kind == 2:  # narrow
            shapes.append(poly("sclera", [(cx - 2.8, -3), (cx - 1, -3.9), (cx + 1.3, -3.9), (cx + 2.8, -2.8), (cx + 1, -2.2), (cx - 1.2, -2.2)]))
            iris = 0.95
        else:  # wide
            shapes.append(ellipse_shape("sclera", cx, -3, 2.5, 2.1))
            iris = 1.35
        shapes.append(circle("eye", (cx + 0.2, -3), iris))
        shapes.append(circle("line", (cx + 0.2, -3), iris * 0.5))
        shapes.append(circle("teeth", (cx - 0.25, -3.5), iris * 0.28))
        # lash line
        shapes.append(line("line", (cx - 2.4, -3.9 if kind != 1 else -4.6), (cx + 2.4, -3.9 if kind != 1 else -4.6), 0.55))
    return doc("eyes", [part("eyes", shapes)])


def ellipse_shape(color, cx, cy, rx, ry):
    return poly(color, ellipse(cx, cy, rx, ry, n=20))


def brows(kind):
    shapes = []
    for sx in (-1, 1):
        cx = sx * 4.6
        if kind == 0:  # straight, heavy
            shapes.append(line("hair", (cx - 2.8, -7), (cx + 2.8, -7), 1.3))
        elif kind == 1:  # arched
            shapes.append(line("hair", (cx - 2.8, -6.4), (cx, -7.8), 1.0))
            shapes.append(line("hair", (cx, -7.8), (cx + 2.8, -6.6), 1.0))
        elif kind == 2:  # angled inward (stern)
            shapes.append(line("hair", (cx - sx * 2.8, -7.6), (cx + sx * 2.6, -6.2), 1.2))
        elif kind == 3:  # thin, raised (worried)
            shapes.append(line("hair", (cx - 2.6, -8.2), (cx + 2.6, -8.6), 0.7))
        else:  # one raised: sly
            y = -8.6 if sx == 1 else -7
            shapes.append(line("hair", (cx - 2.6, y + 0.4), (cx + 2.6, y - 0.4 * sx), 1.0))
    return doc("brows", [part("brows", shapes)])


# ---------------------------------------------------------------- nose, mouth
def nose(kind):
    if kind == 0:  # button
        shapes = [circle("skin_shade", (0.6, 1.6), 1.3), line("skin_shade", (-0.6, -1.5), (-1.2, 1.4), 0.6)]
    elif kind == 1:  # straight bridge
        shapes = [line("skin_shade", (-0.5, -2.2), (-1.3, 1.8), 0.75), line("skin_shade", (-1.3, 1.8), (1.4, 2.2), 0.75)]
    elif kind == 2:  # broad
        shapes = [poly("skin_shade", [(-0.6, -1.5), (0.6, -1.5), (2.4, 2.4), (0, 3), (-2.4, 2.4)])]
    else:  # hooked
        shapes = [poly("skin_shade", [(-0.4, -2.4), (1.0, -1.0), (1.8, 1.8), (0.2, 2.6), (-1.4, 1.8)])]
    return doc("nose", [part("nose", shapes)])


def mouth(kind):
    if kind == 0:  # neutral
        shapes = [line("mouth", (-2.8, 6), (2.8, 6), 0.9)]
    elif kind == 1:  # smile
        shapes = [line("mouth", (-3.2, 5.4), (0, 6.6), 1.0), line("mouth", (0, 6.6), (3.2, 5.4), 1.0)]
    elif kind == 2:  # frown
        shapes = [line("mouth", (-3, 6.8), (0, 5.6), 1.0), line("mouth", (0, 5.6), (3, 6.8), 1.0)]
    elif kind == 3:  # grin with teeth
        shapes = [poly("mouth", [(-3.8, 5.2), (3.8, 5.2), (2.4, 7.6), (-2.4, 7.6)]), poly("teeth", [(-3, 5.6), (3, 5.6), (2.2, 6.6), (-2.2, 6.6)])]
    else:  # pursed
        shapes = [line("mouth", (-1.6, 6), (1.6, 6), 1.3), circle("skin_shade", (0, 6), 0.5)]
    return doc("mouth", [part("mouth", shapes)])


# ---------------------------------------------------------------- facial hair, collars, extras
def beard(kind):
    shapes = []
    if kind == 0:
        shapes.append(circle("hair", (0, -40), 0.01))
    elif kind == 1:  # stubble
        import random
        r = random.Random(3)
        for _ in range(70):
            x = r.uniform(-8, 8)
            y = r.uniform(3, 11.5)
            if (x / 8.5) ** 2 + ((y - 4) / 8) ** 2 < 1 and not (abs(x) < 3.2 and 4.8 < y < 7.4):
                shapes.append(circle("hair_shade", (x, y), 0.35))
    elif kind == 2:  # full beard
        shapes.append(poly("hair", [(-9.5, 1), (-8, 10), (-4, 14), (4, 14), (8, 10), (9.5, 1), (7, 4), (0, 3), (-7, 4)]))
        shapes.append(poly("skin", [(-3.4, 4.8), (3.4, 4.8), (2.6, 7.6), (-2.6, 7.6)]))
    elif kind == 3:  # goatee
        shapes.append(poly("hair", [(-2.6, 7.2), (2.6, 7.2), (2, 11.8), (-2, 11.8)]))
        shapes.append(line("hair", (-3, 4.6), (3, 4.6), 0.9))
    else:  # moustache
        shapes.append(line("hair", (-4.2, 4.4), (-0.4, 4.8), 1.2))
        shapes.append(line("hair", (0.4, 4.8), (4.2, 4.4), 1.2))
    return doc("beard", [part("beard", shapes)])


def collar(kind):
    shapes = []
    if kind == 0:  # flight suit, high collar with a stripe
        shapes.append(poly("cloth", [(-16, 16), (16, 16), (16, 22), (-16, 22)]))
        shapes.append(poly("cloth", [(-9, 12), (-4.5, 14.5), (4.5, 14.5), (9, 12), (12, 16), (-12, 16)]))
        shapes.append(line("accent", (-9, 12.6), (-4.5, 15), 0.8))
        shapes.append(line("accent", (4.5, 15), (9, 12.6), 0.8))
    elif kind == 1:  # jacket with lapels over a shirt
        shapes.append(poly("cloth2", [(-16, 16), (16, 16), (16, 22), (-16, 22)]))
        shapes.append(poly("cloth", [(-16, 15), (-5, 13), (-1, 19), (-4, 22), (-16, 22)]))
        shapes.append(poly("cloth", [(16, 15), (5, 13), (1, 19), (4, 22), (16, 22)]))
        shapes.append(line("accent", (0, 15), (0, 22), 0.6))
    elif kind == 2:  # uniform with an insignia
        shapes.append(poly("cloth", [(-16, 16), (16, 16), (16, 22), (-16, 22)]))
        shapes.append(poly("cloth", [(-8, 12), (8, 12), (12, 16), (-12, 16)]))
        shapes.append(line("accent", (-16, 16.8), (16, 16.8), 0.5))
        shapes.append(circle("accent", (9, 19), 1.2))
        shapes.append(circle("accent", (12, 19), 1.2))
    else:  # hood
        shapes.append(poly("cloth", [(-16, 16), (16, 16), (16, 22), (-16, 22)]))
        shapes.append(poly("cloth", [(-13.5, 4), (-11, 14), (-5, 15.5), (5, 15.5), (11, 14), (13.5, 4), (15, 16), (-15, 16)]))
        shapes.append(line("cloth2", (-4.5, 15.5), (4.5, 15.5), 0.8))
    return doc("collar", [part("collar", shapes)])


def extra(kind):
    shapes = []
    if kind == 0:
        shapes.append(circle("accent", (0, -40), 0.01))
    elif kind == 1:  # glasses
        for sx in (-1, 1):
            shapes.append(circle("line", (sx * 4.6, -3), 3.0))
            shapes.append(circle("sclera", (sx * 4.6, -3), 2.4))
            shapes.append(circle("eye", (sx * 4.8, -3), 1.2))
            shapes.append(circle("line", (sx * 4.8, -3), 0.6))
        shapes.append(line("line", (-1.6, -3), (1.6, -3), 0.5))
        shapes.append(line("line", (7.6, -3.2), (10.5, -3.6), 0.5))
        shapes.append(line("line", (-7.6, -3.2), (-10.5, -3.6), 0.5))
    elif kind == 2:  # visor
        shapes.append(poly("cloth2", [(-11, -6.5), (11, -6.5), (10, -0.5), (-10, -0.5)]))
        shapes.append(line("accent", (-9, -5.5), (9, -5.5), 0.6))
        shapes.append(line("sclera", (-8, -2.5), (-2, -1.8), 0.6))
    elif kind == 3:  # scar
        shapes.append(line("skin_shade", (5, -8), (7.5, 1), 0.7))
        for i in range(3):
            y = -6 + i * 3
            shapes.append(line("skin_shade", (5 + 0.7 * i - 1, y), (5 + 0.7 * i + 1.2, y + 0.3), 0.45))
    elif kind == 4:  # earring
        shapes.append(circle("accent", (11.4, 1.6), 0.7))
        shapes.append(circle("accent", (-11.4, 1.6), 0.7))
    elif kind == 5:  # headband
        shapes.append(poly("accent", [(-11, -8.4), (11, -8.4), (11, -6.4), (-11, -6.4)]))
    else:  # eyepatch
        shapes.append(poly("line", [(-7.4, -5.6), (-1.8, -5.6), (-2.4, -0.4), (-6.8, -0.4)]))
        shapes.append(line("line", (-7.4, -5.6), (-10.8, -8.5), 0.5))
        shapes.append(line("line", (-1.8, -5.6), (10.8, -9.5), 0.5))
    return doc("extra", [part("extra", shapes)])


COUNTS = {"head": 4, "hair": 8, "eyes": 4, "brows": 5, "nose": 4, "mouth": 5, "beard": 5, "collar": 4, "extra": 7}


def main():
    os.makedirs(OUT, exist_ok=True)
    makers = {"head": head, "hair": hair, "eyes": eyes, "brows": brows, "nose": nose, "mouth": mouth, "beard": beard, "collar": collar, "extra": extra}
    n = 0
    for name, count in COUNTS.items():
        for k in range(count):
            write(f"{name}_{k}", makers[name](k))
            n += 1
    with open(os.path.join(OUT, "..", "palettes", "avatar.fart"), "w") as f:
        json.dump({
            "version": 1, "name": "avatar",
            "palette": [
                {"name": "skin", "rgb": [224, 180, 150, 255]},
                {"name": "skin_shade", "rgb": [178, 132, 108, 255]},
                {"name": "hair", "rgb": [70, 48, 36, 255]},
                {"name": "hair_shade", "rgb": [46, 30, 22, 255]},
                {"name": "eye", "rgb": [80, 110, 60, 255]},
                {"name": "sclera", "rgb": [240, 238, 232, 255]},
                {"name": "cloth", "rgb": [70, 82, 110, 255]},
                {"name": "cloth2", "rgb": [40, 46, 62, 255]},
                {"name": "accent", "rgb": [232, 122, 58, 255]},
                {"name": "line", "rgb": [28, 22, 24, 255]},
                {"name": "mouth", "rgb": [150, 70, 70, 255]},
                {"name": "teeth", "rgb": [245, 242, 236, 255]},
            ]}, f, indent=1)
    print(f"wrote {n} avatar documents + palettes/avatar.fart")


if __name__ == "__main__":
    main()
