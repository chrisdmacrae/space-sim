package render

// NPC avatars: a face composed from one fastart document per feature,
// recoloured through the avatar palette tokens. `avatar_make` rolls the
// look from a person's seed; `avatar_draw` layers the documents (facial
// hair goes under the mouth so a beard never swallows the expression).
// tools/preview_avatars.py rasterises the same layering without a window.

import "core:fmt"
import rl "vendor:raylib"
import art "sim:art"
import core "sim:core"

Avatar :: struct {
	head, hair, eyes, brows, nose, mouth, beard, collar, extra: u8,
	skin, skin_shade, hair_col, hair_shade, eye, cloth, cloth2, accent: [4]u8,
}

// Variants per feature; must match tools/gen_avatars.py.
AVATAR_COUNTS :: struct { head, hair, eyes, brows, nose, mouth, beard, collar, extra: int }{4, 8, 4, 5, 4, 5, 5, 4, 7}

SKIN_TONES :: [?][4]u8 {
	{246, 220, 200, 255}, {232, 198, 172, 255}, {224, 180, 150, 255}, {205, 160, 125, 255},
	{182, 132, 96, 255}, {150, 104, 72, 255}, {118, 78, 52, 255}, {88, 58, 40, 255},
}
HAIR_TONES :: [?][4]u8 {
	{28, 24, 26, 255}, {58, 40, 30, 255}, {92, 60, 40, 255}, {140, 76, 40, 255}, {196, 150, 80, 255},
	{225, 200, 140, 255}, {150, 150, 155, 255}, {235, 235, 235, 255},
}
HAIR_ODD :: [?][4]u8{{70, 150, 200, 255}, {60, 170, 150, 255}, {200, 80, 150, 255}, {160, 60, 60, 255}}
EYE_TONES :: [?][4]u8{{78, 50, 36, 255}, {110, 88, 50, 255}, {70, 110, 60, 255}, {70, 110, 170, 255}, {120, 130, 140, 255}}
ACCENTS :: [?][4]u8{{232, 122, 58, 255}, {122, 204, 240, 255}, {220, 180, 70, 255}, {120, 220, 140, 255}, {220, 140, 220, 255}, {230, 230, 230, 255}}

@(private = "file")
darken :: proc(c: [4]u8, f: f32) -> [4]u8 {
	return {u8(f32(c[0]) * f), u8(f32(c[1]) * f), u8(f32(c[2]) * f), c[3]}
}

@(private = "file")
pick :: proc(r: ^core.Rng, n: int) -> u8 { return u8(core.rng_int(r, 0, n)) }

avatar_make :: proc(seed: u64) -> (av: Avatar) {
	r := core.rng_make(core.sub_seed(seed, "avatar"))
	c := AVATAR_COUNTS
	av.head = pick(&r, c.head)
	av.hair = pick(&r, c.hair)
	av.eyes = pick(&r, c.eyes)
	av.brows = pick(&r, c.brows)
	av.nose = pick(&r, c.nose)
	av.mouth = pick(&r, c.mouth)
	av.beard = core.rng_chance(&r, 0.4) ? u8(core.rng_int(&r, 1, c.beard)) : 0
	av.collar = pick(&r, c.collar)
	av.extra = core.rng_chance(&r, 0.4) ? u8(core.rng_int(&r, 1, c.extra)) : 0
	skins := SKIN_TONES
	av.skin = skins[core.rng_int(&r, 0, len(skins))]
	av.skin_shade = darken(av.skin, 0.78)
	if core.rng_chance(&r, 0.1) {
		odd := HAIR_ODD
		av.hair_col = odd[core.rng_int(&r, 0, len(odd))]
	} else {
		hairs := HAIR_TONES
		av.hair_col = hairs[core.rng_int(&r, 0, len(hairs))]
	}
	av.hair_shade = darken(av.hair_col, 0.7)
	eyes := EYE_TONES
	av.eye = eyes[core.rng_int(&r, 0, len(eyes))]
	// Clothes: a muted hue, its darker partner, and a bright accent.
	hue := f32(core.rng_range(&r, 0, 360))
	av.cloth = hsv(hue, f32(core.rng_range(&r, 0.25, 0.5)), f32(core.rng_range(&r, 0.3, 0.55)))
	av.cloth2 = darken(av.cloth, 0.6)
	accents := ACCENTS
	av.accent = accents[core.rng_int(&r, 0, len(accents))]
	return
}

@(private = "file")
hsv :: proc(h, s, v: f32) -> [4]u8 {
	c := rl.ColorFromHSV(h, s, v)
	return {c.r, c.g, c.b, 255}
}

// Register the feature documents with the library.
avatar_load :: proc(lib: ^art.Library) {
	c := AVATAR_COUNTS
	names := [?]string{"head", "hair", "eyes", "brows", "nose", "mouth", "beard", "collar", "extra"}
	counts := [?]int{c.head, c.hair, c.eyes, c.brows, c.nose, c.mouth, c.beard, c.collar, c.extra}
	for name, i in names {
		for k in 0 ..< counts[i] {
			doc := fmt.aprintf("av_%s_%d", name, k)
			art.library_load(lib, doc, fmt.tprintf("avatars/%s_%d.fart", name, k))
		}
	}
}

// Draw the face centred on `origin`, `px` screen pixels per document unit
// (the face spans about 32 units). Draws a rounded backdrop first.
avatar_draw :: proc(lib: ^art.Library, av: Avatar, origin: [2]f32, px: f32) {
	half := px * 17
	rl.DrawRectangleRounded({origin.x - half, origin.y - half, half * 2, half * 2}, 0.15, 4, {24, 30, 44, 255})
	rl.BeginScissorMode(i32(origin.x - half), i32(origin.y - half), i32(half * 2), i32(half * 2))
	ov := [?]art.Override {
		{"skin", av.skin}, {"skin_shade", av.skin_shade}, {"hair", av.hair_col}, {"hair_shade", av.hair_shade},
		{"eye", av.eye}, {"cloth", av.cloth}, {"cloth2", av.cloth2}, {"accent", av.accent},
	}
	xf := art.Xform{origin = origin, px = px}
	layer :: proc(lib: ^art.Library, name: string, k: u8, state: string, xf: art.Xform, ov: []art.Override) {
		if doc := art.library_get(lib, fmt.tprintf("av_%s_%d", name, k)); doc != nil do art.draw_doc(doc, state, xf, ov)
	}
	layer(lib, "hair", av.hair, "back", xf, ov[:])
	layer(lib, "head", av.head, "idle", xf, ov[:])
	layer(lib, "collar", av.collar, "idle", xf, ov[:])
	layer(lib, "eyes", av.eyes, "idle", xf, ov[:])
	layer(lib, "brows", av.brows, "idle", xf, ov[:])
	layer(lib, "nose", av.nose, "idle", xf, ov[:])
	layer(lib, "beard", av.beard, "idle", xf, ov[:])
	layer(lib, "mouth", av.mouth, "idle", xf, ov[:])
	layer(lib, "hair", av.hair, "front", xf, ov[:])
	layer(lib, "extra", av.extra, "idle", xf, ov[:])
	rl.EndScissorMode()
}
