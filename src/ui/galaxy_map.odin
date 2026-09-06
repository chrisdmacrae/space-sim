package ui

// Galaxy map: a painted backdrop (field stars, haze, dust and core sampled
// from the galaxy's own shape, rendered once to a texture), then the link
// lattice and the systems as glowing points. Zoom with the wheel, drag to
// pan, hover for names, click to select.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import art "sim:art"
import core "sim:core"
import gen "sim:gen"
import text "sim:text"

Map_State :: struct {
	zoom:     f32,    // 1 = whole galaxy fits
	center:   [2]f32, // light-years
	inited:   bool,
	drag:     bool,
	tex:      rl.RenderTexture2D, // the painted backdrop, built once per galaxy
	tex_seed: u64,
	has_tex:  bool,
}

Map_View :: struct {
	galaxy:     ^gen.Galaxy,
	lib:        ^art.Library,
	current:    int,
	selected:   int,
	cryo_speed: f64,  // ship's cruise fraction of c
	can_jump:   bool, // the ship is already on an escape trajectory
	pending:    bool, // a flight out of the system is under way for this jump
	info:       string, // extra lines for the selected system
	// The economy of the system the card shows, once it has been surveyed.
	surveyed:   bool,
	output:     f64, // goods per day
	wealth:     f64,
	demand:     f64, // pressure, 0..1
	markets:    int,
}

BACKDROP_PX :: 2048

// The info card floats over the map's top-right corner rather than taking a
// column of its own, so the galaxy keeps the whole window.
CARD_W   :: 300 // total width
CARD_PAD :: 14  // inside the border
CARD_M   :: 16  // clear of the map's edge
CARD_ROW :: 20  // one label-and-value line

@(private = "file") HERE_COL :: rl.Color{150, 230, 170, 255} // where the ship is
@(private = "file") SEL_COL  :: rl.Color{255, 220, 120, 255} // what is selected
@(private = "file") WARN_COL :: rl.Color{255, 150, 110, 255}
@(private = "file") CARD_BG  :: rl.Color{10, 13, 21, 228}
@(private = "file") CARD_EDGE :: rl.Color{58, 68, 90, 255}
@(private = "file") RULE_COL :: rl.Color{48, 56, 74, 255}
@(private = "file") CAP_COL  :: rl.Color{112, 124, 148, 255} // section captions

galaxy_map_release :: proc(st: ^Map_State) {
	if st.has_tex do rl.UnloadRenderTexture(st.tex)
	st.has_tex = false
}

// Colour of the field by distance from the centre: warm old stars in the
// bulge, blue young ones out in the arms. Ellipticals are warm throughout.
@(private = "file")
field_tint :: proc(kind: gen.Galaxy_Kind, t: f32) -> rl.Color {
	warm := rl.Color{255, 222, 175, 255}
	blue := rl.Color{150, 185, 255, 255}
	violet := rl.Color{200, 160, 255, 255}
	mix := clamp(t, 0, 1)
	switch kind {
	case .Elliptical: mix = mix * 0.25
	case .Lenticular: mix = mix * 0.6
	case .Irregular:  blue = violet
	case .Spiral:
	}
	lerp :: proc(a, b: u8, t: f32) -> u8 { return u8(f32(a) + (f32(b) - f32(a)) * t) }
	return {lerp(warm.r, blue.r, mix), lerp(warm.g, blue.g, mix), lerp(warm.b, blue.b, mix), 255}
}

