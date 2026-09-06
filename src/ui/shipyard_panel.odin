package ui

// Shipyard: classes in stock with price, stats and a buy button.

import "core:fmt"
import rl "vendor:raylib"
import econ "sim:econ"
import text "sim:text"

Yard_Row :: struct {
	class:      econ.Class_Id,
	name:       string,
	stock:      int,
	price:      f64,
	cargo:      f64,
	dv:         f64,
	cryo:       f64,
	progress:   f64,
	is_current: bool,
}

Yard_View :: struct {
	name:     string,
	rows:     []Yard_Row,
	credits:  f64,
	trade_in: f64,
}

shipyard_panel_draw :: proc(v: Yard_View, open: ^bool) -> (buy: econ.Class_Id, did: bool, hot: bool) {
	if !open^ do return
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	pw: f32 = 640
	ph := f32(90 + len(v.rows) * 26 + 30)
	r := rl.Rectangle{sw - pw - 8 - right_inset, sh - ph - 8, pw, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.04, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1, BAR_LINE)
	x := r.x + 14
	y := r.y + 10
	text.draw(fmt.ctprintf("%s   shipyard", v.name), i32(x), i32(y), 17, TEXT_MAIN)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 8, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do open^ = false
	y += 24
	text.draw(fmt.ctprintf("credits %.0f     your hull trades in for %.0f", v.credits, v.trade_in), i32(x), i32(y), 14, TEXT_DIM)
	y += 24
	cols := [?]f32{0, 110, 180, 250, 320, 400, 480, 560}
	for h, i in ([?]cstring{"class", "hold", "dv", "cryo", "price", "in stock", "", ""}) {
		text.draw(h, i32(x + cols[i]), i32(y), 12, TEXT_DIM)
	}
	y += 18
	for row in v.rows {
		col := row.is_current ? rl.Color{150, 230, 170, 255} : TEXT_MAIN
		text.draw(fmt.ctprintf("%s%s", row.name, row.is_current ? " (yours)" : ""), i32(x + cols[0]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.0f", row.cargo), i32(x + cols[1]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.3f", row.dv), i32(x + cols[2]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.2fc", row.cryo), i32(x + cols[3]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.0f", row.price), i32(x + cols[4]), i32(y), 13, col)
		if row.stock > 0 {
			text.draw(fmt.ctprintf("%d", row.stock), i32(x + cols[5]), i32(y), 13, col)
		} else {
			text.draw(fmt.ctprintf("building %.0f%%", row.progress * 100), i32(x + cols[5]), i32(y), 12, TEXT_DIM)
		}
		can := row.stock > 0 && !row.is_current && v.credits + v.trade_in >= row.price
		br := rl.Rectangle{x + cols[6], y - 3, 60, 20}
		over := rl.CheckCollisionPointRec(mouse, br) && can
		rl.DrawRectangleRounded(br, 0.3, 3, can ? (over ? HOVER_BG : rl.Color{30, 36, 50, 255}) : rl.Color{22, 26, 36, 255})
		text.draw("Buy", i32(br.x + 18), i32(br.y + 3), 13, can ? TEXT_MAIN : TEXT_DIM)
		if over && rl.IsMouseButtonPressed(.LEFT) {
			buy = row.class
			did = true
		}
		y += 26
	}
	text.draw("Buying trades in your hull. Cargo and propellant move over as far as they fit; the rest is sold here.", i32(x), i32(y + 4), 12, TEXT_DIM)
	return
}
