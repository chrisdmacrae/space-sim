#!/usr/bin/env python3
"""Rasterise a sheet of NPC faces from the avatar documents without the
game (handy when no window can open). Mirrors render/avatar.odin: same
layer order, same token overrides. Pure stdlib; writes a PNG.

    python3 tools/preview_avatars.py out.png [seed] [count]
"""
import json, math, os, random, struct, sys, zlib

ROOT = os.path.join(os.path.dirname(__file__), "..")
AV = os.path.join(ROOT, "assets", "avatars")
LAYERS = [("hair", "back"), ("head", "idle"), ("collar", "idle"), ("eyes", "idle"), ("brows", "idle"),
          ("nose", "idle"), ("beard", "idle"), ("mouth", "idle"), ("hair", "front"), ("extra", "idle")]
COUNTS = {"head": 4, "hair": 8, "eyes": 4, "brows": 5, "nose": 4, "mouth": 5, "beard": 5, "collar": 4, "extra": 7}
SKIN = [(246, 220, 200), (232, 198, 172), (224, 180, 150), (205, 160, 125), (182, 132, 96), (150, 104, 72), (118, 78, 52), (88, 58, 40)]
HAIR = [(28, 24, 26), (58, 40, 30), (92, 60, 40), (140, 76, 40), (196, 150, 80), (225, 200, 140), (150, 150, 155), (235, 235, 235)]
EYE = [(78, 50, 36), (110, 88, 50), (70, 110, 60), (70, 110, 170), (120, 130, 140)]
ACC = [(232, 122, 58), (122, 204, 240), (220, 180, 70), (120, 220, 140), (220, 140, 220), (230, 230, 230)]
BASE = {"sclera": (240, 238, 232), "line": (28, 22, 24), "mouth": (150, 70, 70), "teeth": (245, 242, 236)}


def dark(c, f):
    return tuple(int(v * f) for v in c)