// Paint the backdrop: thousands of unresolved field stars along the
// morphology, soft haze, faint dust lanes just inside the arms, and a warm
// core. Everything is additive so overlaps brighten instead of muddying.
@(private = "file")
build_backdrop :: proc(st: ^Map_State, g: ^gen.Galaxy) {
	galaxy_map_release(st)
	st.tex = rl.LoadRenderTexture(BACKDROP_PX, BACKDROP_PX)
	rl.SetTextureFilter(st.tex.texture, .BILINEAR)
	st.tex_seed = g.seed
	st.has_tex = true
	span := g.span
	k := f32(BACKDROP_PX) / f32(span)
	tex :: proc(p: [2]f64, k: f32) -> rl.Vector2 { return {f32(p.x) * k, f32(BACKDROP_PX) - f32(p.y) * k} }
	rr := core.rng_make(g.seed ~ 0xBADC0FFEE)
	cx, cy := span * 0.5, span * 0.5
	R := f32(g.shape.R)
	radial :: proc(p: [2]f64, cx, cy: f64, R: f32) -> f32 {
		dx := f32(p.x - cx)
		dy := f32(p.y - cy)
		return math.sqrt(dx * dx + dy * dy) / R
	}

	rl.BeginTextureMode(st.tex)
	rl.ClearBackground(rl.BLANK)
	// Light accumulates: colour weighted by alpha piles up, and alpha
	// itself sums (plain additive would square the tiny haze alphas away).
	rlgl.SetBlendFactorsSeparate(rlgl.SRC_ALPHA, rlgl.ONE, rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD, rlgl.FUNC_ADD)
	rl.BeginBlendMode(.CUSTOM_SEPARATE)
	// Haze: wide soft blobs, denser and warmer inward.
	for _ in 0 ..< 1400 {
		p := gen.galaxy_sample(g, &rr)
		t := radial(p, cx, cy, R)
		c := field_tint(g.kind, t)
		c.a = u8(6 + 6 * (1 - t))
		rad := k * f32(core.rng_range(&rr, 1.4, 3.6))
		rl.DrawCircleGradient(tex(p, k), rad, c, {c.r, c.g, c.b, 0})
	}
	// Core: a warm glow, larger for the rounder kinds.
	{
		size: f32
		switch g.kind {
		case .Elliptical: size = 0.55
		case .Lenticular: size = 0.30
		case .Spiral:     size = 0.20
		case .Irregular:  size = 0.10
		}
		c := tex({cx, cy}, k)
		rl.DrawCircleGradient(c, R * k * size, {255, 225, 180, 45}, {255, 225, 180, 0})
		rl.DrawCircleGradient(c, R * k * size * 0.45, {255, 240, 215, 60}, {255, 240, 215, 0})
		rl.DrawCircleGradient(c, R * k * size * 0.12, {255, 250, 240, 110}, {255, 250, 240, 0})
	}
	// Field stars: the thing that actually reads as a galaxy.
	for _ in 0 ..< 14000 {
		p := gen.galaxy_sample(g, &rr)
		t := radial(p, cx, cy, R)
		c := field_tint(g.kind, t)
		u := core.rng_f64(&rr)
		q := tex(p, k)
		switch {
		case u < 0.03:
			c.a = 230
			rl.DrawCircleGradient(q, 3.5, c, {c.r, c.g, c.b, 0})
			rl.DrawRectangleV({q.x - 0.5, q.y - 0.5}, {1.5, 1.5}, {255, 255, 255, 220})
		case u < 0.18:
			c.a = u8(120 + core.rng_range(&rr, 0, 100))
			rl.DrawRectangleV({q.x - 0.5, q.y - 0.5}, {1.6, 1.6}, c)
		case:
			c.a = u8(40 + core.rng_range(&rr, 0, 110))
			rl.DrawRectangleV(q, {1, 1}, c)
		}
	}
	// Clusters: a few tight knots of bright young stars in the arms.
	for _ in 0 ..< 26 {
		centre := gen.galaxy_sample(g, &rr)
		if radial(centre, cx, cy, R) < 0.25 do continue
		for _ in 0 ..< 40 {
			p := centre + {core.rng_range(&rr, -0.9, 0.9), core.rng_range(&rr, -0.9, 0.9)}
			q := tex(p, k)
			rl.DrawRectangleV({q.x - 0.5, q.y - 0.5}, {1.4, 1.4}, {200, 220, 255, u8(120 + core.rng_range(&rr, 0, 120))})
		}
		q := tex(centre, k)
		rl.DrawCircleGradient(q, k * 1.2, {170, 200, 255, 60}, {170, 200, 255, 0})
	}
	rl.EndBlendMode()
	// Dust: faint dark lanes hugging the inside of the arms (spirals) or
	// mottling the disc (lenticular). Normal blending so it dims the haze.
	if g.kind == .Spiral || g.kind == .Lenticular {
		for _ in 0 ..< 700 {
			p := gen.galaxy_sample(g, &rr, g.kind == .Spiral ? -0.16 : 0)
			t := radial(p, cx, cy, R)
			if t < 0.18 do continue
			q := tex(p, k)
			rad := k * f32(core.rng_range(&rr, 0.5, 1.3))
			rl.DrawCircleGradient(q, rad, {0, 0, 0, 70}, {0, 0, 0, 0})
		}
	}
	rl.EndTextureMode()
}

