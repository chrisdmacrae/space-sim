#!/usr/bin/env python3
"""Generate detailed planet documents (.fart) per body kind, several variants each.

All shapes stay inside the unit disc. Tokens: surface, surface2, feature,
feature2, accent, highlight. The game recolours them per planet.
Run: python3 tools/gen_planets.py
"""
import json, math, random

R = 0.985  # keep everything inside the disc

def clip(p):
    x, y = p
    d = math.hypot(x, y)
    if d > R:
        x, y = x / d * R, y / d * R
    return [round(x, 4), round(y, 4)]

def blob(rng, cx, cy, r, n=12, jitter=0.35, stretch=1.0):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        rr = r * (1 + rng.uniform(-jitter, jitter))
        pts.append(clip((cx + math.cos(a) * rr * stretch, cy + math.sin(a) * rr)))
    return pts

def chord(y):
    return math.sqrt(max(R * R - y * y, 0))

def band(rng, y0, y1, wave=0.03, n=14):
    """Horizontal band between y0 and y1 with wavy edges, inside the disc."""
    top, bot = [], []
    for i in range(n + 1):
        t = i / n
        # x spans the chord at each edge's own y
        yt = y0 + rng.uniform(-wave, wave) * math.sin(t * 6.28 * 2 + rng.random())
        yb = y1 + rng.uniform(-wave, wave) * math.sin(t * 6.28 * 2 + rng.random())
        yt = max(-R, min(R, yt)); yb = max(-R, min(R, yb))
        xt = -chord(yt) + 2 * chord(yt) * t
        xb = -chord(yb) + 2 * chord(yb) * t
        top.append([round(xt, 4), round(yt, 4)])
        bot.append([round(xb, 4), round(yb, 4)])
    return top + bot[::-1]

def cap(y, north=True, n=10):
    """Polar cap: the circle segment beyond the chord at y (screen y is down)."""
    alpha = math.asin(max(-1, min(1, abs(y) / R)))
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (math.pi + alpha) + (math.pi - 2 * alpha) * t if north else alpha + (math.pi - 2 * alpha) * t
        pts.append([round(R * math.cos(a), 4), round(R * math.sin(a), 4)])
    return pts

def circle(color, at, r):
    return {"kind": "circle", "color": color, "at": clip(at), "r": round(r, 4)}

def line(color, a, b, w):
    return {"kind": "line", "color": color, "a": clip(a), "b": clip(b), "w": round(w, 4)}

def _cross(o, a, b):
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

def earclip(pts):
    """Ear clipping for simple polygons; returns index triples. Falls back to a fan."""
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
            # Degenerate remainder: fan it rather than leave holes.
            for i in range(1, len(idx) - 1):
                out += [idx[0], idx[i], idx[i + 1]]
            idx = []
            break
    if len(idx) == 3:
        out += idx
    return out

def dedupe(pts):
    out = []
    for p in pts:
        if not out or abs(out[-1][0] - p[0]) > 1e-6 or abs(out[-1][1] - p[1]) > 1e-6:
            out.append(p)
    if len(out) > 1 and abs(out[0][0] - out[-1][0]) < 1e-6 and abs(out[0][1] - out[-1][1]) < 1e-6:
        out.pop()
    return out

def poly(color, pts):
    pts = dedupe(pts)
    return {"kind": "poly", "color": color, "points": pts, "tris": earclip(pts)}

def crater(rng, shapes, cx, cy, r):
    shapes.append(circle("highlight", (cx - r * 0.1, cy - r * 0.1), r * 1.08))
    shapes.append(circle("feature", (cx, cy), r))
    shapes.append(circle("surface2", (cx + r * 0.25, cy + r * 0.2), r * 0.55))

def walk(rng, shapes, color, start, steps, step, w, color2=None):
    x, y = start
    a = rng.uniform(0, 6.28)
    for _ in range(steps):
        a += rng.uniform(-0.9, 0.9)
        nx, ny = x + math.cos(a) * step, y + math.sin(a) * step
        if math.hypot(nx, ny) > R * 0.95:
            a += math.pi
            nx, ny = x + math.cos(a) * step, y + math.sin(a) * step
        if color2:
            shapes.append(line(color2, (x, y), (nx, ny), w * 2.4))
        shapes.append(line(color, (x, y), (nx, ny), w))
        x, y = nx, ny

