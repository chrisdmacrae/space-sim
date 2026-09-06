package ui

// An interruption: the clock stops, a card says what happened, and the
// player picks what to do about it.

import "core:fmt"
import rl "vendor:raylib"
import text "sim:text"

Notice_View :: struct {
	title:   string,
	text:    string,
	buttons: []string, // up to three; the first is the default (Enter)
	accent:  rl.Color,
}

// Returns the chosen button index, or -1.
notice_draw :: proc(v: Notice_View) -> (choice: int, hot: bool) {
	choice = -1
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	lines := wrap_text(v.text, 520, 14)
	h := f32(96 + len(lines) * 18)
	r := rl.Rectangle{(sw - 580) * 0.5, sh * 0.5 - h * 0.5 - 40, 580, h}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.05, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.05, 6, 1, v.accent)
	text.draw(fmt.ctprintf("%s", v.title), i32(r.x + 18), i32(r.y + 12), 17, v.accent)
	for l, i in lines do text.draw(fmt.ctprintf("%s", l), i32(r.x + 18), i32(r.y + 42 + f32(i) * 18), 14, TEXT_MAIN)
	bw: f32 = (r.width - 36 - f32(len(v.buttons) - 1) * 10) / f32(max(len(v.buttons), 1))
	for b, i in v.buttons {
		if button({r.x + 18 + f32(i) * (bw + 10), r.y + h - 42, bw, 30}, b, true, i == 0) do choice = i
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) do choice = 0
	if rl.IsKeyPressed(.ESCAPE) && len(v.buttons) > 1 do choice = len(v.buttons) - 1
	return
}