galaxy_map_draw :: proc(v: Map_View, st: ^Map_State) -> (clicked: int, closed: bool, jump: bool, hot: bool) {
	clicked = -1
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{40, BAR_H + 8, sw - 80, sh - BAR_H - 16}
	mouse := rl.GetMousePosition()
	hot = true
	g := v.galaxy
	span := f32(g.span)
	if !st.inited {
		st.zoom = 1
		st.center = {span * 0.5, span * 0.5}
		st.inited = true
	}
	if !st.has_tex || st.tex_seed != g.seed do build_backdrop(st, g)
	// The map has the whole window; the card is laid out first so the map
	// knows which patch of itself is covered.
	inner := rl.Rectangle{r.x + 10, r.y + 36, r.width - 20, r.height - 46}
	card := card_rect(v, inner)
	// Systems are framed in the room the card leaves, so nothing worth
	// clicking hides under it, while the backdrop still runs on behind.
	view := rl.Rectangle{inner.x, inner.y, inner.width - CARD_W - CARD_M, inner.height}
	base_scale := min(view.width, view.height) / span
	scale := base_scale * st.zoom
	to_screen :: proc(view: rl.Rectangle, scale: f32, center: [2]f32, p: [2]f64) -> rl.Vector2 {
		cx := view.x + view.width * 0.5
		cy := view.y + view.height * 0.5
		return {cx + (f32(p.x) - center.x) * scale, cy - (f32(p.y) - center.y) * scale}
	}
	// Input: wheel zooms about the cursor, right-drag pans, click selects.
	// The card swallows the mouse where it lies over the map.
	on_map := rl.CheckCollisionPointRec(mouse, inner) && !rl.CheckCollisionPointRec(mouse, card)
	if on_map {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			before := [2]f32{st.center.x + (mouse.x - view.x - view.width * 0.5) / scale, st.center.y - (mouse.y - view.y - view.height * 0.5) / scale}
			st.zoom = clamp(st.zoom * math.pow(f32(1.2), wheel), 1, 12)
			scale = base_scale * st.zoom
			after := [2]f32{st.center.x + (mouse.x - view.x - view.width * 0.5) / scale, st.center.y - (mouse.y - view.y - view.height * 0.5) / scale}
			st.center += before - after
		}
		if rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE) {
			d := rl.GetMouseDelta()
			st.center.x -= d.x / scale
			st.center.y += d.y / scale
		}
	}
	half := span * 0.5 / st.zoom
	st.center.x = clamp(st.center.x, half, span - half)
	st.center.y = clamp(st.center.y, half, span - half)

	rl.DrawRectangleRounded(r, 0.02, 6, {3, 4, 8, 252})
	rl.DrawRectangleRoundedLinesEx(r, 0.02, 6, 1, BAR_LINE)
	// Title bar: the window's name, what galaxy this is, and the controls.
	text.draw("Galaxy map", i32(r.x + 14), i32(r.y + 9), 16, TEXT_MAIN)
	text.draw(fmt.ctprintf("%v galaxy, %d systems", g.kind, len(g.systems)), i32(r.x + 28 + f32(text.measure("Galaxy map", 16))), i32(r.y + 12), 12, TEXT_DIM)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 8, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	hint: cstring = "wheel zooms    right-drag pans    click selects"
	text.draw(hint, i32(close.x - 16 - f32(text.measure(hint, 12))), i32(r.y + 12), 12, TEXT_DIM)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do closed = true

	rl.BeginScissorMode(i32(inner.x), i32(inner.y), i32(inner.width), i32(inner.height))
	// ---- backdrop texture, mapped onto the light-year plane
	{
		tl := to_screen(view, scale, st.center, {0, f64(span)})
		src := rl.Rectangle{0, 0, BACKDROP_PX, -BACKDROP_PX}
		dst := rl.Rectangle{tl.x, tl.y, span * scale, span * scale}
		rlgl.SetBlendFactors(rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD)
		rl.BeginBlendMode(.CUSTOM)
		rl.DrawTexturePro(st.tex.texture, src, dst, {0, 0}, 0, rl.WHITE)
		rl.EndBlendMode()
	}
	// ---- edges: the whole lattice faintly, the current system's links
	// bright, the selection's links picked out.
	for e in g.edges {
		a := to_screen(view, scale, st.center, g.systems[e.a].pos)
		b := to_screen(view, scale, st.center, g.systems[e.b].pos)
		rl.DrawLineV(a, b, {120, 140, 190, 28})
	}
	if v.selected >= 0 && v.selected != v.current {
		for j in gen.neighbours(g, v.selected) {
			a := to_screen(view, scale, st.center, g.systems[v.selected].pos)
			b := to_screen(view, scale, st.center, g.systems[j].pos)
			rl.DrawLineEx(a, b, 1.5, {255, 220, 120, 150})
		}
	}
	for j in gen.neighbours(g, v.current) {
		a := to_screen(view, scale, st.center, g.systems[v.current].pos)
		b := to_screen(view, scale, st.center, g.systems[j].pos)
		rl.DrawLineEx(a, b, 2, {120, 170, 240, 230})
	}
	// ---- systems: a soft glow in the star's colour, sized by brightness
	hover := -1
	hover_d: f32 = 12
	zs := math.sqrt(st.zoom)
	rl.BeginBlendMode(.ADDITIVE)
	// Nebulae first, under the stars. A site is a cloud with barely a star
	// in it and is drawn as one; a working system that happens to hold a
	// cloud gets a wisp of its colour around the usual point.
	for s in g.systems {
		if !s.nebula do continue
		p := to_screen(view, scale, st.center, s.pos)
		nc := gen.nebula_kind_color(s.neb_kind)
		size := (s.is_site ? f32(15) : f32(6)) * zs
		gain := u8(s.is_site ? 100 : 42)
		// Three offset puffs read as gas where one circle reads as a dot.
		for k in 0 ..< 3 {
			a := f32(k) * 2.094 + f32(s.seed % 64) * 0.1
			off := rl.Vector2{math.cos(a) * size * 0.30, math.sin(a) * size * 0.30}
			rl.DrawCircleGradient({p.x + off.x, p.y + off.y}, size * (0.75 + f32(k) * 0.16), {nc[0], nc[1], nc[2], gain}, {nc[0], nc[1], nc[2], 0})
		}
	}
	for s in g.systems {
		p := to_screen(view, scale, st.center, s.pos)
		col := rl.Color{s.star.color[0], s.star.color[1], s.star.color[2], 255}
		lum := f32(clamp(math.log10(s.star.luminosity + 1), 0, 2.2))
		rl.DrawCircleGradient(p, (2.5 + 2.2 * lum) * zs, {col.r, col.g, col.b, u8(50 + 30 * lum)}, {col.r, col.g, col.b, 0})
	}
	rl.EndBlendMode()
	for s, i in g.systems {
		p := to_screen(view, scale, st.center, s.pos)
		col := rl.Color{s.star.color[0], s.star.color[1], s.star.color[2], 255}
		lum := f32(clamp(math.log10(s.star.luminosity + 1), 0, 2.2))
		rad := (1.1 + 0.5 * lum) * zs
		if i == v.current {
			rl.DrawCircleLinesV(p, rad + 6, {150, 230, 170, 255})
			rl.DrawCircleLinesV(p, rad + 7, {150, 230, 170, 120})
		}
		if i == v.selected {
			rl.DrawCircleLinesV(p, rad + 9, {255, 220, 120, 255})
			rl.DrawCircleLinesV(p, rad + 10, {255, 220, 120, 120})
		}
		rl.DrawCircleV(p, rad, col)
		if lum > 0.8 do rl.DrawCircleV(p, rad * 0.5, {255, 255, 255, 200})
		d := math.sqrt((mouse.x - p.x) * (mouse.x - p.x) + (mouse.y - p.y) * (mouse.y - p.y))
		if d < hover_d && on_map {
			hover_d = d
			hover = i
		}
	}
	// Labels: current, selected, hovered, and the current system's neighbours.
	label :: proc(view: rl.Rectangle, scale: f32, center: [2]f32, s: gen.Summary, col: rl.Color) {
		p := to_screen(view, scale, center, s.pos)
		w := f32(text.measure(fmt.ctprintf("%s", s.name), 12))
		rl.DrawRectangleRounded({p.x + 5, p.y - 9, w + 8, 16}, 0.4, 4, {3, 4, 8, 170})
		text.draw(fmt.ctprintf("%s", s.name), i32(p.x + 9), i32(p.y - 7), 12, col)
	}
	for s in g.systems {
		if !s.is_site do continue
		label(view, scale, st.center, s, {u8(gen.nebula_kind_color(s.neb_kind)[0]), u8(gen.nebula_kind_color(s.neb_kind)[1]), u8(gen.nebula_kind_color(s.neb_kind)[2]), 220})
	}
	for j in gen.neighbours(g, v.current) do label(view, scale, st.center, g.systems[j], TEXT_DIM)
	label(view, scale, st.center, g.systems[v.current], {150, 230, 170, 255})
	if v.selected >= 0 do label(view, scale, st.center, g.systems[v.selected], {255, 220, 120, 255})
	if hover >= 0 && hover != v.current && hover != v.selected do label(view, scale, st.center, g.systems[hover], TEXT_MAIN)
	rl.EndScissorMode()
	if hover >= 0 && rl.IsMouseButtonPressed(.LEFT) do clicked = hover
	draw_legend(inner, v)
	jump = card_draw(v, card)
	return
}

