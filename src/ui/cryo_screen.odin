package ui

// Full-screen cryo transit: years counting up while the galaxy's economies
// catch up underneath.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import text "sim:text"
import core "sim:core"

Cryo_View :: struct {
	from, to:  string,
	progress:  f64, // 0..1
	years:     f64, // elapsed so far
	total:     f64,
	notes:     string, // multi-line flavour: what changed
}

STREAK_STARS :: 320

// Stars rushing past at a good fraction of c: each one falls from the
// vanishing point at the centre toward the edge, drawn as a streak from
// where it was a moment ago. Deterministic per star index, driven by the
// wall clock so it moves even while the sim clock is stepping.
draw_star_streaks :: proc(sw, sh: f32) {
	cx, cy := sw * 0.5, sh * 0.5
	tm := rl.GetTime()
	reach := f32(math.sqrt(f64(cx * cx + cy * cy)))
	for i in 0 ..< STREAK_STARS {
		h := u64(i) * 0x9E3779B97F4A7C15
		h ~= h >> 29
		h *= 0xBF58476D1CE4E5B9
		h ~= h >> 32
		u0 := f64(h & 0xFFFF) / 65535
		u1 := f64((h >> 16) & 0xFFFF) / 65535
		u2 := f64((h >> 32) & 0xFFFF) / 65535
		ang := u0 * 2 * math.PI
		speed := 0.25 + u1 * 0.45
		// Depth falls from 1 (far, at the centre) to 0 (past the viewer).
		z := 1 - math.mod(tm * speed + u2, 1)
		z_prev := min(z + 0.03 * speed / 0.5, 1)
		dist := proc(z: f64) -> f64 { return (1 / max(z, 0.04) - 1) * 40 }
		r := f32(dist(z))
		rp := f32(dist(z_prev))
		if r > reach do continue
		dx := f32(math.cos(ang))
		dy := f32(math.sin(ang))
		near := clamp(1 - z, 0, 1)
		alpha := u8(30 + 200 * near)
		thick := f32(0.6 + 1.6 * near)
		col := rl.Color{u8(200 + 55 * u1), u8(215 + 40 * u2), 255, alpha}
		rl.DrawLineEx({cx + dx * rp, cy + dy * rp}, {cx + dx * r, cy + dy * r}, thick, col)
	}
}

cryo_screen_draw :: proc(v: Cryo_View) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {3, 4, 8, 235})
	if core.gfx.effects do draw_star_streaks(sw, sh)
	// A darker panel keeps the text legible over the streaks.
	rl.DrawRectangleRounded({sw * 0.5 - 320, sh * 0.35 - 24, 640, 190}, 0.08, 6, {3, 4, 8, 245})
	cx := sw * 0.5
	y := sh * 0.35
	title := fmt.ctprintf("Cryo sleep   %s  ->  %s", v.from, v.to)
	tw := f32(text.measure(title, 22))
	text.draw(title, i32(cx - tw * 0.5), i32(y), 22, TEXT_MAIN)
	y += 44
	bar := rl.Rectangle{cx - 260, y, 520, 14}
	rl.DrawRectangleRounded(bar, 0.5, 4, {24, 30, 44, 255})
	rl.DrawRectangleRounded({bar.x, bar.y, bar.width * f32(v.progress), bar.height}, 0.5, 4, ACCENT)
	y += 30
	s := fmt.ctprintf("%.1f of %.1f years", v.years, v.total)
	sw2 := f32(text.measure(s, 16))
	text.draw(s, i32(cx - sw2 * 0.5), i32(y), 16, TEXT_DIM)
	y += 40
	line_y := y
	start := 0
	for i in 0 ..= len(v.notes) {
		if i == len(v.notes) || v.notes[i] == '\n' {
			if i > start {
				l := fmt.ctprintf("%s", v.notes[start:i])
				lw := f32(text.measure(l, 13))
				text.draw(l, i32(cx - lw * 0.5), i32(line_y), 13, TEXT_DIM)
				line_y += 18
			}
			start = i + 1
		}
	}
}