def rock(rng):
    s = [circle("surface", (0, 0), 1.0)]
    for _ in range(rng.randint(2, 4)):  # maria / plains
        s.append(poly("surface2", blob(rng, rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), rng.uniform(0.25, 0.45), 12, 0.4)))
    for _ in range(rng.randint(3, 5)):  # highland patches
        s.append(poly("feature2", blob(rng, rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), rng.uniform(0.12, 0.28), 9, 0.35)))
    for _ in range(rng.randint(6, 10)):
        crater(rng, s, rng.uniform(-0.7, 0.7), rng.uniform(-0.7, 0.7), rng.uniform(0.05, 0.16))
    for _ in range(rng.randint(1, 3)):
        walk(rng, s, "feature", (rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4)), 6, 0.12, 0.02)
    return s

def moon(rng):
    s = [circle("surface", (0, 0), 1.0)]
    for _ in range(rng.randint(1, 3)):
        s.append(poly("surface2", blob(rng, rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(0.3, 0.5), 12, 0.35)))
    for _ in range(rng.randint(8, 14)):
        crater(rng, s, rng.uniform(-0.75, 0.75), rng.uniform(-0.75, 0.75), rng.uniform(0.04, 0.18))
    return s

def atmospheric(rng):
    s = [circle("surface", (0, 0), 1.0)]
    for _ in range(rng.randint(2, 4)):  # continents with shelves
        cx, cy, r = rng.uniform(-0.55, 0.55), rng.uniform(-0.55, 0.55), rng.uniform(0.3, 0.5)
        s.append(poly("feature2", blob(rng, cx, cy, r * 1.15, 14, 0.4)))  # shallow shelf
        s.append(poly("feature", blob(rng, cx, cy, r, 14, 0.45)))
        for _ in range(rng.randint(1, 3)):  # mountains / deserts
            s.append(poly("surface2", blob(rng, cx + rng.uniform(-r, r) * 0.5, cy + rng.uniform(-r, r) * 0.5, r * 0.35, 8, 0.4)))
    for _ in range(rng.randint(3, 7)):  # islands
        s.append(poly("feature", blob(rng, rng.uniform(-0.8, 0.8), rng.uniform(-0.8, 0.8), rng.uniform(0.04, 0.1), 7, 0.4)))
    s.append(poly("highlight", cap(-rng.uniform(0.62, 0.8), True)))
    s.append(poly("highlight", cap(rng.uniform(0.62, 0.8), False)))
    for _ in range(rng.randint(4, 7)):  # cloud streaks
        y = rng.uniform(-0.7, 0.7)
        x0 = rng.uniform(-0.8, 0.2)
        length = rng.uniform(0.3, 0.8)
        s.append(line("accent", (x0, y), (x0 + length, y + rng.uniform(-0.12, 0.12)), rng.uniform(0.05, 0.12)))
    for _ in range(rng.randint(1, 2)):  # cyclones
        cx, cy = rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6)
        a = rng.uniform(0, 6.28)
        x, y = cx, cy
        for k in range(10):
            a += 0.75
            rr = 0.02 + k * 0.02
            nx, ny = cx + math.cos(a) * rr, cy + math.sin(a) * rr
            s.append(line("accent", (x, y), (nx, ny), 0.05 - k * 0.002))
            x, y = nx, ny
    return s

def gas(rng):
    s = [circle("surface", (0, 0), 1.0)]
    y = -R
    toks = ["surface2", "feature", "feature2", "accent", "surface"]
    k = 0
    while y < R - 0.05:
        h = rng.uniform(0.06, 0.22)
        tok = toks[k % len(toks)] if rng.random() < 0.8 else rng.choice(toks)
        s.append(poly(tok, band(rng, y, min(y + h, R), wave=0.02 + h * 0.15)))
        # thin turbulent streak inside the band
        if rng.random() < 0.6:
            yy = y + h * rng.uniform(0.2, 0.8)
            s.append(line("highlight", (-chord(yy) * 0.9, yy), (chord(yy) * rng.uniform(0.1, 0.9), yy + rng.uniform(-0.01, 0.01)), 0.012))
        y += h
        k += 1
    # great spot
    cx, cy = rng.uniform(-0.4, 0.4), rng.uniform(-0.5, 0.5)
    s.append(poly("feature2", blob(rng, cx, cy, 0.14, 12, 0.15, stretch=1.8)))
    s.append(poly("highlight", blob(rng, cx, cy, 0.08, 10, 0.15, stretch=1.8)))
    return s