// ---- the info card
//
// A single floating panel over the map. Everything in it is laid out
// top-down through a Col: a header saying which system this is, then
// captioned blocks of label-and-value rows for the star, the system, its
// economy and the crossing. The card is walked twice a frame, once dry to
// measure its height and once to draw, so the box always fits its contents.

@(private = "file")
Col :: struct {
	x, y, w: f32,
	dry:     bool, // measuring, not drawing
}

// A line of text on its own, followed by `gap` empty pixels.
@(private = "file")
col_line :: proc(c: ^Col, s: cstring, size: i32, col: rl.Color, gap: f32) {
	if !c.dry do text.draw(s, i32(c.x), i32(c.y), size, col)
	c.y += f32(size) + gap
}

// A block caption: small dim capitals with a hairline running out to the
// right edge, so the blocks read as blocks without boxing them in.
@(private = "file")
col_section :: proc(c: ^Col, name: cstring) {
	c.y += 12
	if !c.dry {
		text.draw(name, i32(c.x), i32(c.y), 12, CAP_COL)
		w := f32(text.measure(name, 12))
		rl.DrawLineV({c.x + w + 10, c.y + 7}, {c.x + c.w, c.y + 7}, RULE_COL)
	}
	c.y += 21
}

// Dim label on the left, the value right-aligned against the far edge.
@(private = "file")
col_row :: proc(c: ^Col, label, value: cstring, col := TEXT_MAIN) {
	if !c.dry {
		text.draw(label, i32(c.x), i32(c.y + 2), 12, TEXT_DIM)
		text.draw(value, i32(c.x + c.w - f32(text.measure(value, 14))), i32(c.y), 14, col)
	}
	c.y += CARD_ROW
}

