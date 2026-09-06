package ui

// Course options: direct transfers first, then one section per gravity
// assist body. One clickable row per route.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import text "sim:text"

Plan_Row :: struct {
	section:     string, // header drawn above this row when non-empty
	name:        string,
	ok, fits:    bool,
	burns:       int,
	dv:          f64,
	depart_in:   f64,
	arrive_in:   f64,
	propellant:  f64, // percent after
	note:        string, // "does not fit", or empty
}

// Returns the chosen row index, -1 if none; `closed` when dismissed.
plan_table_draw :: proc(dest: string, rows: []Plan_Row) -> (chosen: int, closed: bool, hot: bool) {
	chosen = -1
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	sections := 0
	for row in rows do if row.section != "" do sections += 1
	pw: f32 = 760
	ph: f32 = 60 + f32(len(rows)) * 28 + f32(sections) * 24 + 50
	r := rl.Rectangle{(sw - pw) * 0.5, BAR_H + 60, pw, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.04, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1, BAR_LINE)
	text.draw(fmt.ctprintf("Course to %s", dest), i32(r.x + 16), i32(r.y + 12), 18, TEXT_MAIN)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 10, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do closed = true

	cols := [?]f32{16, 300, 370, 470, 570, 670}
	hy := r.y + 42
	for h, i in ([?]cstring{"route", "burns", "dv total", "depart in", "arrive in", "propellant"}) {
		text.draw(h, i32(r.x + cols[i]), i32(hy), 13, TEXT_DIM)
	}
	y := hy + 24
	for row, i in rows {
		if row.section != "" {
			text.draw(fmt.ctprintf("%s", row.section), i32(r.x + 16), i32(y), 13, {220, 170, 90, 255})
			rl.DrawLineV({r.x + 16, y + 17}, {r.x + r.width - 16, y + 17}, BAR_LINE)
			y += 24
		}
		rr := rl.Rectangle{r.x + 8, y - 4, r.width - 16, 26}
		over := rl.CheckCollisionPointRec(mouse, rr) && row.ok
		if over do rl.DrawRectangleRounded(rr, 0.2, 3, HOVER_BG)
		col := row.ok ? (row.fits ? TEXT_MAIN : rl.Color{255, 140, 120, 255}) : TEXT_DIM
		text.draw(fmt.ctprintf("%d  %s", i + 1, row.name), i32(r.x + cols[0]), i32(y), 15, col)
		if row.ok {
			text.draw(fmt.ctprintf("%d", row.burns), i32(r.x + cols[1]), i32(y), 15, col)
			text.draw(fmt.ctprintf("%.4f", row.dv), i32(r.x + cols[2]), i32(y), 15, col)
			text.draw(fmt.ctprintf("%s", core.clock_duration(row.depart_in)), i32(r.x + cols[3]), i32(y), 15, col)
			text.draw(fmt.ctprintf("%s", core.clock_duration(row.arrive_in)), i32(r.x + cols[4]), i32(y), 15, col)
			text.draw(fmt.ctprintf("%.0f%%%s", row.propellant, row.fits ? "" : "  (does not fit)"), i32(r.x + cols[5]), i32(y), 15, col)
		} else {
			text.draw(fmt.ctprintf("%s", row.note != "" ? row.note : "no solution"), i32(r.x + cols[2]), i32(y), 15, col)
		}
		if over && rl.IsMouseButtonPressed(.LEFT) do chosen = i
		y += 28
	}
	text.draw("Click a route or press its number. Direct routes burn to leave and to arrive, with a correction on the way; an assist adds a pass at that body.", i32(r.x + 16), i32(r.y + ph - 26), 12, TEXT_DIM)
	return
}