def ice(rng):
    s = [circle("surface", (0, 0), 1.0)]
    for _ in range(rng.randint(2, 4)):
        s.append(poly("surface2", blob(rng, rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), rng.uniform(0.25, 0.45), 11, 0.4)))
    for _ in range(rng.randint(4, 7)):  # chaos terrain
        s.append(poly("feature2", blob(rng, rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), rng.uniform(0.08, 0.2), 8, 0.5)))
    for _ in range(rng.randint(4, 7)):  # long cracks
        walk(rng, s, "feature", (rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5)), 9, 0.14, 0.018)
    for _ in range(rng.randint(2, 4)):
        crater(rng, s, rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), rng.uniform(0.05, 0.1))
    s.append(poly("highlight", cap(-rng.uniform(0.5, 0.7), True)))
    return s

def molten(rng):
    s = [circle("surface", (0, 0), 1.0)]
    for _ in range(rng.randint(4, 7)):  # crust plates
        s.append(poly("surface2", blob(rng, rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), rng.uniform(0.18, 0.4), 10, 0.45)))
    for _ in range(rng.randint(4, 7)):  # glowing cracks with a dim halo
        walk(rng, s, "feature", (rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6)), 8, 0.13, 0.025, color2="feature2")
    for _ in range(rng.randint(2, 4)):  # lava lakes
        cx, cy, r = rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), rng.uniform(0.06, 0.16)
        s.append(poly("feature2", blob(rng, cx, cy, r * 1.3, 9, 0.3)))
        s.append(poly("feature", blob(rng, cx, cy, r, 9, 0.3)))
        s.append(circle("highlight", (cx, cy), r * 0.35))
    for _ in range(rng.randint(2, 5)):  # volcanic cones
        cx, cy = rng.uniform(-0.7, 0.7), rng.uniform(-0.7, 0.7)
        s.append(circle("accent", (cx, cy), 0.06))
        s.append(circle("highlight", (cx, cy), 0.02))
    return s

PALETTES = {
    "rock":        [[152,132,108],[126,108,88],[112,96,78],[168,150,124],[90,78,64],[190,176,156]],
    "moon":        [[150,150,156],[128,128,134],[104,104,112],[140,140,146],[118,118,126],[186,186,192]],
    "atmospheric": [[36,88,170],[150,140,90],[72,142,68],[54,110,150],[255,255,255],[240,246,255]],
    "gas":         [[204,172,122],[178,146,102],[160,122,82],[214,190,150],[232,214,176],[246,236,214]],
    "ice":         [[204,222,236],[186,206,224],[146,178,208],[214,230,240],[255,255,255],[236,244,250]],
    "molten":      [[70,42,38],[54,32,30],[255,120,30],[190,60,20],[120,40,30],[255,230,150]],
}
ALPHA = {"accent": {"atmospheric": 150, "gas": 200}, "highlight": {"atmospheric": 230, "ice": 200, "gas": 120, "rock": 90, "moon": 90}}

GEN = {"rock": (rock, 3), "moon": (moon, 2), "atmospheric": (atmospheric, 3), "gas": (gas, 3), "ice": (ice, 2), "molten": (molten, 2)}
TOKENS = ["surface", "surface2", "feature", "feature2", "accent", "highlight"]

for kind, (fn, n) in GEN.items():
    for v in range(n):
        rng = random.Random(f"{kind}-{v}")
        shapes = fn(rng)
        pal = []
        for tok, rgb in zip(TOKENS, PALETTES[kind]):
            a = ALPHA.get(tok, {}).get(kind, 255)
            pal.append({"name": tok, "rgb": [*rgb, a]})
        doc = {"version": 1, "name": f"{kind}_{v}", "palette": pal,
               "parts": [{"name": "globe", "pivot": [0, 0], "shapes": shapes}], "states": []}
        with open(f"assets/bodies/{kind}_{v}.fart", "w") as f:
            json.dump(doc, f, separators=(",", ":"))
        print(kind, v, len(shapes), "shapes")
