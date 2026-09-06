package ui

// The derived trade-route table, as the player sees it.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import text "sim:text"

routes_panel_draw :: proc(e: ^econ.Economy, sys: ^gen.System, routes: []econ.Route) -> (closed: bool, hot: bool) {
	sw := f32(rl.GetScreenWidth())
	n := min(len(routes), 14)
	pw: f32 = 760
	ph := f32(70 + n * 22 + 30)
	r := rl.Rectangle{(sw - pw) * 0.5, BAR_H + 8, pw, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.04, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1, BAR_LINE)
	x := r.x + 14
	y := r.y + 10
	text.draw("Known trade routes   (for a 20-unit hold, refreshed every few hours)", i32(x), i32(y), 16, TEXT_MAIN)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 8, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do closed = true
	y += 30
	cols := [?]f32{0, 190, 380, 480, 570, 660}
	for h, i in ([?]cstring{"from", "to", "commodity", "profit/unit", "transfer", "credits/day"}) {
		text.draw(h, i32(x + cols[i]), i32(y), 12, TEXT_DIM)
	}
	y += 18
	for rt, i in routes {
		if i >= n do break
		text.draw(fmt.ctprintf("%s", e.markets[rt.from].name), i32(x + cols[0]), i32(y), 13, TEXT_MAIN)
		text.draw(fmt.ctprintf("%s", e.markets[rt.to].name), i32(x + cols[1]), i32(y), 13, TEXT_MAIN)
		text.draw(fmt.ctprintf("%s", econ.NAMES[rt.commodity]), i32(x + cols[2]), i32(y), 13, TEXT_MAIN)
		text.draw(fmt.ctprintf("%.1f", rt.unit_profit), i32(x + cols[3]), i32(y), 13, TEXT_MAIN)
		text.draw(fmt.ctprintf("%s", core.clock_duration(rt.transfer_t)), i32(x + cols[4]), i32(y), 13, TEXT_MAIN)
		text.draw(fmt.ctprintf("%.0f", rt.rate), i32(x + cols[5]), i32(y), 13, TEXT_MAIN)
		y += 22
	}
	if n == 0 do text.draw("no profitable routes right now", i32(x), i32(y), 13, TEXT_DIM)
	_ = sys
	return
}
