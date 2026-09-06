package ui

// The flight instruments, bottom centre: what a pilot reads at a glance
// instead of a paragraph of numbers. Throttle, propellant and Δv are vertical
// gauges on the left; a scope in the middle draws the conic the ship is
// actually on, around the body it is bound to; altitude and speed are tapes
// on the right with periapsis, apoapsis, circular and escape speed marked, so
// every number has a reference sitting beside it. Everything arrives in a
// Hud_View: nothing here reaches into the game.
//
// Drawn text is ASCII only - the font atlas carries the first 95 codepoints.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import core "sim:core"
import orbit "sim:orbit"
import text "sim:text"

HUD_W      :: 548
HUD_H      :: 152
HUD_MARGIN :: 10

HUD_BG    :: rl.Color{  9,  13,  19, 247}
HUD_EDGE  :: rl.Color{ 74,  98, 118, 255}
HUD_LINE  :: rl.Color{ 44,  60,  76, 255}
HUD_TRACK :: rl.Color{ 15,  21,  29, 255}
HUD_TEXT  :: rl.Color{198, 212, 226, 255}
HUD_DIM   :: rl.Color{116, 134, 154, 255}
HUD_CYAN  :: rl.Color{110, 205, 235, 255}
HUD_GREEN :: rl.Color{140, 226, 168, 255}
HUD_AMBER :: rl.Color{240, 182,  92, 255}
HUD_RED   :: rl.Color{242, 112, 106, 255}

// A named reference on a tape: periapsis and apoapsis on altitude, circular
// and escape speed on the speed tape.
Hud_Mark :: struct {
	value: f64,
	label: string,
	col:   rl.Color,
	on:    bool,
}

Hud_Lamp :: struct {
	label: string,
	on:    bool,
	col:   rl.Color,
}

Hud_View :: struct {
	mode:       string, // ON RAILS, BURN, DOCKED, WRECKED...
	primary:    string, // the body the ship is bound to
	throttle:   f64,    // 0..1
	hold:       string, // "", "PRO", "RET"
	autoburn:   bool,
	armed:      bool,
	propellant: f64,    // 0..1 of the tank
	dv:         f64,
	dv_full:    f64,    // Δv on a full tank: the gauge's top
	alt:        f64,    // above the surface
	alt_max:    f64,    // the sphere of influence, above the surface
	speed:      f64,
	v_circ:     f64,
	v_esc:      f64,
	pe, ap:     f64,    // altitudes above the surface
	conic:      orbit.Orbit, // the conic the ship is on
	radius:     f64,    // primary's radius
	soi:        f64,
	pos, vel:   [2]f64, // ship, relative to the primary
	hull:       f64,    // 0..1; lights a caution lamp once it is not whole
	hazard:     string, // "" when the hull is safe; lights the frame
	repairing:  bool,   // an engineer is bringing the hull back
	dead:       bool,
}

