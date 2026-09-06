package ui

// Centered prompt once the ship has left the star's grip: jump or not yet.

import "core:fmt"
import rl "vendor:raylib"
import text "sim:text"

jump_prompt_draw :: proc(dest: string, years: f64) -> (jump: bool, cancel: bool, hot: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{(sw - 420) * 0.5, sh * 0.5 - 70, 420, 120}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.05, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.05, 6, 1, {150, 230, 170, 255})
	text.draw("Clear of the star", i32(r.x + 16), i32(r.y + 12), 17, {150, 230, 170, 255})
	text.draw(fmt.ctprintf("Engage cryo for %s?  %.1f years will pass.", dest, years), i32(r.x + 16), i32(r.y + 42), 14, TEXT_MAIN)
	btn :: proc(rr: rl.Rectangle, label: cstring, mouse: rl.Vector2) -> bool {
		over := rl.CheckCollisionPointRec(mouse, rr)
		rl.DrawRectangleRounded(rr, 0.3, 4, over ? HOVER_BG : rl.Color{30, 36, 50, 255})
		tw := f32(text.measure(label, 14))
		text.draw(label, i32(rr.x + (rr.width - tw) * 0.5), i32(rr.y + 6), 14, TEXT_MAIN)
		return over && rl.IsMouseButtonPressed(.LEFT)
	}
	if btn({r.x + 16, r.y + 76, 180, 28}, "Jump", mouse) do jump = true
	if btn({r.x + 224, r.y + 76, 180, 28}, "Not yet", mouse) do cancel = true
	return
}
