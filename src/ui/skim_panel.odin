package ui

// The scoop. A small card under the bar while the ship is skimming a
// nebula: which cloud, how thick the gas is where you are sitting, how far
// through the current pass, and what has come aboard so far.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import econ "sim:econ"
import sim "sim:sim"
import text "sim:text"

Skim_View :: struct {
	nebula:  string,
	kind:    string,
	skim:    ^sim.Skim,
	tint:    [4]u8,
	hazard:  f64, // hull lost per hour where the ship is sitting
}

SKIM_W :: 340

// Returns true when Stop was pressed.
skim_panel_draw :: proc(v: Skim_View) -> (stop: bool, hot: bool) {
	sk := v.skim
	rows := 0
	for c in econ.Commodity do if sk.gathered[c] > 0.05 do rows += 1
	if sk.fuelled > 0 do rows += 1
	r := rl.Rectangle{8, BAR_H + 8, SKIM_W, f32(116 + rows * 16)}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.05, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.05, 6, 1, BAR_LINE)
	col := rl.Color{v.tint[0], v.tint[1], v.tint[2], 255}
	text.draw(fmt.ctprintf("Skimming %s", v.nebula), i32(r.x + 12), i32(r.y + 9), 15, col)
	text.draw(fmt.ctprintf("%s   gas %.0f%%   %s", v.kind, sk.density * 100, sim.skim_status(sk)), i32(r.x + 12), i32(r.y + 29), 12, TEXT_DIM)

	// The wait itself: a bar per pass, with what a pass costs and yields.
	bar := rl.Rectangle{r.x + 12, r.y + 48, r.width - 24, 10}
	rl.DrawRectangleRounded(bar, 0.5, 4, {22, 26, 36, 255})
	if p := f32(sim.skim_progress(sk)); p > 0.005 {
		fill := bar
		fill.width = max(bar.width * p, 4)
		rl.DrawRectangleRounded(fill, 0.5, 4, col)
	}
	left := sim.skim_cycle() * (1 - sim.skim_progress(sk))
	text.draw(fmt.ctprintf("pass %d, %s to go", sk.cycles + 1, core.clock_duration(left)), i32(r.x + 12), i32(r.y + 62), 12, TEXT_DIM)
	if v.hazard > 0 {
		note := fmt.ctprintf("hull -%.2f%%/h", v.hazard * 100)
		w := f32(text.measure(note, 12))
		text.draw(note, i32(r.x + r.width - 12 - w), i32(r.y + 62), 12, {220, 170, 140, 255})
	}

	y := r.y + 84
	for c in econ.Commodity {
		if sk.gathered[c] <= 0.05 do continue
		text.draw(fmt.ctprintf("%s", econ.NAMES[c]), i32(r.x + 12), i32(y), 12, TEXT_MAIN)
		amount := fmt.ctprintf("%.1f", sk.gathered[c])
		w := f32(text.measure(amount, 12))
		text.draw(amount, i32(r.x + r.width - 100 - w), i32(y), 12, TEXT_MAIN)
		y += 16
	}
	if sk.fuelled > 0 {
		text.draw("propellant", i32(r.x + 12), i32(y), 12, {150, 230, 170, 255})
		amount := fmt.ctprintf("%.1f", sk.fuelled)
		w := f32(text.measure(amount, 12))
		text.draw(amount, i32(r.x + r.width - 100 - w), i32(y), 12, {150, 230, 170, 255})
		y += 16
	}
	btn := rl.Rectangle{r.x + r.width - 84, r.y + r.height - 30, 72, 24}
	over := rl.CheckCollisionPointRec(mouse, btn)
	rl.DrawRectangleRounded(btn, 0.3, 4, over ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("Stop", i32(btn.x + 22), i32(btn.y + 5), 13, TEXT_MAIN)
	if over && rl.IsMouseButtonPressed(.LEFT) do stop = true
	return
}
