package ui

// Editor for the selected maneuver node: sliders for Δv and timing, and the
// warp / execute / remove buttons. Sits above the menu bar on the right.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import text "sim:text"

Node_Action :: enum u8 {
	None,
	Warp,
	Execute,
	Remove,
}

Node_View :: struct {
	index, count: int,
	prograde:     ^f32, // slider-bound copies; caller writes them back
	radial:       ^f32,
	lead:         ^f32, // seconds from now to the burn
	lead_max:     f32,
	burn_seconds: f64,
	dv:           f64,
	armed:        bool,
}

NODE_W :: 320
NODE_H :: 196

node_panel_draw :: proc(v: Node_View) -> (action: Node_Action, changed: bool, hot: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{sw - NODE_W - 8 - right_inset, sh - NODE_H - 8, NODE_W, NODE_H}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.05, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.05, 6, 1, BAR_LINE)
	x := r.x + 12
	y := r.y + 10
	w := r.width - 24
	text.draw(fmt.ctprintf("Maneuver node %d of %d%s", v.index + 1, v.count, v.armed ? "   ARMED" : ""), i32(x), i32(y), 16, v.armed ? rl.Color{150, 230, 170, 255} : TEXT_MAIN)
	y += 24
	text.draw(fmt.ctprintf("dv %.4f   burn %s", v.dv, core.clock_duration(v.burn_seconds)), i32(x), i32(y), 14, TEXT_DIM)
	y += 22

	slider :: proc(x, y, w: f32, label: string, v: ^f32, lo, hi: f32, fmt_s: string) -> bool {
		text.draw(fmt.ctprintf("%s", label), i32(x), i32(y), 13, TEXT_DIM)
		before := v^
		rl.GuiSlider({x + 70, y, w - 70 - 64, 16}, "", fmt.ctprintf(fmt_s, v^), v, lo, hi)
		return v^ != before
	}
	if slider(x, y, w, "prograde", v.prograde, -0.03, 0.03, "%+.4f") do changed = true
	y += 24
	if slider(x, y, w, "radial", v.radial, -0.03, 0.03, "%+.4f") do changed = true
	y += 24
	if slider(x, y, w, "burn in", v.lead, 30, v.lead_max, "%.0fs") do changed = true
	y += 30

	btn :: proc(r: rl.Rectangle, label: cstring, mouse: rl.Vector2) -> bool {
		over := rl.CheckCollisionPointRec(mouse, r)
		rl.DrawRectangleRounded(r, 0.25, 4, over ? HOVER_BG : rl.Color{30, 36, 50, 255})
		tw := f32(text.measure(label, 14))
		text.draw(label, i32(r.x + (r.width - tw) * 0.5), i32(r.y + 5), 14, TEXT_MAIN)
		return over && rl.IsMouseButtonPressed(.LEFT)
	}
	bw := (w - 16) / 3
	if btn({x, y, bw, 26}, "Warp to burn", mouse) do action = .Warp
	if btn({x + bw + 8, y, bw, 26}, "Execute", mouse) do action = .Execute
	if btn({x + 2 * (bw + 8), y, bw, 26}, "Remove", mouse) do action = .Remove
	return
}
