#!/usr/bin/env python3
"""Rasterise the ship hulls without the game, one row per hull and one column
per pose: at rest, the engine at a trickle and at full, and the attitude jets
that turn each way. These are the states the clips in the document move
between, drawn the way the game draws them (parents, pivots, alpha).

    python3 tools/preview_ships.py out.png
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import preview_avatars as pa

ROOT = os.path.join(os.path.dirname(__file__), "..")
pal = {t["name"]: tuple(t["rgb"]) for t in json.load(open(os.path.join(ROOT, "assets", "palettes", "base.fart")))["palette"]}
names = ["courier", "hauler", "clipper", "freighter", "sleeper"]
poses = ["idle", "min_hi", "burn_hi", "turn_l_hi", "turn_r_hi"]
px = 5
cv = pa.Canvas(320 * len(poses), len(names) * 110 + 30)
for i, n in enumerate(names):
    d = json.load(open(os.path.join(ROOT, "assets", "ships", n + ".fart")))
    for k, state in enumerate(poses):
        # Document space is the screen's (y down): no flip, same as the game.
        pa.draw_doc(cv, d, state, 160 + k * 320, 70 + i * 110, px, pal)
cv.png(sys.argv[1] if len(sys.argv) > 1 else "ships_preview.png")
print("ok")