// Draws the cluster. Returns true when the mouse is over it, so the caller
// keeps world input from leaking through.
hud_draw :: proc(v: Hud_View) -> (hot: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{f32(i32((sw - HUD_W) * 0.5)), sh - HUD_H - HUD_MARGIN, HUD_W, HUD_H}
	hot = rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
	alarm := v.hazard != "" || v.dead
	edge := HUD_EDGE
	if alarm {
		// A slow pulse, so an alarm reads as an alarm without flickering.
		k := f32(0.5 + 0.5 * math.sin(rl.GetTime() * 4))
		edge = {u8(74 + k * 168), u8(98 - k * 10), u8(118 - k * 30), 255}
	}
	hud_panel(r, edge)

	// ---- header: what the ship is doing, to what, and the warning lamps
	mode_c := v.dead ? HUD_RED : (v.hazard != "" ? HUD_AMBER : HUD_TEXT)
	ml := fmt.ctprintf("%s", v.mode)
	text.draw(ml, i32(r.x + 14), i32(r.y + 9), 13, mode_c)
	px := r.x + 14 + f32(text.measure(ml, 13)) + 9
	rl.DrawCircleV({px, r.y + 16}, 1.5, HUD_LINE)
	text.draw(fmt.ctprintf("%s", v.primary), i32(px + 8), i32(r.y + 10), 12, HUD_DIM)
	lamps := [?]Hud_Lamp {
		{v.hold == "" ? "" : fmt.tprintf("HOLD %s", v.hold), v.hold != "", HUD_CYAN},
		{fmt.tprintf("HULL %.0f%%", v.hull * 100), v.hull < 0.995, v.hull < 0.5 ? HUD_RED : HUD_AMBER},
		{"REPAIR", v.repairing, HUD_GREEN},
		{"AUTOBURN", v.autoburn, HUD_AMBER},
		{"ARMED", v.armed, HUD_AMBER},
		{v.hazard, v.hazard != "", HUD_RED},
	}
	lx := r.x + r.width - 12
	for l in lamps {
		if !l.on do continue
		lbl := fmt.ctprintf("%s", l.label)
		w := f32(text.measure(lbl, 10)) + 14
		lx -= w
		box := rl.Rectangle{lx, r.y + 8, w, 16}
		rl.DrawRectangleRounded(box, 0.35, 4, {l.col.r / 6, l.col.g / 6, l.col.b / 6, 255})
		rl.DrawRectangleRoundedLinesEx(box, 0.35, 4, 1, l.col)
		text.draw(lbl, i32(lx + 7), i32(r.y + 11), 10, l.col)
		lx -= 5
	}
	rl.DrawLineEx({r.x + 10, r.y + 30}, {r.x + r.width - 10, r.y + 30}, 1, HUD_LINE)

	// ---- instrument row
	x0 := r.x + 14
	gy := r.y + 34
	gh: f32 = HUD_H - 34 - 10

	thr_c := v.throttle > 0 ? (v.autoburn ? HUD_AMBER : HUD_CYAN) : HUD_DIM
	hud_vgauge(x0, gy, 40, gh, "THR", v.throttle, fmt.tprintf("%.0f%%", v.throttle * 100), thr_c, 12)

	pf := clamp(v.propellant, 0, 1)
	prop_c := pf < 0.1 ? HUD_RED : (pf < 0.25 ? HUD_AMBER : HUD_GREEN)
	hud_vgauge(x0 + 52, gy, 40, gh, "PROP", pf, fmt.tprintf("%.0f%%", pf * 100), prop_c, 12)

	dvf := v.dv_full > 0 ? clamp(v.dv / v.dv_full, 0, 1) : 0
	hud_vgauge(x0 + 104, gy, 40, gh, "DV", dvf, fmt.tprintf("%.3f", v.dv), dvf < 0.15 ? HUD_AMBER : HUD_CYAN, 12)

	rl.DrawLineEx({x0 + 154, gy + 4}, {x0 + 154, gy + gh - 4}, 1, HUD_LINE)
	span := v.conic.e < 1 ? orbit.apoapsis(v.conic) : max(orbit.periapsis(v.conic) * 3, orbit.length(v.pos) * 1.3)
	span = max(span, v.radius * 1.7, 1e-9)
	hud_scope(x0 + 214, gy + 50, 48, v, span)
	hud_orbit_block(x0 + 272, gy, 84, gh, v, span)
	rl.DrawLineEx({x0 + 364, gy + 4}, {x0 + 364, gy + gh - 4}, 1, HUD_LINE)

	alt_marks := [?]Hud_Mark {
		{v.pe, "PE", HUD_AMBER, true},
		{v.ap, "AP", HUD_CYAN, v.conic.e < 1},
	}
	alt_c := v.alt < v.radius * 0.05 ? HUD_AMBER : HUD_CYAN
	hud_tape(x0 + 372, gy, 70, gh, "ALT", v.alt, 0, max(v.alt_max, v.alt * 1.1), true, alt_marks[:], hud_dist(v.alt), alt_c)

	spd_marks := [?]Hud_Mark {
		{v.v_circ, "VC", HUD_GREEN, v.v_circ > 0},
		{v.v_esc, "VE", HUD_AMBER, v.v_esc > 0},
	}
	spd_hi := max(v.v_esc * 1.2, v.speed * 1.08, 1e-9)
	hud_tape(x0 + 450, gy, 70, gh, "SPD", v.speed, 0, spd_hi, false, spd_marks[:], fmt.tprintf("%.4f", v.speed), v.speed >= v.v_esc && v.v_esc > 0 ? HUD_AMBER : HUD_CYAN)
	return
}