// Wrapped prose: hazards, hints and the like.
@(private = "file")
col_note :: proc(c: ^Col, s: string, col: rl.Color) {
	for line in wrap_text(s, c.w, 12) {
		if !c.dry do text.draw(fmt.ctprintf("%s", line), i32(c.x), i32(c.y), 12, col)
		c.y += 16
	}
}

// Pills for the facts a system either has or has not.
@(private = "file")
col_chips :: proc(c: ^Col, chips: []string) {
	if len(chips) == 0 do return
	x := c.x
	for s in chips {
		t := fmt.ctprintf("%s", s)
		w := f32(text.measure(t, 12)) + 18
		if x > c.x && x + w > c.x + c.w {
			x = c.x
			c.y += 22
		}
		if !c.dry {
			pill := rl.Rectangle{x, c.y, w, 19}
			rl.DrawRectangleRounded(pill, 0.5, 5, {26, 32, 46, 255})
			rl.DrawRectangleRoundedLinesEx(pill, 0.5, 5, 1, {50, 60, 80, 255})
			text.draw(t, i32(x + 9), i32(c.y + 3), 12, {186, 196, 214, 255})
		}
		x += w + 6
	}
	c.y += 23
}

// Luminosity runs from a thousandth of the sun to tens of thousands of it.
@(private = "file")
solar :: proc(x: f64) -> cstring {
	switch {
	case x >= 100: return fmt.ctprintf("%.0f solar", x)
	case x >= 1:   return fmt.ctprintf("%.2f solar", x)
	}
	return fmt.ctprintf("%.4f solar", x)
}

