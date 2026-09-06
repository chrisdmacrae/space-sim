package ui

// Trade window shown while docked: every commodity with stock, prices, and
// the ship's hold, with buy/sell buttons.

import "core:fmt"
import rl "vendor:raylib"
import art "sim:art"
import econ "sim:econ"
import render "sim:render"
import sim "sim:sim"
import core "sim:core"
import text "sim:text"

Trade :: struct {
	commodity: econ.Commodity,
	units:     f64, // positive buys, negative sells
}

Market_View :: struct {
	market:    ^econ.Market,
	cargo:     []f64, // indexed by commodity
	cargo_cap: f64,
	credits:   f64,
	propellant_pct: f64,
	edge:      f64, // comms: fraction off what you pay and onto what you are paid
	// The person selling: face, name and their line for this visit.
	lib:         ^art.Library,
	vendor:      render.Avatar,
	vendor_name: string,
	vendor_line: string,
	// Colonies: no dock, a shuttle works the queue.
	shuttle:     ^sim.Shuttle, // nil for a station
	round_trip:  f64,          // seconds for one trip at the current altitude
}

MARKET_W :: 640
VENDOR_H :: 84
SHUTTLE_H :: 46

market_panel_draw :: proc(v: Market_View, open: ^bool) -> (trade: Trade, did: bool, talk: bool, jobs: bool, cancel: bool, hot: bool) {
	if !open^ do return
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rows := len(econ.Commodity)
	ph := f32(70 + VENDOR_H + rows * 22 + 40 + (v.shuttle != nil ? SHUTTLE_H : 0))
	r := rl.Rectangle{sw - MARKET_W - 8 - right_inset, sh - ph - 8, MARKET_W, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.04, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1, BAR_LINE)
	x := r.x + 14
	y := r.y + 10
	text.draw(fmt.ctprintf("%s   market", v.market.name), i32(x), i32(y), 17, TEXT_MAIN)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 8, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do open^ = false
	y += 24
	used := 0.0
	for u in v.cargo do used += u
	text.draw(fmt.ctprintf("credits %.0f     hold %.0f / %.0f", v.credits, used, v.cargo_cap), i32(x), i32(y), 14, TEXT_DIM)
	y += 24
	// The vendor: face, name, a line, and a Talk button.
	if v.lib != nil {
		render.avatar_draw(v.lib, v.vendor, {x + 34, y + 34}, 2)
		text.draw(fmt.ctprintf("%s", v.vendor_name), i32(x + 80), i32(y + 6), 15, TEXT_MAIN)
		for l, i in wrap_text(v.vendor_line, r.width - 240, 13) {
			if i > 2 do break
			text.draw(fmt.ctprintf("%s", l), i32(x + 80), i32(y + 28 + f32(i) * 16), 13, TEXT_DIM)
		}
		if button({r.x + r.width - 110, y + 6, 96, 26}, "Talk") do talk = true
		if button({r.x + r.width - 110, y + 38, 96, 26}, "Jobs") do jobs = true
	}
	y += VENDOR_H
	if v.shuttle != nil {
		buys, sells := sim.shuttle_pending(v.shuttle)
		rl.DrawRectangleRounded({x - 4, y - 4, r.width - 20, SHUTTLE_H - 6}, 0.2, 3, {14, 18, 26, 255})
		text.draw(fmt.ctprintf("Shuttle: %s   %.0f units per trip, about %s per round trip   trips %d", sim.shuttle_status(v.shuttle), sim.SHUTTLE_CAP, core.clock_duration(v.round_trip), v.shuttle.trips), i32(x + 4), i32(y + 2), 13, {150, 230, 170, 255})
		text.draw(fmt.ctprintf("queued: buy %.0f, sell %.0f   spent %.0f, earned %.0f   (orders queue; the shuttle flies while you hold this orbit)", buys, sells, v.shuttle.spent, v.shuttle.earned), i32(x + 4), i32(y + 20), 12, TEXT_DIM)
		if buys + sells > 0 && btn({r.x + r.width - 118, y + 8, 100, 20}, "Cancel orders", mouse, true) do cancel = true
		y += SHUTTLE_H
	}
	cols := [?]f32{0, 130, 210, 290, 370, 440, 500, 560}
	for h, i in ([?]cstring{"commodity", "stock", "buy at", "sell at", "you have", "", "", ""}) {
		text.draw(h, i32(x + cols[i]), i32(y), 12, TEXT_DIM)
	}
	y += 18
	btn :: proc(rr: rl.Rectangle, label: cstring, mouse: rl.Vector2, enabled: bool) -> bool {
		over := rl.CheckCollisionPointRec(mouse, rr) && enabled
		rl.DrawRectangleRounded(rr, 0.3, 3, enabled ? (over ? HOVER_BG : rl.Color{30, 36, 50, 255}) : rl.Color{22, 26, 36, 255})
		tw := f32(text.measure(label, 12))
		text.draw(label, i32(rr.x + (rr.width - tw) * 0.5), i32(rr.y + 3), 12, enabled ? TEXT_MAIN : TEXT_DIM)
		return over && rl.IsMouseButtonPressed(.LEFT)
	}
	for c in econ.Commodity {
		stock := v.market.stock[c]
		bp := econ.buy_price(v.market, c) * (1 - v.edge)
		sp := econ.sell_price(v.market, c) * (1 + v.edge)
		have := v.cargo[int(c)]
		ratio := v.market.target[c] > 0 ? stock / v.market.target[c] : 1
		col := TEXT_MAIN
		if ratio < 0.5 do col = {255, 170, 120, 255}   // scarce: sells high
		else if ratio > 1.5 do col = {140, 210, 160, 255} // glut: buys cheap
		text.draw(fmt.ctprintf("%s", econ.NAMES[c]), i32(x + cols[0]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.0f", stock), i32(x + cols[1]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.1f", bp), i32(x + cols[2]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.1f", sp), i32(x + cols[3]), i32(y), 13, col)
		text.draw(fmt.ctprintf("%.0f", have), i32(x + cols[4]), i32(y), 13, col)
		can_buy := stock >= 1 && v.credits >= bp && used < v.cargo_cap
		can_sell := have >= 1
		if btn({x + cols[5], y - 2, 26, 18}, "+1", mouse, can_buy) { trade = {c, 1}; did = true }
		if btn({x + cols[5] + 30, y - 2, 26, 18}, "+10", mouse, can_buy) { trade = {c, 10}; did = true }
		if btn({x + cols[6] + 24, y - 2, 26, 18}, "-1", mouse, can_sell) { trade = {c, -1}; did = true }
		if btn({x + cols[6] + 54, y - 2, 26, 18}, "-10", mouse, can_sell) { trade = {c, -10}; did = true }
		y += 22
	}
	if v.edge > 0 do text.draw(fmt.ctprintf("Orange: scarce (sells high). Green: glut (buys cheap). Your comms officer has talked every price %.0f%% your way.", v.edge * 100), i32(x), i32(y + 6), 12, TEXT_DIM)
	else do text.draw("Orange: scarce here (sells high). Green: glut (buys cheap). Prices move with every trade.", i32(x), i32(y + 6), 12, TEXT_DIM)
	return
}