class Canvas:
    def __init__(self, w, h, bg=(5, 7, 12)):
        self.w, self.h = w, h
        self.px = [list(bg) for _ in range(w * h)]

    def put(self, x, y, c, a=1.0):
        if 0 <= x < self.w and 0 <= y < self.h:
            p = self.px[y * self.w + x]
            for i in range(3):
                p[i] = int(p[i] * (1 - a) + c[i] * a)

    def circle(self, cx, cy, r, c, a=1.0):
        for y in range(int(cy - r) - 1, int(cy + r) + 2):
            for x in range(int(cx - r) - 1, int(cx + r) + 2):
                d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
                if d <= r:
                    self.put(x, y, c, a)
                elif d < r + 1:
                    self.put(x, y, c, a * (r + 1 - d))

    def tri(self, a, b, cc, c, alpha=1.0):
        xs = [a[0], b[0], cc[0]]
        ys = [a[1], b[1], cc[1]]
        det = (b[0] - a[0]) * (cc[1] - a[1]) - (cc[0] - a[0]) * (b[1] - a[1])
        if abs(det) < 1e-9:
            return
        for y in range(int(min(ys)), int(max(ys)) + 2):
            for x in range(int(min(xs)), int(max(xs)) + 2):
                px, py = x + 0.5, y + 0.5
                l1 = ((b[0] - px) * (cc[1] - py) - (cc[0] - px) * (b[1] - py)) / det
                l2 = ((cc[0] - px) * (a[1] - py) - (a[0] - px) * (cc[1] - py)) / det
                l3 = 1 - l1 - l2
                if l1 >= -1e-6 and l2 >= -1e-6 and l3 >= -1e-6:
                    self.put(x, y, c, alpha)

    def capsule(self, a, b, w, c, alpha=1.0):
        r = w / 2
        for y in range(int(min(a[1], b[1]) - r) - 1, int(max(a[1], b[1]) + r) + 2):
            for x in range(int(min(a[0], b[0]) - r) - 1, int(max(a[0], b[0]) + r) + 2):
                px, py = x + 0.5, y + 0.5
                dx, dy = b[0] - a[0], b[1] - a[1]
                l2 = dx * dx + dy * dy
                t = 0 if l2 == 0 else max(0, min(1, ((px - a[0]) * dx + (py - a[1]) * dy) / l2))
                d = math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy))
                if d <= r:
                    self.put(x, y, c, alpha)
                elif d < r + 1:
                    self.put(x, y, c, alpha * (r + 1 - d))

    def png(self, path):
        raw = b"".join(b"\x00" + bytes(v for p in self.px[y * self.w:(y + 1) * self.w] for v in p) for y in range(self.h))

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        with open(path, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def load(name, k):
    with open(os.path.join(AV, f"{name}_{k}.fart")) as f:
        return json.load(f)


ID = (1, 0, 0, 1, 0, 0)  # a, b, c, d, e, f: x' = ax + cy + e, y' = bx + dy + f


def xf_mul(A, B):
    return (A[0] * B[0] + A[2] * B[1], A[1] * B[0] + A[3] * B[1],
            A[0] * B[2] + A[2] * B[3], A[1] * B[2] + A[3] * B[3],
            A[0] * B[4] + A[2] * B[5] + A[4], A[1] * B[4] + A[3] * B[5] + A[5])


def xf_apply(T, p):
    return (T[0] * p[0] + T[2] * p[1] + T[4], T[1] * p[0] + T[3] * p[1] + T[5])


def local_xf(part, sp):
    """translate(offset) . rotate . scale . mirror . translate(-pivot)"""
    if sp is None:
        return ID
    s = sp.get("scale") or 1
    r = sp.get("rotate", 0)
    m = -1 if sp.get("mirror") else 1
    c, sn = math.cos(r) * s, math.sin(r) * s
    a, b, cc, d = c * m, sn * m, -sn, c
    pv = part["pivot"]
    off = sp.get("offset", pv)
    return (a, b, cc, d, off[0] - (a * pv[0] + cc * pv[1]), off[1] - (b * pv[0] + d * pv[1]))


def world_xf(parts, poses, name):
    part = parts[name]
    sp = next((q for q in poses if q["part"] == name), None)
    L = local_xf(part, sp)
    parent = part.get("parent")
    return xf_mul(world_xf(parts, poses, parent), L) if parent in parts else L


def draw_doc(cv, doc, state, ox, oy, px, colors, poses=None):
    """Draw a state (or a pose list of the same shape) the way the game does:
    each part through its world transform, parents and all."""
    parts = {p["name"]: p for p in doc["parts"]}
    if poses is None:
        poses = next(s for s in doc["states"] if s["name"] == state)["parts"]
    for sp in poses:
        if sp["part"] not in parts:
            continue
        part = parts[sp["part"]]
        T = world_xf(parts, poses, sp["part"])
        unit = px * math.hypot(T[0], T[1])
        def at(p):
            q = xf_apply(T, p)
            return (ox + q[0] * px, oy + q[1] * px)
        for sh in parts.get(part.get("like"), part)["shapes"]:
            col = colors[sh["color"]]
            c, a = col[:3], (col[3] / 255 if len(col) > 3 else 1.0)
            if sh["kind"] == "circle":
                p = at(sh["at"])
                cv.circle(p[0], p[1], sh["r"] * unit, c, a)
            elif sh["kind"] == "line":
                cv.capsule(at(sh["a"]), at(sh["b"]), sh["w"] * unit, c, a)
            else:
                pts = [at(p) for p in sh["points"]]
                tr = sh["tris"]
                for i in range(0, len(tr), 3):
                    cv.tri(pts[tr[i]], pts[tr[i + 1]], pts[tr[i + 2]], c, a)


def face(rng):
    f = {k: rng.randrange(n) for k, n in COUNTS.items()}
    f["beard"] = rng.randrange(1, COUNTS["beard"]) if rng.random() < 0.4 else 0
    f["extra"] = rng.randrange(1, COUNTS["extra"]) if rng.random() < 0.4 else 0
    skin = rng.choice(SKIN)
    hair = rng.choice(HAIR)
    h = rng.random() * 360
    s, v = rng.uniform(0.25, 0.5), rng.uniform(0.3, 0.55)
    i = int(h / 60) % 6
    ff = h / 60 - int(h / 60)
    p, q, t = v * (1 - s), v * (1 - s * ff), v * (1 - s * (1 - ff))
    cloth = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    cloth = tuple(int(x * 255) for x in cloth)
    colors = dict(BASE)
    colors.update({"skin": skin, "skin_shade": dark(skin, 0.78), "hair": hair, "hair_shade": dark(hair, 0.7),
                   "eye": rng.choice(EYE), "cloth": cloth, "cloth2": dark(cloth, 0.6), "accent": rng.choice(ACC)})
    return f, colors


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "avatars_preview.png"
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    rng = random.Random(seed)
    cols = 6
    cell = 132
    px = 3.4
    rows = (count + cols - 1) // cols
    cv = Canvas(cols * cell + 20, rows * cell + 20)
    docs = {}
    for k in range(count):
        f, colors = face(rng)
        ox = 20 + (k % cols) * cell + cell / 2
        oy = 20 + (k // cols) * cell + cell / 2
        half = px * 17
        for y in range(int(oy - half), int(oy + half)):
            for x in range(int(ox - half), int(ox + half)):
                cv.put(x, y, (24, 30, 44))
        for name, state in LAYERS:
            key = (name, f[name])
            if key not in docs:
                docs[key] = load(*key)
            draw_doc(cv, docs[key], state, ox, oy, px, colors)
    cv.png(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