// Where the card sits, sized to what it has to say.
@(private = "file")
card_rect :: proc(v: Map_View, inner: rl.Rectangle) -> rl.Rectangle {
	c := Col{y = CARD_PAD, w = CARD_W - 2 * CARD_PAD, dry = true}
	card_content(&c, v)
	h := min(c.y + CARD_PAD - 4, inner.height - 2 * CARD_M)
	return {inner.x + inner.width - CARD_W - CARD_M, inner.y + CARD_M, CARD_W, h}
}

@(private = "file")
card_draw :: proc(v: Map_View, card: rl.Rectangle) -> (jump: bool) {
	rl.DrawRectangleRounded({card.x - 2, card.y + 3, card.width + 4, card.height + 4}, 0.05, 6, {0, 0, 0, 110})
	rl.DrawRectangleRounded(card, 0.05, 6, CARD_BG)
	rl.DrawRectangleRoundedLinesEx(card, 0.05, 6, 1, CARD_EDGE)
	rl.BeginScissorMode(i32(card.x), i32(card.y), i32(card.width), i32(card.height))
	c := Col{x = card.x + CARD_PAD, y = card.y + CARD_PAD, w = card.width - 2 * CARD_PAD}
	jump = card_content(&c, v)
	rl.EndScissorMode()
	return
}