// Panel body: rounded slab, thin border, corner brackets. Shared with the log
// so both ends of the screen read as one instrument set.
hud_panel :: proc(r: rl.Rectangle, edge: rl.Color) {
	rl.DrawRectangleRounded(r, 0.06, 6, HUD_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.06, 6, 1, HUD_LINE)
	ARM :: 14 // length of a corner bracket's two strokes
	IN  :: 6  // how far inside the rounded edge they sit
	corners := [4][2]f32{{r.x + IN, r.y + IN}, {r.x + r.width - IN, r.y + IN}, {r.x + r.width - IN, r.y + r.height - IN}, {r.x + IN, r.y + r.height - IN}}
	dirs := [4][2]f32{{1, 1}, {-1, 1}, {-1, -1}, {1, -1}}
	for c, i in corners {
		d := dirs[i]
		rl.DrawLineEx({c.x, c.y}, {c.x + d.x * ARM, c.y}, 1.5, edge)
		rl.DrawLineEx({c.x, c.y}, {c.x, c.y + d.y * ARM}, 1.5, edge)
	}
}

// ---- gauges

@(private = "file")
hud_label :: proc(s: string, x, y, w: f32) {
	l := fmt.ctprintf("%s", s)
	text.draw(l, i32(x + (w - f32(text.measure(l, 10))) * 0.5), i32(y), 10, HUD_DIM)
}

// Boxed numeric, the way a gauge prints what its needle is pointing at.
@(private = "file")
hud_readout :: proc(x, y, w, h: f32, s: string, col: rl.Color) {
	box := rl.Rectangle{x, y, w, h}
	rl.DrawRectangleRec(box, HUD_TRACK)
	rl.DrawRectangleLinesEx(box, 1, HUD_LINE)
	l := fmt.ctprintf("%s", s)
	text.draw(l, i32(x + (w - f32(text.measure(l, 11))) * 0.5), i32(y + (h - 11) * 0.5 - 1), 11, col)
}

// A vertical segmented bar with quarter ticks, a lever pointer and a readout.
@(private = "file")
hud_vgauge :: proc(x, y, w, h: f32, label: string, frac: f64, value: string, col: rl.Color, segs: int) {
	hud_label(label, x, y, w)
	track := rl.Rectangle{x + (w - 13) * 0.5, y + 16, 13, h - 46}
	rl.DrawRectangleRec(track, HUD_TRACK)
	rl.DrawRectangleLinesEx(track, 1, HUD_LINE)
	f := clamp(frac, 0, 1)
	gap: f32 = 1
	bh := (track.height - gap * f32(segs - 1)) / f32(segs)
	for i in 0 ..< segs {
		lo := f64(i) / f64(segs)
		if f <= lo do break
		part := f32(min((f - lo) * f64(segs), 1))
		by := track.y + track.height - f32(i) * (bh + gap) - bh
		rl.DrawRectangleRec({track.x + 1.5, by + bh * (1 - part), track.width - 3, bh * part}, col)
	}
	for i in 0 ..= 4 {
		ty := track.y + track.height * f32(i) / 4
		rl.DrawLineEx({track.x - 5, ty}, {track.x - 1, ty}, 1, i % 4 == 0 ? HUD_DIM : HUD_LINE)
	}
	py := track.y + track.height * f32(1 - f)
	rl.DrawPoly({track.x + track.width + 5, py}, 3, 5, 180, col)
	hud_readout(x - 1, y + h - 17, w + 2, 16, value, col)
}

@(private = "file")
hud_frac :: proc(v, lo, hi: f64, logscale: bool) -> f32 {
	if hi <= lo do return 0
	if !logscale do return f32(clamp((v - lo) / (hi - lo), 0, 1))
	eps := max((hi - lo) * 0.003, 1e-12)
	num := math.ln((max(v, lo) - lo + eps) / eps)
	den := math.ln((hi - lo + eps) / eps)
	return f32(clamp(num / den, 0, 1))
}

