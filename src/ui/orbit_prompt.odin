package ui

// "Orbit at altitude": a small card with a slider and a Go button.

import "core:fmt"
import rl "vendor:raylib"
import text "sim:text"

Orbit_Prompt :: struct {
	open:     bool,
	altitude: f32, // above the surface, world units
	lo, hi:   f32,
	body:     string,
	current:  f32,
}

orbit_prompt_draw :: proc(p: ^Orbit_Prompt) -> (go: bool, hot: bool) {
	if !p.open do return
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{(sw - 520) * 0.5, sh * 0.5 - 80, 520, 150}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.05, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.05, 6, 1, {150, 190, 255, 255})
	text.draw(fmt.ctprintf("Orbit %s at", p.body), i32(r.x + 18), i32(r.y + 12), 17, {150, 190, 255, 255})
	text.draw(fmt.ctprintf("now %.1f above the surface", p.current), i32(r.x + 18), i32(r.y + 38), 13, TEXT_DIM)
	slider({r.x + 18, r.y + 64, r.width - 36, 20}, "altitude", &p.altitude, p.lo, p.hi, "%.1f")
	if button({r.x + 18, r.y + 104, 150, 30}, "Go", true, true) do go = true
	if button({r.x + r.width - 168, r.y + 104, 150, 30}, "Cancel") do p.open = false
	if rl.IsKeyPressed(.ENTER) do go = true
	if rl.IsKeyPressed(.ESCAPE) do p.open = false
	return
}