@(private = "file")
card_content :: proc(c: ^Col, v: Map_View) -> (jump: bool) {
	g := v.galaxy
	// With nothing picked the card describes where the ship already is.
	shown := v.selected >= 0 ? v.selected : v.current
	s := g.systems[shown]
	here := shown == v.current
	accent := here ? HERE_COL : SEL_COL

	// ---- header: what this is, its name, and what kind of star it is
	if !c.dry {
		rl.DrawCircleV({c.x + 4, c.y + 6}, 4, accent)
		rl.DrawCircleLinesV({c.x + 4, c.y + 6}, 7, {accent.r, accent.g, accent.b, 110})
		text.draw(here ? "YOU ARE HERE" : "SELECTED", i32(c.x + 17), i32(c.y), 12, accent)
	}
	c.y += 21
	col_line(c, fmt.ctprintf("%s", s.name), 22, TEXT_MAIN, 3)
	col_line(c, fmt.ctprintf("%s", gen.star_describe(s.star)), 12, TEXT_DIM, 0)

	// ---- the star
	col_section(c, "STAR")
	col_row(c, "mass", fmt.ctprintf("%.2f solar", s.star.mass))
	col_row(c, "luminosity", solar(s.star.luminosity))
	col_row(c, "surface", fmt.ctprintf("%.0f K", s.star.temperature))
	if note := gen.star_hazard_note(s.star); note != "" {
		c.y += 3
		col_note(c, note, WARN_COL)
	}

	// ---- what is in orbit
	col_section(c, "SYSTEM")
	if s.is_site do col_row(c, "planets", "none: gas only")
	else do col_row(c, "planets", fmt.ctprintf("%d", s.planets))
	chips := make([dynamic]string, context.temp_allocator)
	if s.has_gas do append(&chips, "gas giant")
	if s.has_hab do append(&chips, "habitable band")
	if s.nebula do append(&chips, gen.nebula_describe(s.neb_kind))
	col_chips(c, chips[:])
	if s.nebula do col_note(c, gen.nebula_note(s.neb_kind), TEXT_DIM)
	if s.is_site do col_note(c, "nothing to dock with; survey ships work the cloud", TEXT_DIM)

	// ---- the market picture, once the place has been surveyed
	col_section(c, "ECONOMY")
	if v.surveyed {
		col_row(c, "output", fmt.ctprintf("%.0f / day", v.output))
		col_row(c, "wealth", fmt.ctprintf("%.0f", v.wealth))
		col_row(c, "demand", fmt.ctprintf("%.0f%%", v.demand * 100))
		col_row(c, "markets", fmt.ctprintf("%d", v.markets))
	} else {
		col_note(c, "Not yet surveyed.", TEXT_DIM)
	}

	// ---- the crossing, and the one button that starts it
	if !here {
		col_section(c, "CROSSING")
		if e, ok := gen.edge_between(g, v.current, shown); ok {
			col_row(c, "distance", fmt.ctprintf("%.1f ly", e.distance))
			col_row(c, "cryo sleep", fmt.ctprintf("%.1f years", e.distance / max(v.cryo_speed, 1e-6)), SEL_COL)
			col_row(c, "cruise", fmt.ctprintf("%.2f c", v.cryo_speed))
			c.y += 8
			if !c.dry {
				label: string = v.can_jump ? "Jump now" : (v.pending ? "Flying out of the system..." : "Fly out of the system, then jump")
				if button({c.x, c.y, c.w, 30}, label, !v.pending, v.can_jump) do jump = true
			}
			c.y += 34
			if !v.can_jump && !v.pending do col_note(c, "The autopilot takes you past the star's grip first.", TEXT_DIM)
		} else {
			col_row(c, "straight line", fmt.ctprintf("%.1f ly", gen.distance(g, v.current, shown)))
			c.y += 3
			col_note(c, "No link from here. Cross by way of a system that is linked.", WARN_COL)
		}
	} else if v.selected < 0 {
		c.y += 10
		col_note(c, "Click a star to weigh up the crossing.", TEXT_DIM)
	}
	return
}

// A key in the map's bottom-left corner: the two rings, and the systems
// they mark, so the card is free to be about one system at a time.
@(private = "file")
draw_legend :: proc(inner: rl.Rectangle, v: Map_View) {
	g := v.galaxy
	here := fmt.ctprintf("%s", g.systems[v.current].name)
	has_sel := v.selected >= 0 && v.selected != v.current
	sel: cstring = has_sel ? fmt.ctprintf("%s", g.systems[v.selected].name) : ""
	w := 26 + f32(text.measure(here, 12)) + 14
	if has_sel do w += 20 + f32(text.measure(sel, 12))
	bg := rl.Rectangle{inner.x + 12, inner.y + inner.height - 34, w, 24}
	rl.DrawRectangleRounded(bg, 0.5, 6, {8, 11, 18, 210})
	rl.DrawRectangleRoundedLinesEx(bg, 0.5, 6, 1, {42, 50, 68, 255})
	entry :: proc(x, y: f32, col: rl.Color, name: cstring) -> f32 {
		rl.DrawCircleLinesV({x + 5, y}, 5, col)
		rl.DrawCircleV({x + 5, y}, 2, col)
		text.draw(name, i32(x + 15), i32(y - 7), 12, col)
		return x + 15 + f32(text.measure(name, 12)) + 20
	}
	x := entry(bg.x + 9, bg.y + 12, HERE_COL, here)
	if has_sel do entry(x, bg.y + 12, SEL_COL, sel)
}