// A vertical tape: scale ticks, a filled column to the current value, named
// reference marks, and a boxed readout riding the pointer.
@(private = "file")
hud_tape :: proc(x, y, w, h: f32, label: string, value, lo, hi: f64, logscale: bool, marks: []Hud_Mark, shown: string, col: rl.Color) {
	hud_label(label, x, y, w)
	track := rl.Rectangle{x + 15, y + 16, 6, h - 24}
	rl.DrawRectangleRec(track, HUD_TRACK)
	for i in 0 ..= 10 {
		ty := track.y + track.height * f32(i) / 10
		n: f32 = i % 5 == 0 ? 6 : 3
		rl.DrawLineEx({track.x - n - 1, ty}, {track.x - 1, ty}, 1, i % 5 == 0 ? HUD_DIM : HUD_LINE)
	}
	u := hud_frac(value, lo, hi, logscale)
	fh := track.height * u
	rl.DrawRectangleRec({track.x, track.y + track.height - fh, track.width, fh}, {col.r, col.g, col.b, 190})
	rl.DrawRectangleLinesEx(track, 1, HUD_LINE)
	// Reference lines first, then their labels on top of the scale ticks.
	for m in marks {
		if !m.on do continue
		my := track.y + track.height * (1 - hud_frac(m.value, lo, hi, logscale))
		rl.DrawLineEx({track.x - 7, my}, {track.x + track.width + 4, my}, 1, m.col)
	}
	used: [4]f32
	nused := 0
	for m in marks {
		if !m.on do continue
		my := track.y + track.height * (1 - hud_frac(m.value, lo, hi, logscale))
		// A circular orbit puts Pe and Ap in the same place: stack the labels.
		ly := my - 5
		for k in 0 ..< nused do if abs(ly - used[k]) < 9 do ly = used[k] + 9
		if nused < len(used) {
			used[nused] = ly
			nused += 1
		}
		lbl := fmt.ctprintf("%s", m.label)
		rl.DrawRectangleRec({x - 1, ly - 1, f32(text.measure(lbl, 10)) + 3, 12}, {11, 16, 23, 255})
		text.draw(lbl, i32(x), i32(ly), 10, m.col)
	}
	py := clamp(track.y + track.height * (1 - u), track.y + 8, track.y + track.height - 8)
	rl.DrawPoly({track.x + track.width + 6, py}, 3, 5, 180, col)
	bx := track.x + track.width + 10
	hud_readout(bx, py - 8, x + w - bx, 16, shown, col)
}

// ---- orbit

// The conic the ship is on, drawn around its primary: the instrument that
// makes an orbit a shape instead of four numbers.
@(private = "file")
hud_scope :: proc(cx, cy, R: f32, v: Hud_View, span: f64) {
	rl.DrawCircleV({cx, cy}, R, {11, 16, 23, 255})
	rl.DrawCircleLinesV({cx, cy}, R, HUD_EDGE)
	rl.DrawCircleLinesV({cx, cy}, R - 3, HUD_LINE)
	for i in 0 ..< 12 {
		a := f32(i) * math.PI / 6
		c, s := math.cos(a), math.sin(a)
		n: f32 = i % 3 == 0 ? 7 : 4
		rl.DrawLineEx({cx + c * (R - 3), cy + s * (R - 3)}, {cx + c * (R - 3 - n), cy + s * (R - 3 - n)}, 1, i % 3 == 0 ? HUD_DIM : HUD_LINE)
	}
	o := v.conic
	scale := f32(f64(R) * 0.84 / span)
	to :: proc(cx, cy, scale: f32, p: [2]f64) -> rl.Vector2 {
		return {cx + f32(p.x) * scale, cy - f32(p.y) * scale}
	}
	inside :: proc(p: rl.Vector2, cx, cy, R: f32) -> bool {
		dx, dy := p.x - cx, p.y - cy
		return dx * dx + dy * dy < (R - 4) * (R - 4)
	}
	// The sphere of influence, when it fits: the edge of this frame.
	if sr := f32(v.soi) * scale; sr < R - 5 && sr > f32(v.radius) * scale + 3 {
		rl.DrawCircleLinesV({cx, cy}, sr, {60, 78, 96, 255})
	}
	// The body at the focus.
	br := clamp(f32(v.radius) * scale, 2.5, R - 5)
	rl.DrawCircleV({cx, cy}, br, {34, 52, 72, 255})
	rl.DrawCircleLinesV({cx, cy}, br, {86, 118, 148, 255})
	// The path, clipped to the bezel.
	N :: 96
	prev: rl.Vector2
	prev_in := false
	for i in 0 ..= N {
		p: [2]f64
		if o.e < 1 do p = orbit.point_at_E(o, 2 * math.PI * f64(i) / f64(N))
		else do p = orbit.point_at_anomaly(o, -2.6 + 5.2 * f64(i) / f64(N))
		s := to(cx, cy, scale, p)
		in_now := inside(s, cx, cy, R)
		if i > 0 && in_now && prev_in do rl.DrawLineEx(prev, s, 1.6, HUD_CYAN)
		prev, prev_in = s, in_now
	}
	// Apsides, then the ship over them.
	if o.e < 1 {
		ap := to(cx, cy, scale, orbit.point_at_E(o, math.PI))
		if inside(ap, cx, cy, R) {
			rl.DrawCircleV(ap, 2.5, HUD_CYAN)
			text.draw("A", i32(ap.x + 4), i32(ap.y - 6), 10, HUD_CYAN)
		}
	}
	pe := to(cx, cy, scale, orbit.point_at_E(o, 0) if o.e < 1 else orbit.point_at_anomaly(o, 0))
	if inside(pe, cx, cy, R) {
		rl.DrawCircleV(pe, 2.5, HUD_AMBER)
		text.draw("P", i32(pe.x + 4), i32(pe.y - 6), 10, HUD_AMBER)
	}
	ship := to(cx, cy, scale, v.pos)
	if inside(ship, cx, cy, R) {
		rot := f32(math.atan2(-v.vel.y, v.vel.x) * 180 / math.PI)
		sp := orbit.length(v.vel)
		if sp > 0 {
			d := rl.Vector2{f32(v.vel.x / sp), f32(-v.vel.y / sp)}
			rl.DrawLineEx(ship, {ship.x + d.x * 11, ship.y + d.y * 11}, 1, {140, 226, 168, 160})
		}
		rl.DrawPoly(ship, 3, 4.5, rot, v.dead ? HUD_RED : HUD_GREEN)
	}
}

// Periapsis, apoapsis, eccentricity (with a bar) and period, beside the scope.
@(private = "file")
hud_orbit_block :: proc(x, y, w, h: f32, v: Hud_View, span: f64) {
	esc := v.conic.e >= 1
	text.draw("ORBIT", i32(x), i32(y), 10, HUD_DIM)
	// How far the scope beside this block reaches, the way a radar says its range.
	rng := fmt.ctprintf("R %s", hud_dist(span))
	text.draw(rng, i32(x + w - f32(text.measure(rng, 10))), i32(y), 10, HUD_DIM)
	row :: proc(x, y, w: f32, label, value: string, col: rl.Color) {
		text.draw(fmt.ctprintf("%s", label), i32(x), i32(y), 11, HUD_DIM)
		l := fmt.ctprintf("%s", value)
		text.draw(l, i32(x + w - f32(text.measure(l, 12))), i32(y - 1), 12, col)
	}
	row(x, y + 16, w, "PE", hud_dist(v.pe), HUD_AMBER)
	row(x, y + 34, w, "AP", esc ? "escape" : hud_dist(v.ap), esc ? HUD_AMBER : HUD_CYAN)
	row(x, y + 52, w, "ECC", fmt.tprintf("%.3f", v.conic.e), esc ? HUD_AMBER : HUD_TEXT)
	// Eccentricity as a bar, 0 (circle) to 1 (escape).
	bar := rl.Rectangle{x, y + 70, w, 5}
	rl.DrawRectangleRec(bar, HUD_TRACK)
	rl.DrawRectangleLinesEx(bar, 1, HUD_LINE)
	e := f32(clamp(v.conic.e, 0, 1))
	rl.DrawRectangleRec({bar.x + 1, bar.y + 1, (bar.width - 2) * e, bar.height - 2}, esc ? HUD_AMBER : HUD_CYAN)
	rl.DrawLineEx({bar.x + bar.width - 1, bar.y - 2}, {bar.x + bar.width - 1, bar.y + bar.height + 2}, 1, HUD_AMBER)
	row(x, y + 88, w, "T", esc ? "-" : core.clock_duration(orbit.period(v.conic)), HUD_TEXT)
}

// Distances in this game run from a fraction of a unit to a few hundred.
@(private = "file")
hud_dist :: proc(v: f64) -> string {
	a := abs(v)
	switch {
	case a >= 1000: return fmt.tprintf("%.0f", v)
	case a >= 100:  return fmt.tprintf("%.1f", v)
	case a >= 1:    return fmt.tprintf("%.2f", v)
	case:           return fmt.tprintf("%.3f", v)
	}
}
